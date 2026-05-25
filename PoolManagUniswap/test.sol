// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/PoolManager.sol";
import "../src/types/Currency.sol";
import "../src/types/PoolKey.sol";
import "../src/interfaces/IHooks.sol";

contract MockHooks is IHooks {
    function isValidHookAddress(uint24) external pure returns (bool) {
        return true;
    }

    function beforeInitialize(PoolKey memory, uint160) external pure {}

    function afterInitialize(PoolKey memory, uint160, int24) external pure {}

    function beforeModifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        pure
    {}

    function afterModifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(PoolKey memory, SwapParams memory, bytes calldata)
        external
        pure
        returns (int256, BeforeSwapDelta, uint24)
    {
        return (0, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        PoolKey memory,
        SwapParams memory,
        BalanceDelta,
        bytes calldata,
        BeforeSwapDelta
    ) external pure returns (BalanceDelta, BalanceDelta) {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(PoolKey memory, uint256, uint256, bytes calldata) external pure {}

    function afterDonate(PoolKey memory, uint256, uint256, bytes calldata) external pure {}
}

contract PoolManagerTest is Test {
    PoolManager public poolManager;
    MockHooks public mockHooks;
    address public owner = address(1);
    address public user = address(2);

    function setUp() public {
        vm.prank(owner);
        poolManager = new PoolManager(owner);
        mockHooks = new MockHooks();
    }

    function testInitialize() public {
        Currency currency0 = CurrencyLibrary.fromId(1);
        Currency currency1 = CurrencyLibrary.fromId(2);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: mockHooks
        });

        vm.expectEmit(true, true, true, true);
        emit Initialize(
            key.toId(),
            currency0,
            currency1,
            0,
            1,
            mockHooks,
            uint160(0),
            0
        );

        poolManager.initialize(key, uint160(0));
    }

    function testModifyLiquidity() public {
        Currency currency0 = CurrencyLibrary.fromId(1);
        Currency currency1 = CurrencyLibrary.fromId(2);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: mockHooks
        });

        poolManager.initialize(key, uint160(0));

        vm.prank(user);
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -10,
                tickUpper: 10,
                liquidityDelta: 1000,
                salt: 0
            }),
            ""
        );

        assertEq(callerDelta.amount0(), 0);
        assertEq(callerDelta.amount1(), 0);
    }

    function testSwap() public {
        Currency currency0 = CurrencyLibrary.fromId(1);
        Currency currency1 = CurrencyLibrary.fromId(2);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: mockHooks
        });

        poolManager.initialize(key, uint160(0));

        vm.prank(user);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: 100,
                sqrtPriceLimitX96: 0
            }),
            ""
        );

        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function testUnlock() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlreadyUnlocked.selector));
        poolManager.unlock("");

        vm.prank(owner);
        poolManager.unlock("");

        vm.expectRevert(abi.encodeWithSelector(CurrencyNotSettled.selector));
        vm.prank(user);
        poolManager.unlock("");
    }

    function testGasReport() public {
        vm.txGasPrice(1);
        Currency currency0 = CurrencyLibrary.fromId(1);
        Currency currency1 = CurrencyLibrary.fromId(2);
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: mockHooks
        });

        poolManager.initialize(key, uint160(0));

        uint256 gasStart = gasleft();
        vm.prank(user);
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -10,
                tickUpper: 10,
                liquidityDelta: 1000,
                salt: 0
            }),
            ""
        );
        uint256 gasUsed = gasStart - gasleft();
        console.log("modifyLiquidity gas used:", gasUsed);

        gasStart = gasleft();
        vm.prank(user);
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: 100,
                sqrtPriceLimitX96: 0
            }),
            ""
        );
        gasUsed = gasStart - gasleft();
        console.log("swap gas used:", gasUsed);
    }
}