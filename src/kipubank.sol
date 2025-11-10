// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Imports from OpenZeppelin and Chainlink
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @author Ezequiel Arce
/// @notice Allows users to deposit and withdraw ETH or ERC20 tokens.
/// @dev Internally tracks all balances in USD value (USDC units). Swaps use Uniswap V2 pairs.
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice User vaults - tracks USDC balances per user (in USDC token units)
    mapping(address user => uint256) private s_vaults;

    /// @notice Global bank capacity (in USDC units)
    uint256 public s_bankCap;

    /// @notice Maximum amount (in USDC units) a user can withdraw in one transaction
    uint256 public s_withdrawalThreshold;

    /// @notice Total USDC deposited in the bank (sum of all vaults)
    uint256 public s_depositTotal;

    /// @notice Number of deposits and withdrawals (for tracking/statistics)
    uint256 private s_depositCount;
    uint256 private s_withdrawCount;

    /// @notice Uniswap V2 factory used to find pairs
    IUniswapV2Factory public immutable i_factory;

    /// @notice USDC token address (target accounting token)
    address public immutable i_usdc;

    /// @notice WETH wrapper interface (used to wrap ETH before swapping)
    IWETH public immutable i_weth;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event KipuBank_DepositAccepted(address indexed user, address indexed token, uint256 amountIn, uint256 amountOut);
    event KipuBank_WithdrawalAccepted(address indexed user, address indexed token, uint256 amount);
    event KipuBank_BankCapacityUpdated(uint256 newCapacity);
    event KipuBank_WithdrawalThresholdUpdated(uint256 newThreshold);
    event KipuBank_AdminRoleGranted(address newAdmin);
    event KipuBank_AdminRoleRevoked(address removedAdmin);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error KipuBank_InvalidAmount(address user, uint256 amount);
    error KipuBank_DepositRejected(address user, uint256 amount, string message);
    error KipuBank_WithdrawalRejected(address user, address token, uint256 amount, string message);
    error KipuBank_InitializationFailed(uint256 bankCap, uint256 withdrawalThreshold);
    error KipuBank_InvalidBankCapacity(address admin, uint256 newCapacity);
    error KipuBank_InsufficientOutputAmount();
    error KipuBank_InsufficientLiquidity();
    error KipuBank_PairDoesNotExist();
    error KipuBank_InvalidAddress();
    error KipuBank_USDCNotAllowed(address token);
    error KipuBank_TokenNotAccepted(address token);
    error KipuBank_PleaseUseDepositEth(string message);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures the provided amount is greater than zero
    modifier onlyAmountsGreaterThanZero(uint256 amount) {
        if (amount == 0) revert KipuBank_InvalidAmount(msg.sender, amount);
        _;
    }

    /// @notice Validates that the pair (token, USDC) exists in the factory
    /// @param token First token to validate
    modifier pairExists(address token) {
        if (token == i_usdc) revert KipuBank_TokenNotAccepted(token);
        address pair = i_factory.getPair(token, i_usdc);
        if (pair == address(0)) {
            revert KipuBank_PairDoesNotExist();
        }
        _;
    }

    /// @notice Validates that the provided token address is non-zero
    /// @param token Token address to validate
    modifier validTokenAddresses(address token) {
        if (token == address(0)) {
            revert KipuBank_InvalidAddress();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract constructor
    /// @param _bankCap The global maximum USDC-equivalent the contract can hold
    /// @param _withdrawalThreshold The per-transaction USDC withdrawal limit
    /// @param _factory Address of the Uniswap V2 factory
    /// @param _usdc Address of the USDC token (accounting token)
    /// @param _weth Address of the WETH contract
    constructor(
        uint256 _bankCap,
        uint256 _withdrawalThreshold,
        address _factory,
        address _usdc,
        address _weth
    ) {
        if (_bankCap == 0 || _withdrawalThreshold == 0 || _bankCap < _withdrawalThreshold)
            revert KipuBank_InitializationFailed(_bankCap, _withdrawalThreshold);

        s_bankCap = _bankCap;
        s_withdrawalThreshold = _withdrawalThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        i_factory = IUniswapV2Factory(_factory);
        i_usdc = _usdc;
        i_weth = IWETH(_weth);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevent direct ETH transfers without an explicit `amountOutMin` (protects against accidental no-slippage deposits)
    receive() external payable onlyAmountsGreaterThanZero(msg.value) {
        revert KipuBank_PleaseUseDepositEth("Use depositETH(uint256 amountOutMin)");
    }

    /// @notice Prevent fallback calls that send ETH/data. Ask callers to use depositETH instead.
    fallback() external payable {
        revert KipuBank_PleaseUseDepositEth("Use depositETH(uint256 amountOutMin)");
    }

    /// @notice Deposit native ETH and specify minimum accepted USDC to protect against slippage.
    /// @dev Wraps ETH into WETH, then swaps WETH -> USDC using Uniswap V2 and credits the user's vault in USDC units.
    /// @param amountOutMin Minimum amount of USDC the user accepts to receive from the swap.
    function depositETH(uint256 amountOutMin) public payable nonReentrant onlyAmountsGreaterThanZero(msg.value) {
        // 1. Wrap ETH into WETH
        i_weth.deposit{value: msg.value}();

        // 2. Call internal swap function
        // At this point the contract owns `msg.value` WETH
        _swapAndCredit(msg.sender, address(i_weth), msg.value, amountOutMin);
    }

    /// @notice Deposit ERC20 tokens different than ETH and USDC. Token must have a direct pair with USDC on Uniswap V2.
    /// @param token Address of the input token
    /// @param amount Amount of `token` to deposit
    /// @param amountMin Minimum amount of USDC expected after the swap
    function depositToken(address token, uint256 amount, uint256 amountMin)
        external
        nonReentrant
        onlyAmountsGreaterThanZero(amount)
        pairExists(token)
    {
        if (token == i_usdc) revert KipuBank_USDCNotAllowed(token);

        // Transfer tokens from user to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Perform swap and credit user's vault in USDC
        _swapAndCredit(msg.sender, token, amount, amountMin);
    }

    /// @notice Deposit USDC directly (no swap required).
    /// @param amount Amount of USDC to deposit
    function depositUSDC(uint256 amount) external nonReentrant onlyAmountsGreaterThanZero(amount) {
        // Check bank capacity
        if (s_depositTotal + amount > s_bankCap)
            revert KipuBank_DepositRejected(msg.sender, amount, "Bank cap exceeded");

        // Interaction: transfer USDC from user
        IERC20(i_usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Effects: update user vault and totals
        s_vaults[msg.sender] += amount;
        s_depositTotal += amount;
        s_depositCount += 1;

        emit KipuBank_DepositAccepted(msg.sender, i_usdc, amount, amount);
    }

    /// @notice Withdraw USDC from the user's vault.
    /// @param _amount Amount of USDC to withdraw
    function withdrawUSDC(uint256 _amount) external nonReentrant onlyAmountsGreaterThanZero(_amount) {
        // Ensure withdrawal does not exceed vault balance
        if (_amount > s_vaults[msg.sender])
            revert KipuBank_WithdrawalRejected(msg.sender, i_usdc, _amount, "Insufficient funds");

        // Ensure withdrawal does not exceed per-transaction threshold
        if (_amount > s_withdrawalThreshold)
            revert KipuBank_WithdrawalRejected(msg.sender, i_usdc, _amount, "Withdrawal threshold exceeded");

        // Effects: update balances and counters
        s_vaults[msg.sender] -= _amount;
        s_withdrawCount += 1;
        s_depositTotal -= _amount;

        // Interaction: transfer USDC to the user
        IERC20(i_usdc).safeTransfer(msg.sender, _amount);

        emit KipuBank_WithdrawalAccepted(msg.sender, i_usdc, _amount);
    }

    /// @notice Updates the bank's total USDC capacity.
    /// @param newCapacity New bank capacity in USDC units
    function setBankCapacity(uint256 newCapacity) external onlyRole(ADMIN_ROLE) {
        if (newCapacity <= s_depositTotal)
            revert KipuBank_InvalidBankCapacity(msg.sender, newCapacity);
        s_bankCap = newCapacity;
        emit KipuBank_BankCapacityUpdated(newCapacity);
    }

    /// @notice Updates the maximum per-transaction withdrawal threshold.
    /// @param newThreshold New withdrawal threshold in USDC units
    function setWithdrawalThreshold(uint256 newThreshold)
        external
        onlyRole(ADMIN_ROLE)
        onlyAmountsGreaterThanZero(newThreshold)
    {
        s_withdrawalThreshold = newThreshold;
        emit KipuBank_WithdrawalThresholdUpdated(newThreshold);
    }

    /// @notice Grants the ADMIN_ROLE to a new address. Only DEFAULT_ADMIN_ROLE can call.
    /// @param newAdmin Address to grant ADMIN_ROLE
    function grantAdminRole(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ADMIN_ROLE, newAdmin);
        emit KipuBank_AdminRoleGranted(newAdmin);
    }

    /// @notice Revokes the ADMIN_ROLE from an address. Only DEFAULT_ADMIN_ROLE can call.
    /// @param removeThisAdmin Address to revoke ADMIN_ROLE from
    function revokeAdminRole(address removeThisAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ADMIN_ROLE, removeThisAdmin);
        emit KipuBank_AdminRoleRevoked(removeThisAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper to compute output amount using Uniswap V2 formula.
     * @param amountIn Input amount
     * @param reserveIn Reserve of the input token in the pair
     * @param reserveOut Reserve of the output token in the pair
     * @return amountOut Calculated output amount using Uniswap V2 AMM formula
     * @dev Implements: amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            revert KipuBank_InsufficientLiquidity();
        }

        // Uniswap V2 fee: 0.3% => multiplier 997 / 1000
        uint256 amountInWithFee = amountIn * 997;

        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        amountOut = numerator / denominator;
    }

    /**
     * @notice Returns the pair address for (tokenA, tokenB) from the factory.
     * @param tokenA First token
     * @param tokenB Second token
     * @return pair The pair address (may be address(0) if not created)
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return i_factory.getPair(tokenA, tokenB);
    }

    /// @notice Returns the caller's USDC vault balance.
    function viewBalance() external view returns (uint256) {
        return s_vaults[msg.sender];
    }

    function viewDepositCount() external view returns (uint256) {
        return s_depositCount;
    }

    function viewWithdrawCount() external view returns (uint256) {
        return s_withdrawCount;
    }

    function viewWithdrawalThreshold() external view returns (uint256) {
        return s_withdrawalThreshold;
    }

    function viewBankCapacity() external view returns (uint256) {
        return s_bankCap;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal helper: estimate output and validate slippage & bank cap before swap.
     * @param user User who is depositing
     * @param pair Uniswap V2 pair address for tokenIn/USDC
     * @param tokenIn Input token address
     * @param amountIn Input amount (tokenIn units)
     * @param amountOutMin Minimum acceptable USDC from user (slippage protection)
     * @return token0IsTokenIn True if token0 of pair == tokenIn
     * @return amountOutExpected Expected USDC amount calculated from reserves using `getAmountOut`
     */
    function _calculateAndCheckPreSwap(
        address user,
        address pair,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal view returns (bool token0IsTokenIn, uint256 amountOutExpected) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();

        token0IsTokenIn = token0 == tokenIn;

        amountOutExpected = getAmountOut(
            amountIn,
            token0IsTokenIn ? reserve0 : reserve1,
            token0IsTokenIn ? reserve1 : reserve0
        );

        // Preliminary checks (slippage and bank cap)
        if (amountOutExpected < amountOutMin) {
            revert KipuBank_InsufficientOutputAmount();
        }
        if (amountOutExpected + s_depositTotal > s_bankCap) {
            revert KipuBank_DepositRejected(user, amountIn, "Bank cap exceeded");
        }

        return (token0IsTokenIn, amountOutExpected);
    }

    /**
     * @notice Internal helper to apply accounting changes after a successful deposit (credits user's USDC vault).
     * @param user User to credit
     * @param amount Amount of USDC to credit (in USDC units)
     */
    function _applyChanges(address user, uint256 amount) internal {
        s_vaults[user] += amount;
        s_depositTotal += amount;
        s_depositCount += 1;
    }

    /**
     * @notice Internal function to perform an exact-input swap on a Uniswap V2 pair and credit the resulting USDC to the user.
     * @dev The function performs pre-swap estimation, transfers the input token to the pair, calls `swap(...)` with the
     *      expected output, then verifies the real USDC received and applies accounting changes.
     * @param user Address of the user performing the deposit
     * @param tokenIn Address of the input token
     * @param amountIn Exact input amount to swap (tokenIn units)
     * @param amountOutMin Minimum acceptable USDC amount (slippage protection)
     * @return amountOut Actual USDC amount received and credited to the user
     */
    function _swapAndCredit(
        address user,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    )
        internal
        validTokenAddresses(tokenIn)
        onlyAmountsGreaterThanZero(amountIn)
        pairExists(tokenIn)
        returns (uint256 amountOut)
    {
        // Get the pair for (tokenIn, USDC)
        address pair = i_factory.getPair(tokenIn, i_usdc);

        (bool token0IsTokenIn, uint256 amountOutExpected) = _calculateAndCheckPreSwap(
            user,
            pair,
            tokenIn,
            amountIn,
            amountOutMin
        );

        // Transfer tokenIn from this contract to the pair
        IERC20(tokenIn).safeTransfer(pair, amountIn);

        // Record USDC balance before swap
        uint256 balanceBefore = IERC20(i_usdc).balanceOf(address(this));

        // Determine the exact amounts to request from the pair (use expected amount)
        uint256 amount0Out = token0IsTokenIn ? 0 : amountOutExpected;
        uint256 amount1Out = token0IsTokenIn ? amountOutExpected : 0;

        // Execute swap on the pair; Uniswap V2 will send USDC to this contract
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");

        // Actual USDC received
        amountOut = IERC20(i_usdc).balanceOf(address(this)) - balanceBefore;

        // Post-swap checks (slippage and bank cap)
        if (amountOut < amountOutMin) {
            revert KipuBank_InsufficientOutputAmount();
        }
        if (amountOut + s_depositTotal > s_bankCap) {
            revert KipuBank_DepositRejected(user, amountIn, "Bank cap exceeded after swap");
        }

        // Effects: apply accounting changes
        _applyChanges(user, amountOut);

        emit KipuBank_DepositAccepted(user, tokenIn, amountIn, amountOut);

        return amountOut;
    }
}
