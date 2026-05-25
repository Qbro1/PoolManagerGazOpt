// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Hooks} from "./libraries/Hooks.sol";
import {Pool} from "./libraries/Pool.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Position} from "./libraries/Position.sol";
import {LPFeeLibrary} from "./libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {NoDelegateCall} from "./NoDelegateCall.sol";
import {IHooks} from "./interfaces/IHooks.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./interfaces/callback/IUnlockCallback.sol";
import {ProtocolFees} from "./ProtocolFees.sol";
import {ERC6909Claims} from "./ERC6909Claims.sol";
import {PoolId} from "./types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "./types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {BeforeSwapDelta} from "./types/BeforeSwapDelta.sol";
import {Lock} from "./libraries/Lock.sol";
import {CurrencyDelta} from "./libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "./libraries/NonzeroDeltaCount.sol";
import {CurrencyReserves} from "./libraries/CurrencyReserves.sol";
import {Extsload} from "./Extsload.sol";
import {Exttload} from "./Exttload.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";

contract PoolManager is IPoolManager, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using SafeCast for *;
    using Pool for *;
    using Hooks for IHooks;
    using CurrencyDelta for Currency;
    using LPFeeLibrary for uint24;
    using CurrencyReserves for Currency;
    using CustomRevert for bytes4;

    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;
    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;
    uint256 private _lockStatus;

    constructor(address initialOwner) ProtocolFees(initialOwner) {}

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (_lockStatus == 1) AlreadyUnlocked.selector.revertWith();
        _lockStatus = 1;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        _lockStatus = 0;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external override noDelegateCall returns (int24 tick) {
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

        key.hooks.beforeInitialize(key, sqrtPriceX96);
        PoolId id = key.toId();
        tick = _pools[id].initialize(sqrtPriceX96, key.fee.getInitialLPFee());
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);
        key.hooks.afterInitialize(key, sqrtPriceX96, tick);
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        override
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        key.hooks.beforeModifyLiquidity(key, params, hookData);
        (callerDelta, feesAccrued) = pool.modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta.toInt128(),
                tickSpacing: key.tickSpacing,
                salt: params.salt
            })
        );
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);

        BalanceDelta hookDelta;
        (callerDelta, hookDelta) = key.hooks.afterModifyLiquidity(key, params, callerDelta, feesAccrued, hookData);
        _accountPoolBalanceDelta(key, callerDelta, msg.sender);
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        override
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta)
    {
        if (params.amountSpecified == 0) SwapAmountCannotBeZero.selector.revertWith();
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        BeforeSwapDelta beforeSwapDelta;
        {
            int256 amountToSwap;
            uint24 lpFeeOverride;
            (amountToSwap, beforeSwapDelta, lpFeeOverride) = key.hooks.beforeSwap(key, params, hookData);
            swapDelta = _swap(pool, id, Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: amountToSwap,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: lpFeeOverride
            }), params.zeroForOne ? key.currency0 : key.currency1);
        }

        BalanceDelta hookDelta;
        (swapDelta, hookDelta) = key.hooks.afterSwap(key, params, swapDelta, hookData, beforeSwapDelta);
        _accountPoolBalanceDelta(key, swapDelta, msg.sender);
        if (hookDelta != BalanceDeltaLibrary.ZERO_DELTA) _accountPoolBalanceDelta(key, hookDelta, address(key.hooks));
    }

    function _swap(Pool.State storage pool, PoolId id, Pool.SwapParams memory params, Currency inputCurrency)
        internal
        returns (BalanceDelta)
    {
        (BalanceDelta delta, uint256 amountToProtocol, uint24 swapFee, Pool.SwapResult memory result) =
            pool.swap(params);
        if (amountToProtocol > 0) _updateProtocolFees(inputCurrency, amountToProtocol);
        emit Swap(id, msg.sender, delta.amount0(), delta.amount1(), result.sqrtPriceX96, result.liquidity, result.tick, swapFee);
        return delta;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        Pool.State storage pool = _getPool(poolId);
        pool.checkPoolInitialized();
        key.hooks.beforeDonate(key, amount0, amount1, hookData);
        delta = pool.donate(amount0, amount1);
        emit Donate(poolId, msg.sender, amount0, amount1);
        key.hooks.afterDonate(key, amount0, amount1, hookData);
        _accountPoolBalanceDelta(key, delta, msg.sender);
    }

    function sync(Currency currency) external override {
        if (currency.isAddressZero()) CurrencyReserves.resetCurrency();
        else CurrencyReserves.syncCurrencyAndReserves(currency, currency.balanceOfSelf());
    }

    function take(Currency currency, address to, uint256 amount) external override onlyWhenUnlocked {
        unchecked { _accountDelta(currency, -(amount.toInt128()), msg.sender); }
        currency.transfer(to, amount);
    }

    function settle() external payable override onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    function settleFor(address recipient) external payable override onlyWhenUnlocked returns (uint256) {
        return _settle(recipient);
    }

    function clear(Currency currency, uint256 amount) external override onlyWhenUnlocked {
        int256 current = currency.getDelta(msg.sender);
        if (amount.toInt128() != current) MustClearExactPositiveDelta.selector.revertWith();
        unchecked { _accountDelta(currency, -(amount.toInt128()), msg.sender); }
    }

    function mint(address to, uint256 id, uint256 amount) external override onlyWhenUnlocked {
        unchecked {
            Currency currency = CurrencyLibrary.fromId(id);
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            _mint(to, currency.toId(), amount);
        }
    }

    function burn(address from, uint256 id, uint256 amount) external override onlyWhenUnlocked {
        Currency currency = CurrencyLibrary.fromId(id);
        _accountDelta(currency, amount.toInt128(), msg.sender);
        _burnFrom(from, currency.toId(), amount);
    }

    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external override {
        if (!key.fee.isDynamicFee() || msg.sender != address(key.hooks)) UnauthorizedDynamicLPFeeUpdate.selector.revertWith();
        newDynamicLPFee.validate();
        _pools[key.toId()].setLPFee(newDynamicLPFee);
    }

    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = CurrencyReserves.getSyncedCurrency();
        if (currency.isAddressZero()) paid = msg.value;
        else {
            if (msg.value > 0) NonzeroNativeValue.selector.revertWith();
            uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
            paid = CurrencyReserves.syncCurrencyAndReserves(currency, currency.balanceOfSelf()) - reservesBefore;
            CurrencyReserves.resetCurrency();
        }
        unchecked { _accountDelta(currency, paid.toInt128(), recipient); }
    }

    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;
        (int256 previous, int256 next) = currency.applyDelta(target, delta);
        if (next == 0) NonzeroDeltaCount.decrement();
        else if (previous == 0) NonzeroDeltaCount.increment();
    }

    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }

    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    function _isUnlocked() internal view override returns (bool) {
        return _lockStatus == 0;
    }
}