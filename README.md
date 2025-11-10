# KipuBankV3
## Funcionalidades añadidas
En KipuBank versión 3, se añadio la capacidad de realizar cualquier un deposito con cualquier token que tenga un par directo con USDC, esto se realizo mediante el uso de UniSwapV2.

---

## Constructor

constructor(
    uint256 _bankCap,
    uint256 _withdrawalThreshold,
    address _factory,
    address _usdc,
    address _weth
)

| Nombre                 | Tipo      | Descripción                                                                                  |
| ---------------------- | --------- | -------------------------------------------------------------------------------------------- |
| `_bankCap`             | `uint256` | Capacidad total máxima del banco expresada en valor equivalente a USDC.                      |
| `_withdrawalThreshold` | `uint256` | Límite máximo de retiro por transacción, también expresado en USDC.                          |
| `_factory`             | `address` | Dirección del contrato **Uniswap V2 Factory**, utilizada para encontrar los pares de tokens. |
| `_usdc`                | `address` | Dirección del token **USDC**, que actúa como unidad base de contabilidad.                    |
| `_weth`                | `address` | Dirección del contrato **WETH**, usado para envolver ETH antes de realizar swaps.            |

**Detalles**

-Valida que _bankCap y _withdrawalThreshold sean mayores a cero, y que el umbral de retiro no supere la capacidad del banco.

-Otorga al creador del contrato los roles DEFAULT_ADMIN_ROLE y ADMIN_ROLE.

-Inicializa las direcciones de Uniswap Factory, USDC y WETH.

---

## Funciones principales de usuario

`depositETH(uint256 amountOutMin)`

Permite al usuario depositar ETH nativo.
El contrato automáticamente envuelve el ETH en WETH y luego lo intercambia por USDC usando Uniswap V2.

**Parámetros**:

`amountOutMin`: Monto mínimo de USDC que el usuario acepta recibir (protección contra slippage).

**Eventos emitidos**:

KipuBank_DepositAccepted

`depositToken(address token, uint256 amount, uint256 amountMin)`

Permite depositar cualquier token ERC20 distinto de USDC o ETH.
El token debe tener un par directo con USDC en Uniswap V2. El contrato realiza el swap automáticamente a USDC.

**Parámetros**:

`token`: Dirección del token que se desea depositar.

`amount`: Cantidad del token que se enviará al contrato.

`amountMin`: Cantidad mínima de USDC que el usuario acepta recibir después del swap.

**Eventos emitidos**:

KipuBank_DepositAccepted

`depositUSDC(uint256 amount)`

Permite depositar directamente USDC, sin realizar ningún intercambio.

**Parámetros**:

`amount`: Cantidad de USDC a depositar.

**Validaciones**:

No puede superar la capacidad total (s_bankCap).

**Eventos emitidos**:

KipuBank_DepositAccepted

`withdrawUSDC(uint256 _amount)`

Permite retirar USDC desde el vault personal del usuario.

**Parámetros**:

`_amount`: Cantidad de USDC que el usuario desea retirar.

**Validaciones**:

No puede exceder el saldo del usuario.

No puede superar el límite de retiro por transacción (s_withdrawalThreshold).

**Eventos emitidos**:

KipuBank_WithdrawalAccepted

---

## Funciones administrativas

Estas funciones solo pueden ser ejecutadas por direcciones con el rol ADMIN_ROLE o DEFAULT_ADMIN_ROLE.

`setBankCapacity(uint256 newCapacity)`

Actualiza la capacidad máxima total del banco (en USDC).
Debe ser mayor al total actualmente depositado.

`setWithdrawalThreshold(uint256 newThreshold)`

Cambia el límite máximo de retiro por transacción.

`grantAdminRole(address newAdmin)`

Otorga el rol de administrador a una nueva dirección.
Solo puede ser llamado por quien tenga el rol DEFAULT_ADMIN_ROLE.

`revokeAdminRole(address removeThisAdmin)`

Revoca el rol de administrador a una dirección existente.

---

## Funciones de consulta
| Función                                                                 | Descripción                                                                       |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `viewBalance()`                                                         | Devuelve el saldo en USDC del usuario que llama.                                  |
| `viewDepositCount()`                                                    | Muestra la cantidad total de depósitos realizados.                                |
| `viewWithdrawCount()`                                                   | Muestra la cantidad total de retiros realizados.                                  |
| `viewWithdrawalThreshold()`                                             | Devuelve el límite de retiro actual.                                              |
| `viewBankCapacity()`                                                    | Devuelve la capacidad total del banco.                                            |
| `getPair(address tokenA, address tokenB)`                               | Devuelve la dirección del par Uniswap entre dos tokens.                           |
| `getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)` | Calcula la cantidad de salida esperada en un swap según la fórmula de Uniswap V2. |

---

## Notas de decisiones

En versiones posteriores del contrato podría resultar conveniente **migrar la integración de Uniswap** hacia el uso del **Router** en lugar de la **Factory**, o bien adoptar una versión más avanzada del protocolo (por ejemplo, **Uniswap V3** o **V4** una vez establecida su adopción).

El uso del **Router** proporcionaría una **mayor abstracción y simplicidad en el código**, ya que encapsula la lógica de intercambio de tokens y gestión de pares, evitando la necesidad de calcular manualmente las reservas o la cantidad esperada de salida (`getAmountOut`).  
Esto permitiría un contrato más **limpio, mantenible y seguro**, reduciendo la complejidad de las funciones de depósito y conversión.

Además, una futura migración a una versión más reciente de Uniswap podría mejorar la **eficiencia del gas**, la **precisión de precios** y ofrecer nuevas funcionalidades como **liquidez concentrada** o **mejor control de slippage**, optimizando así la experiencia del usuario y la robustez general del sistema.

