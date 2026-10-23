// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultToken} from "../src/VaultToken.sol";

/// @dev Test-only deployment and transfer probe; never part of a launch.
contract VaultDeploymentProbe {
    function deploy(bytes32 salt) external returns (VaultToken) {
        return new VaultToken{salt: salt}();
    }

    function move(VaultToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract VaultTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    VaultToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new VaultToken();
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "vault");
        assertEq(token.symbol(), "VAULT");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        VaultToken fresh = new VaultToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
    }

    function testFuzz_create2MintsOnlyToImmediateDeployer(bytes32 salt) public {
        VaultDeploymentProbe factory = new VaultDeploymentProbe();
        // The outer caller and tx.origin must not receive a factory deployment's supply.
        vm.prank(alice, alice);
        VaultToken launched = factory.deploy(salt);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_transferMovesExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, 125e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 125e18));
        assertEq(token.balanceOf(deployer), SUPPLY - 125e18);
        assertEq(token.balanceOf(alice), 125e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEntireSupply() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransferPreservesBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferInsufficientBalanceRevertsWithoutChanges() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalEmitsEventWithoutMovingTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(deployer, spender, 400e18);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 400e18));
        assertEq(token.allowance(deployer, spender), 400e18);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_approvalCanBeReplacedAndRevoked() public {
        vm.startPrank(deployer);
        token.approve(spender, 400e18);
        token.approve(spender, 20e18);
        assertEq(token.allowance(deployer, spender), 20e18);
        token.approve(spender, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    function test_approvalMayExceedCurrentBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, spender), SUPPLY);
    }

    function test_transferFromSpendsAllowanceAndEmitsTransfer() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, 7e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 7e18));
        assertEq(token.balanceOf(alice), 7e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 7e18);
        assertEq(token.allowance(deployer, spender), 13e18);
    }

    function test_transferFromExhaustsAllowanceAndCannotSpendTwice() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 20e18));
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(alice), 20e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromUnlimitedAllowanceIsNotDecreased() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertTrue(token.transferFrom(deployer, bob, SUPPLY - 1));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }

    function test_transferFromSelfConsumesAllowanceWithoutMovingBalance() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 20e18));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromOwnerStillNeedsAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromWrongSpenderReverts() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), 20e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromInsufficientBalanceRestoresAllowance() public {
        vm.prank(alice);
        token.approve(spender, 20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 20e18));
        vm.prank(spender);
        token.transferFrom(alice, bob, 20e18);
        assertEq(token.allowance(alice, spender), 20e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToZeroRestoresAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 20e18);
        assertEq(token.allowance(deployer, spender), 20e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromZeroSourceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryDistributionAndPoolTransfersHaveNoTax() public {
        VaultDeploymentProbe factory = new VaultDeploymentProbe();
        VaultToken launched = factory.deploy(keccak256("launch transfer smoke test"));
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 8 / 10;
        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, poolManager, pool));
        assertTrue(factory.move(launched, alice, SUPPLY - swarm - pool));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.balanceOf(alice), SUPPLY / 10);

        vm.prank(distributor);
        assertTrue(launched.transfer(bob, swarm));
        assertEq(launched.balanceOf(bob), swarm);
        assertEq(launched.balanceOf(distributor), 0);

        // Exercise the token legs of a buy and a sell. This is not an AMM implementation.
        vm.prank(poolManager);
        assertTrue(launched.transfer(spender, 100e18));
        assertEq(launched.balanceOf(spender), 100e18);
        vm.prank(spender);
        assertTrue(launched.transfer(poolManager, 100e18));
        assertEq(launched.balanceOf(spender), 0);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_noMintBurnOwnershipOrPrivilegedBalanceControls() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1e18);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1e18);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1e18);
        calls[3] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1e18);
        calls[4] = abi.encodeWithSignature("pause()");
        calls[5] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[6] = abi.encodeWithSignature("freeze(address)", alice);
        calls[7] = abi.encodeWithSignature("seize(address)", alice);
        calls[8] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[9] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[10] = abi.encodeWithSignature("initialize(address)", bob);
        calls[11] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[12] = abi.encodeWithSignature("owner()");
        calls[13] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[14] = abi.encodeWithSignature("setBlacklist(address,bool)", alice, true);

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(bob);
            (bool strangerSuccess,) = address(token).call(calls[i]);
            assertFalse(strangerSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));
        assertEq(token.balanceOf(bob), 100e18);
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_transferFromTracksFiniteAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowance);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(deployer, spender), allowance - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), allowance);
    }
}
