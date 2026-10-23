// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultToken} from "../src/VaultToken.sol";

/// @dev Drives the token with failing calls interleaved among successful ones. Every rejected call
/// must revert with the exact error and leave balances, allowances and supply untouched.
contract VaultAdversarialHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    VaultToken internal immutable token;
    address[5] internal actors;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public ghostMoved;
    uint256 public ghostRejected;
    uint256 public ghostUnexpected;

    constructor(VaultToken token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = SUPPLY;
    }

    function actorCount() external pure returns (uint256) {
        return 5;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ghostMoved += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (unlimited) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[from][spender];
        uint256 balance = expectedBalance[from];
        amount = bound(amount, 0, allowance < balance ? allowance : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[from][spender] -= amount;
        ghostMoved += amount;
    }

    /// @dev Spend more than the balance, by any positive excess up to the uint256 maximum.
    function overspendBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);
        vm.prank(from);
        try token.transfer(to, amount) {
            ghostUnexpected++;
        } catch (bytes memory reason) {
            assertEq(
                reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            ghostRejected++;
        }
    }

    /// @dev Spend more than a finite allowance. The unlimited allowance cannot be exceeded.
    function overspendAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[from][spender];
        if (allowance == type(uint256).max) return;
        uint256 amount = allowance + bound(excess, 1, type(uint256).max - allowance);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            ghostUnexpected++;
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
            );
            ghostRejected++;
        }
    }

    /// @dev Neither transfer nor transferFrom may send to the zero address, at any amount.
    function sendToZero(uint256 fromSeed, uint256 amount, bool viaAllowance) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        if (viaAllowance) {
            // The owner approves itself so the allowance check is not what stops the call.
            vm.prank(from);
            token.approve(from, amount);
            expectedAllowance[from][from] = amount;
            vm.prank(from);
            try token.transferFrom(from, address(0), amount) {
                ghostUnexpected++;
            } catch (bytes memory reason) {
                assertEq(reason, expected);
                ghostRejected++;
            }
        } else {
            vm.prank(from);
            try token.transfer(address(0), amount) {
                ghostUnexpected++;
            } catch (bytes memory reason) {
                assertEq(reason, expected);
                ghostRejected++;
            }
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        try token.approve(address(0), amount) {
            ghostUnexpected++;
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            ghostRejected++;
        }
    }

    /// @dev The token has no payable entry point: ETH sent with or without calldata is refused.
    function sendEther(uint256 fromSeed, uint256 value, bool withData) external {
        address from = _actor(fromSeed);
        value = bound(value, 1, 10 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}(withData ? abi.encodeWithSignature("deposit()") : bytes(""));
        if (ok) ghostUnexpected++;
        else ghostRejected++;
        assertEq(address(token).balance, 0);
    }

    /// @dev Unknown selectors from any holder must not succeed (no fallback, no hidden admin path).
    function callUnknown(uint256 fromSeed, bytes4 selector, uint256 arg) external {
        // Skip the token's real ABI so only absent functions are probed.
        if (
            selector == token.transfer.selector || selector == token.transferFrom.selector
                || selector == token.approve.selector || selector == token.balanceOf.selector
                || selector == token.allowance.selector || selector == token.totalSupply.selector
                || selector == token.name.selector || selector == token.symbol.selector
                || selector == token.decimals.selector || selector == token.INITIAL_SUPPLY.selector
        ) return;
        vm.prank(_actor(fromSeed));
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, _actor(arg), arg));
        if (ok) ghostUnexpected++;
        else ghostRejected++;
    }
}

contract VaultAdversarialInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    VaultToken internal token;
    VaultAdversarialHandler internal handler;
    address[5] internal actors;

    function setUp() public {
        actors = [
            makeAddr("deployer"),
            makeAddr("trader"),
            makeAddr("distributor"),
            makeAddr("poolManager"),
            address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF)
        ];
        vm.prank(actors[0]);
        token = new VaultToken();
        handler = new VaultAdversarialHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = VaultAdversarialHandler.transfer.selector;
        selectors[1] = VaultAdversarialHandler.approve.selector;
        selectors[2] = VaultAdversarialHandler.transferFrom.selector;
        selectors[3] = VaultAdversarialHandler.overspendBalance.selector;
        selectors[4] = VaultAdversarialHandler.overspendAllowance.selector;
        selectors[5] = VaultAdversarialHandler.sendToZero.selector;
        selectors[6] = VaultAdversarialHandler.approveZeroSpender.selector;
        selectors[7] = VaultAdversarialHandler.sendEther.selector;
        selectors[8] = VaultAdversarialHandler.callUnknown.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyFixedAndFullyAccounted() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchModel() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
            assertEq(token.allowance(address(0), actors[i]), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rejectedCallsNeverSucceedAndHoldNoEther() public view {
        assertEq(handler.ghostUnexpected(), 0);
        assertEq(address(token).balance, 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "vault");
        assertEq(token.symbol(), "VAULT");
        assertEq(token.decimals(), 18);
    }
}

/// @dev Stateless properties over the failure paths and arithmetic edges.
contract VaultAdversarialFuzzTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    VaultToken internal token;
    address internal deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new VaultToken();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerWithoutAllowanceCannotMoveHolderFunds(address stranger, uint256 amount) public {
        vm.assume(stranger != deployer);
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveNeverMovesBalances(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 spenderBefore = token.balanceOf(spender);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.balanceOf(owner), ownerBefore);
        assertEq(token.balanceOf(spender), spenderBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBalances(address other, uint256 amount) public {
        vm.assume(other != address(0) && other != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(other, amount);
        vm.prank(other);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(other), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitTransfersEqualSingleTransfer(address to, uint256 a, uint256 b) public {
        vm.assume(to != address(0) && to != deployer);
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(to, a);
        token.transfer(to, b);
        vm.stopPrank();
        assertEq(token.balanceOf(to), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_recipientCannotSpendMoreThanReceived(address to, uint256 amount, uint256 excess) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        excess = bound(excess, 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, to, amount, amount + excess)
        );
        vm.prank(to);
        token.transfer(deployer, amount + excess);
    }

    function test_maxUintTransferReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(makeAddr("bob"), type(uint256).max);
    }

    function test_oneWeiOverSupplyViaUnlimitedAllowanceReverts() public {
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(deployer, spender, SUPPLY + 1);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_allowanceOfMaxMinusOneIsDecremented() public {
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(deployer, spender, 1);
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
    }

    function test_etherIsRefused() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(deployer);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSignature("transfer(address,uint256)", deployer, 0));
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_noPermitOrDelegatedSpendPath() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("nonces(address)", deployer));
        assertFalse(ok);
    }

    function test_runtimeHasNoDelegatecallSelfdestructOrCallcode() public view {
        bytes memory code = address(token).code;
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            // Stop at the INVALID opcode separating runtime from metadata/data sections.
            if (op == 0xfe) break;
            assertTrue(op != 0xf4 && op != 0xff && op != 0xf2, "forbidden opcode in runtime");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            ++i;
        }
    }
}
