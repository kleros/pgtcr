// SPDX-License-Identifier: MIT

pragma solidity ^0.8;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PermanentGTCR} from "../src/PermanentGTCR.sol";
import {PermanentGTCRFactory} from "../src/PermanentGTCRFactory.sol";

import {IEvidence} from "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import {CentralizedArbitratorWithAppeal, IArbitrator, IArbitrable} from "@kleros/erc-792/contracts/examples/CentralizedArbitratorWithAppeal.sol";

contract PolloCoin is ERC20 {
    constructor(uint256 supply) ERC20("PolloCoin", "CAW") {
        _mint(msg.sender, supply);
    }
}

contract PGTCRTest is Test {
    address alice = vm.addr(1);
    address aliceRefuser = address(1);
    address bob = vm.addr(2);
    address eve = vm.addr(3);
    address governor = vm.addr(4);
    address king = vm.addr(5);
    
    PermanentGTCR pgtcrTemplate = new PermanentGTCR();
    PermanentGTCRFactory pgtcrFactory = new PermanentGTCRFactory(address(pgtcrTemplate));
    CentralizedArbitratorWithAppeal arbitrator;

    bytes arbitratorExtraData = "extraData";
    string metaEvidence = "metaEvidence";
    ERC20 token;
    uint256 submissionMinDeposit = 1e18;
    uint256[4] periods = [
      7 days,
      1 days,
      1 days,
      7 days
    ];
    uint256[4] multipliers = [
      10_000,
      10_000,
      20_000,
      5_000
    ];
}

contract Deploy is PGTCRTest {
  function setUp() public {
    token = new PolloCoin(1e20);
    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();
  }

  function test_Deploy() public {
    vm.expectEmit(true, true, false, false);
    emit IEvidence.MetaEvidence(0, metaEvidence);
    vm.expectEmit(false, false, false, false);
    emit PermanentGTCRFactory.NewGTCR(PermanentGTCR(address(0))); // address could be precomputed but skip

    PermanentGTCR instance = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );
    vm.assertEq(address(instance.arbitrator()), address(arbitrator));
    (uint48 arbTimestamp, bytes memory extraData) = instance.arbitrationParamsChanges(0);
    vm.assertEq(arbTimestamp, 0);
    vm.assertEq(extraData, arbitratorExtraData);
    vm.assertEq(instance.governor(), governor);
    vm.assertEq(address(instance.token()), address(token));
    vm.assertEq(instance.submissionMinDeposit(), submissionMinDeposit);
    vm.assertEq(instance.submissionPeriod(), periods[0]);
    vm.assertEq(instance.reinclusionPeriod(), periods[1]);
    vm.assertEq(instance.withdrawingPeriod(), periods[2]);
    vm.assertEq(instance.arbitrationParamsCooldown(), periods[3]);

    vm.assertEq(instance.sharedStakeMultiplier(), multipliers[0]);
    vm.assertEq(instance.winnerStakeMultiplier(), multipliers[1]);
    vm.assertEq(instance.loserStakeMultiplier(), multipliers[2]);
    vm.assertEq(instance.challengeStakeMultiplier(), multipliers[3]);
  }

  function test_CannotReinitialize() public {
    PermanentGTCR instance = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );

    vm.expectRevert(PermanentGTCR.AlreadyInitialized.selector);
    instance.initialize(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );
  }
}

contract AddItem is PGTCRTest {
  PermanentGTCR pgtcr;

  function setUp() public {
    // Alice starts with 100 CAW and 0.1 ETH
    vm.deal(alice, 1e17);
    vm.prank(alice);
    token = new PolloCoin(1e20);
    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();
    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );
  }

  function test_AddItem() public {
    // Need to supply arb deposit
    uint256 arbDeposit = arbitrator.arbitrationCost(arbitratorExtraData);

    vm.startPrank(alice);
    token.approve(address(pgtcr), submissionMinDeposit);

    vm.expectEmit(true, false, false, true);
    emit PermanentGTCR.NewItem(keccak256(abi.encodePacked("item1")), "item1");
    pgtcr.addItem{value: arbDeposit}("item1", submissionMinDeposit);
    vm.stopPrank();

    // Ensure data was written and returns as expected
    (PermanentGTCR.Status status, uint128 arbitrationDeposit, uint120 challengeCount,
    address submitter, uint48 includedAt, uint48 withdrawingTimestamp,
    uint256 stake) = pgtcr.items(keccak256(abi.encodePacked("item1")));

    vm.assertEq(uint8(status), 1);
    vm.assertEq(arbitrationDeposit, uint128(arbDeposit));
    vm.assertEq(challengeCount, 0);
    vm.assertEq(submitter, alice);
    vm.assertEq(includedAt, uint48(block.timestamp));
    vm.assertEq(withdrawingTimestamp, 0);
    vm.assertEq(stake, submissionMinDeposit);
  }

  function test_AddItemExtraDeposit() public {
    bytes32 itemID = keccak256(abi.encodePacked("item1"));
    uint256 extraDeposit = submissionMinDeposit * 2;
    uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);

    vm.startPrank(alice);
    token.approve(address(pgtcr), extraDeposit);
    pgtcr.addItem{value: arbCost}("item1", extraDeposit);

    uint256 stake;
    (, , , , , , stake) = pgtcr.items(itemID);
    assertEq(stake, extraDeposit);
  }

  function test_AddItemExcessArbValue() public {
    bytes32 itemID = keccak256(abi.encodePacked("item1"));
    uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);
    uint256 prebalance = alice.balance;

    vm.startPrank(alice);
    token.approve(address(pgtcr), submissionMinDeposit);
    pgtcr.addItem{value: prebalance}("item1", submissionMinDeposit);

    (, uint256 arbitrationDeposit, , , , , ) = pgtcr.items(itemID);
    assertEq(arbitrationDeposit, arbCost);
    assertEq(address(pgtcr).balance, arbCost);
    assertEq(alice.balance, prebalance - arbCost);
  }

  function test_AddItemExcessArbValueRefuseSend() public {
      bytes32 itemID = keccak256(abi.encodePacked("item1"));
      uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);
      vm.deal(aliceRefuser, 1e18);
      uint256 prebalance = aliceRefuser.balance;
      // send come CAW to aliceRefuser so she can submit
      vm.prank(alice);
      token.transfer(aliceRefuser, 1e18);

      vm.startPrank(aliceRefuser);
      token.approve(address(pgtcr), submissionMinDeposit);
      pgtcr.addItem{value: aliceRefuser.balance}("item1", submissionMinDeposit);

      (, uint256 arbitrationDeposit, , , , , ) = pgtcr.items(itemID);
      assertEq(arbitrationDeposit, arbCost);
      assertEq(address(pgtcr).balance, prebalance); // since aliceRefuser refuses to receive, funds get stuck in contract
      assertEq(aliceRefuser.balance, 0);
      
  }

  function test_AddItemWhenNotEnoughDeposit() public {
      uint256 badDeposit = submissionMinDeposit - 1;
      uint256 arbCost    = arbitrator.arbitrationCost(arbitratorExtraData);

      vm.startPrank(alice);
      token.approve(address(pgtcr), badDeposit);
      vm.expectRevert(PermanentGTCR.BelowDeposit.selector);
      pgtcr.addItem{value: arbCost}("item1", badDeposit);
  }

  function test_AddItemWhenNotEnoughArbDeposit() public {
      uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);

      vm.startPrank(alice);
      token.approve(address(pgtcr), submissionMinDeposit);
      vm.expectRevert(PermanentGTCR.BelowArbitrationDeposit.selector);
      pgtcr.addItem{value: arbCost - 1}("item1", submissionMinDeposit);
  }

  function test_AddItemTwice() public {
      bytes32 itemID = keccak256(abi.encodePacked("item1"));
      uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);

      vm.startPrank(alice);
      token.approve(address(pgtcr), submissionMinDeposit);
      pgtcr.addItem{value: arbCost}("item1", submissionMinDeposit);

      vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
      pgtcr.addItem{value: arbCost}("item1", submissionMinDeposit);
  }

  function test_AddItemAfterBecameAbsentOnlyEmitsStatusChange() public {
      bytes32 itemID = keccak256(abi.encodePacked("item1"));
      uint256 arbCost = arbitrator.arbitrationCost(arbitratorExtraData);

      vm.startPrank(alice);
      token.approve(address(pgtcr), submissionMinDeposit);
      pgtcr.addItem{value: arbCost}("item1", submissionMinDeposit);
      pgtcr.startWithdrawItem(itemID);
      vm.warp(block.timestamp + 1000 days);
      pgtcr.withdrawItem(itemID);

      token.approve(address(pgtcr), submissionMinDeposit);
      vm.expectEmit(true, true, true, true);
      emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Submitted); // instead of NewItem
      pgtcr.addItem{value: arbCost}("item1", submissionMinDeposit);
  }
}

contract WithdrawItem is PGTCRTest {
  PermanentGTCR pgtcr;
  bytes32 itemID;
  uint256 arbCost;

  function setUp() public {
    vm.warp(1745776000); // o/w there are underflows when calculating settings.
    vm.deal(alice, 1 ether);

    vm.prank(alice);
    token = new PolloCoin(1e20);
    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();
    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );

    arbCost = arbitrator.arbitrationCost(arbitratorExtraData);

    vm.startPrank(alice);
    token.approve(address(pgtcr), submissionMinDeposit);
    pgtcr.addItem{value: arbCost}("item1", submissionMinDeposit);
    vm.stopPrank();

    itemID = keccak256(abi.encodePacked("item1"));
  }

  function test_WithdrawItem() public {
    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit PermanentGTCR.ItemStartsWithdrawing(itemID);

    vm.prank(alice);
    pgtcr.startWithdrawItem(itemID);

    ( , , , , , uint48 wTimestamp, ) = pgtcr.items(itemID);
    assertEq(wTimestamp, uint48(block.timestamp));

    // now withdraw the item
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod());

    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(address(pgtcr), alice, submissionMinDeposit);
    vm.expectEmit(true, true, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Absent);

    uint256 aliceEthBefore = alice.balance;
    vm.prank(alice);
    pgtcr.withdrawItem(itemID);

    assertEq(alice.balance, aliceEthBefore + arbCost);
    (PermanentGTCR.Status status, , , , , , ) = pgtcr.items(itemID);
    assertEq(uint8(status), 0); // after withdrawing, Absent
  }

  function test_NonSubmitterCannotStartWithdraw() public {
    vm.prank(bob);
    vm.expectRevert(PermanentGTCR.SubmitterOnly.selector);
    pgtcr.startWithdrawItem(itemID);
  }

  function test_NonSubmitterCanExecuteWithdraw() public {
    vm.prank(alice);
    pgtcr.startWithdrawItem(itemID);
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod());
    vm.prank(bob);
    pgtcr.withdrawItem(itemID);
  }

  function test_CannotStartWithdrawOnNonExistingItem() public {
    bytes32 fakeID = keccak256("fake");
    vm.prank(alice);
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.startWithdrawItem(fakeID);
  }

  function test_CannotStartWithdrawAfterWithdrawn() public {
    vm.startPrank(alice);
    pgtcr.startWithdrawItem(itemID);
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod());
    pgtcr.withdrawItem(itemID);

    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.startWithdrawItem(itemID);
  }

  function test_CannotWithdrawTooEarly() public {
    vm.startPrank(alice);
    pgtcr.startWithdrawItem(itemID);
    vm.expectRevert(PermanentGTCR.ItemWithdrawingNotYet.selector);
    pgtcr.withdrawItem(itemID); // no time has passed
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod() - 10);
    vm.expectRevert(PermanentGTCR.ItemWithdrawingNotYet.selector);
    pgtcr.withdrawItem(itemID); // not ENOUGH time has passed
  }

  function test_CannotWithdrawWhenDisputed() public {
    uint256 challengeStake = submissionMinDeposit * pgtcr.challengeStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();
    vm.prank(alice);
    token.transfer(bob, challengeStake);

    uint256 arb = arbitrator.arbitrationCost(arbitratorExtraData);
    vm.deal(bob, arb);

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    pgtcr.challengeItem{value: arb}(itemID, "");
    vm.stopPrank();

    vm.prank(alice);
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.withdrawItem(itemID);
  }
}

contract ChallengeItem is PGTCRTest {
  PermanentGTCR pgtcr;
  bytes32 itemID;
  uint256 arbCost;
  uint256 stake;
  uint256 challengeStake;

  function setUp() public {
    vm.warp(1745776000); // o/w there are underflows when calculating settings.
    vm.deal(alice, 2 ether);
    vm.deal(bob, 2 ether);

    vm.prank(alice);
    token = new PolloCoin(1e20);
    vm.prank(alice);
    token.transfer(bob, 1e19);

    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();

    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );

    arbCost = arbitrator.arbitrationCost(arbitratorExtraData);
    stake = submissionMinDeposit;
    challengeStake = stake * pgtcr.challengeStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();

    vm.startPrank(alice);
    token.approve(address(pgtcr), stake);
    pgtcr.addItem{value: arbCost}("item1", stake);
    vm.stopPrank();

    itemID = keccak256(abi.encodePacked("item1"));
  }

  function test_ChallengeItemNormal() public {
    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    uint256 bobEthBefore = bob.balance;

    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(bob, address(pgtcr), challengeStake);

    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Dispute(IArbitrator(arbitrator), 0, 0, uint256(itemID));
    pgtcr.challengeItem{value: arbCost}(itemID, "");
    assertEq(bob.balance, bobEthBefore - arbCost);

    (PermanentGTCR.Status status, , uint120 reqCount, , , , uint256 _stake) = pgtcr.items(itemID);
    assertEq(uint8(status), 3); // Disputed
    assertEq(reqCount, 1);
    assertEq(_stake, stake);
    assertEq(address(pgtcr).balance, arbCost);
  }

  function test_ChallengeNonExistingReverts() public {
    bytes32 fakeID = keccak256("fake");
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    vm.prank(bob);
    pgtcr.challengeItem{value: arbCost}(fakeID, "");
  }

  function test_ChallengeAlreadyDisputedReverts() public {
    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
    token.approve(address(pgtcr), challengeStake);

    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
  }

  function test_ChallengeAfterWithdrawnReverts() public {
    vm.prank(alice);
    pgtcr.startWithdrawItem(itemID);
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod());
    pgtcr.withdrawItem(itemID);

    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    vm.prank(bob);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
  }

  function test_ChallengeAfterUnexecutedWithdrawnReverts() public {
    vm.prank(alice);
    pgtcr.startWithdrawItem(itemID);
    vm.warp(block.timestamp + pgtcr.withdrawingPeriod());

    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    vm.prank(bob);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
  }

  function test_ChallengeInsufficientTokenReverts() public {
    vm.startPrank(bob);
    vm.expectRevert(PermanentGTCR.TransferFailed.selector); // ERC20 transfer fails because unapproved
    pgtcr.challengeItem{value: arbCost}(itemID, "");

    token.approve(address(pgtcr), challengeStake - 1); // ERC20 transfer fails because not enough approved
    vm.expectRevert(PermanentGTCR.TransferFailed.selector); 
    pgtcr.challengeItem{value: arbCost}(itemID, "");
  }

  function test_ChallengeInsufficientArbDepositReverts() public {
    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    vm.expectRevert(PermanentGTCR.BelowArbitrationDeposit.selector);
    pgtcr.challengeItem{value: arbCost - 1}(itemID, "");
  }

  function test_ChallengeExcessArbDepositRefunded() public {
    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    uint256 bobEthBefore = bob.balance;
    pgtcr.challengeItem{value: bob.balance}(itemID, "");
    assertEq(bob.balance, bobEthBefore - arbCost);
  }

  function test_ChallengeWithEvidenceEmitsEvidence() public {
    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);

    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Dispute(IArbitrator(arbitrator), 0, 0, uint256(itemID));
    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Evidence(IArbitrator(arbitrator), uint256(itemID), bob, "evidence");
    pgtcr.challengeItem{value: arbCost}(itemID, "evidence");
  }

  function test_ChangeArbParams() public {
    vm.expectEmit(true, false, false, true, address(pgtcr));
    emit IEvidence.MetaEvidence(1, "m1");

    vm.prank(governor);
    pgtcr.changeArbitrationParams("d1", "m1");

    (uint48 ts, bytes memory ed) = pgtcr.arbitrationParamsChanges(1);
    assertEq(ed, bytes("d1"));
    // arbitrationParamsChanges length not available publicly
    assertEq(uint256(ts), block.timestamp);
  }

  function test_ChangeArbParamsNotGovernor() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    vm.prank(alice);
    pgtcr.changeArbitrationParams("d1", "m1");
  }

  function test_ArbParamsCooldownLogic() public {
    // init settings have ID 0
    // first change, 1 week + change elapses so this will be arb settings of challenge, ID 1
    vm.prank(governor);
    pgtcr.changeArbitrationParams("d1", "m1");
    vm.warp(block.timestamp + periods[3] + 1 days);

    // second change, but not enough time will pass for it to trigger, ID 2
    vm.prank(governor);
    pgtcr.changeArbitrationParams("d2", "m2");
    vm.warp(block.timestamp + 1 days);

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);

    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Dispute(
      IArbitrator(address(arbitrator)),
      0, // arbitrator disputeID
      1, // metaEvidenceID
      uint256(itemID)
    );
    pgtcr.challengeItem{value: arbCost}(itemID, "");
    vm.stopPrank();

    (uint80 arbIndex, , , , ,) = pgtcr.challenges(itemID, 0);
    assertEq(arbIndex, 1);

    // create a new different dispute. since item was included after last change, must have settings ID 2
    vm.startPrank(alice);
    token.approve(address(pgtcr), stake);
    pgtcr.addItem{value: arbCost}("item2", stake);
    vm.stopPrank();
    bytes32 itemID2 = keccak256(abi.encodePacked("item2"));

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Dispute(
      IArbitrator(address(arbitrator)),
      1, // arbitrator disputeID
      2, // metaEvidenceID
      uint256(itemID2)
    );
    pgtcr.challengeItem{value: arbCost}(itemID2, "");
    (uint80 arbIndex2, , , , ,) = pgtcr.challenges(itemID2, 0);
    assertEq(arbIndex2, 2);
  }
}

contract AppealRuleAndContribs is PGTCRTest {
  PermanentGTCR pgtcr;
  bytes32 itemID;
  uint256 arbCost;
  uint256 stake;
  uint256 challengeStake;
  uint256 disputeID;

  function setUp() public {
    vm.warp(1745776000); // o/w there are underflows when calculating settings.
    vm.deal(alice, 2 ether);
    vm.deal(bob, 2 ether);
    vm.deal(eve, 2 ether);

    vm.prank(alice);
    token = new PolloCoin(1e20);
    vm.prank(alice);
    token.transfer(bob, 1e19);

    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();

    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );

    arbCost = arbitrator.arbitrationCost(arbitratorExtraData);
    stake = submissionMinDeposit;
    challengeStake = stake * pgtcr.challengeStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();

    vm.startPrank(alice);
    token.approve(address(pgtcr), stake);
    pgtcr.addItem{value: arbCost}("item1", stake);
    vm.stopPrank();

    itemID = keccak256(abi.encodePacked("item1"));

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
    vm.stopPrank();

    disputeID = 0;
  }

  function test_Rule_NoAppeal_Submitter() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.Submitter));
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Reincluded);
    arbitrator.executeRuling(0);
    // item was "Reincluded"
    (PermanentGTCR.Status status, uint128 arbitrationDeposit, uint120 challengeCount,
    address submitter, uint48 includedAt, uint48 withdrawingTimestamp,
    uint256 stake) = pgtcr.items(itemID);

    vm.assertEq(uint8(status), 2); // Reincluded
    vm.assertEq(arbitrationDeposit, uint128(arbCost));
    vm.assertEq(challengeCount, 1);
    vm.assertEq(submitter, alice);
    vm.assertEq(includedAt, uint48(block.timestamp));
    vm.assertEq(withdrawingTimestamp, 0);
    vm.assertEq(stake, submissionMinDeposit + challengeStake);
  }

  function test_Rule_Appeal_OutsidePeriod() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (uint256 appealStart, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp((appealStart + appealEnd) / 2 + 1); // outside losing period
    // bob will appeal for himself but its too late
    vm.startPrank(bob);

    uint256 loserAppealFund = arbitrator.appealCost(disputeID, "")
      + arbitrator.appealCost(disputeID, "") * pgtcr.loserStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();

    vm.expectRevert(PermanentGTCR.AppealLoserNotWithinPeriod.selector);
    pgtcr.fundAppeal{value: loserAppealFund}(itemID, PermanentGTCR.Party.Challenger);
    vm.stopPrank();

    vm.warp(appealEnd + 1); // outside appeal period

    vm.startPrank(alice);
    vm.expectRevert(PermanentGTCR.AppealNotWithinPeriod.selector);
    pgtcr.fundAppeal{value: loserAppealFund}(itemID, PermanentGTCR.Party.Challenger);
    vm.stopPrank();
  }

  function test_Rule_NoAppeal_Submitter_WasWithdrawing() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    // alice starts a withdraw. maybe policy was modified and item would be wrong.
    vm.prank(alice);
    pgtcr.startWithdrawItem(itemID);

    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.Submitter));
    vm.expectEmit(true, true, false, true, address(token));
    // Alice will get her original deposit + Bob's challenger stake
    emit IERC20.Transfer(address(pgtcr), alice, submissionMinDeposit + challengeStake);
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Absent);
    arbitrator.executeRuling(0);
    // item was Withdrawn, so must be Absent
    (PermanentGTCR.Status status, uint128 arbitrationDeposit, uint120 challengeCount,
    address submitter, uint48 includedAt, uint48 withdrawingTimestamp,
    uint256 stake) = pgtcr.items(itemID);

    // Even though item is now Absent, rest of values remain the same. except challengeCount, they won't matter
    // as e.g. amounts cannot be withdrawn any longer as item being Absent prevents it
    // if item becomes Submitted again, they'll get overwritten
    vm.assertEq(uint8(status), 0); // Absent
    vm.assertEq(arbitrationDeposit, uint128(arbCost));
    vm.assertEq(challengeCount, 1); // It's critical this value remains 1
    vm.assertEq(submitter, alice);
    vm.assertEq(includedAt, uint48(block.timestamp)); // set before withdrawal was triggered
    vm.assertEq(withdrawingTimestamp, uint48(block.timestamp)); // is not reset unless addItem happens later
    vm.assertEq(stake, submissionMinDeposit + challengeStake); // set before withdrawal was triggered, cannot be withdrawn again

    // Alice should have in her balance the exact amount she started with, 2 ether
    // Because she got the arbitration deposit back
    vm.assertEq(alice.balance, 2 ether);
    // Bob lost the arbitration deposit
    vm.assertEq(bob.balance, 2 ether - arbCost);
  }

  function test_Rule_FailsIfReincluded() public {
    // Needs to get into a dispute again to get ruled
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    arbitrator.executeRuling(0); // Item is now Reincluded

    vm.expectRevert(); // CentralizedArbitratorWithAppeal is non malicious so cannot be retriggered like this :(
    arbitrator.executeRuling(0);

    vm.prank(address(arbitrator)); // but we can test it like this
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.rule(disputeID, uint256(PermanentGTCR.Party.Submitter));
  }

  function test_Rule_FailsIfAbsent() public {
    // Deposits could be drained if arbitrator was malicious. They fail to do it like this, but can do it with next test.
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    arbitrator.executeRuling(0); // Item is now Reincluded

    vm.expectRevert(); // CentralizedArbitratorWithAppeal is non malicious so cannot be retriggered like this :(
    arbitrator.executeRuling(0);

    vm.prank(address(arbitrator)); // but we can test it like this
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.rule(disputeID, uint256(PermanentGTCR.Party.Submitter));
  }

  function test_Rule_KnownTrustIssue_ArbitratorCanReruleToAffectItemViaPreviousDispute() public {
    // Arbitrator is TRUSTED to remember not to re-execute ruling of a previous dispute.
    // If it affects an item that is Disputed in a new Dispute, the previous ruling can be replayed.
    // This is also an issue in Light Curate and Classic Curate.
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    arbitrator.executeRuling(0); // Item is now Reincluded

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake * 150 / 100); // challengeStake needs to be bigger now 
    pgtcr.challengeItem{value: arbCost}(itemID, "evidence"); // this disputeID is now 1!!!!
    vm.stopPrank();
    // for whatever reason, let's say the Ruling is now different (e.g. item is now non-compliant)
    vm.prank(king);
    arbitrator.giveRuling(1, uint256(PermanentGTCR.Party.Challenger));
    (, uint256 appealEnd2) = arbitrator.appealPeriod(1);
    vm.warp(appealEnd2 + 1);

    vm.prank(address(arbitrator)); // simulating arbitrator vulnerable to replay
    pgtcr.rule(0, uint256(PermanentGTCR.Party.Submitter)); // 0 was the original dispute, which shouldn't be valid

    // Potential Mitigation: mapping whether if a disputeID has been already ruled in arbitrable
    // arbitrator is already TRUSTED though so this shouldn't matter.
    // if they wanted to drain, they can just maliciously rule with the real disputeID.
    // WONTFIX
  }

  function test_Rule_NoAppeal_Challenger() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Challenger));
    uint48 prevIncludedAt = uint48(block.timestamp);

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);

    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.Challenger));
    // Bob will get his original deposit + Alice's item stake
    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(address(pgtcr), bob, submissionMinDeposit + challengeStake);
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Absent);
    arbitrator.executeRuling(0);
    // item is now Absent, challengeCount remains at 1, all other values don't matter
    (PermanentGTCR.Status status, uint128 arbitrationDeposit, uint120 challengeCount,
    address submitter, uint48 includedAt, uint48 withdrawingTimestamp,
    uint256 stake) = pgtcr.items(itemID);

    vm.assertEq(uint8(status), 0); // Absent
    vm.assertEq(arbitrationDeposit, uint128(arbCost));
    vm.assertEq(challengeCount, 1);
    vm.assertEq(submitter, alice);
    vm.assertEq(includedAt, prevIncludedAt); // it was never overwritten, as would happen if rule = Party.Submitter
    vm.assertEq(withdrawingTimestamp, 0);
    vm.assertEq(stake, submissionMinDeposit);

    vm.assertEq(bob.balance, 2 ether); // he started with 2 ether, Alice net lost the arb cost as she had supplied it as item.arbitrationDeposit
    vm.assertEq(alice.balance, 2 ether - arbCost);
  }

  function test_Rule_FundAppeal_Submitter() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Challenger));
    uint48 prevIncludedAt = uint48(block.timestamp);

    (uint256 appealStart, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealStart + 1); // enter loser region for appeals
    // alice will appeal for herself.
    vm.startPrank(alice);

    uint256 loserAppealFund = arbitrator.appealCost(disputeID, "")
      + arbitrator.appealCost(disputeID, "") * pgtcr.loserStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();
    vm.expectEmit(true, true, false, true);
    emit PermanentGTCR.Contribution(
      itemID,
      0,
      1, // round 0 is the submitter challenger cycle (legacy)
      address(alice),
      loserAppealFund,
      PermanentGTCR.Party.Submitter
    );
    pgtcr.fundAppeal{value: loserAppealFund}(itemID, PermanentGTCR.Party.Submitter);

    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 0), 0);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 1), loserAppealFund);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 2), 0);

    (PermanentGTCR.Party sideFunded, uint256 feeRewards) =
      pgtcr.rounds(itemID, 0, 1);
    
    vm.assertEq(uint8(sideFunded), 1); // Submitter
    vm.assertEq(feeRewards, loserAppealFund);

    // i don't know how to access this; without it being cumbersome, so i wont.
    // vm.assertEq(amountPaid[0], 0);
    // vm.assertEq(amountPaid[1], loserAppealFund);
    // vm.assertEq(amountPaid[2], 0);

    vm.warp(appealEnd + 1); // get out of period. Alice wins by default because Bob side desisted to fund appeal

    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.Submitter));
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Reincluded);
    arbitrator.executeRuling(0);
    // item is now Reincluded because Submitter won
    (PermanentGTCR.Status status, , , , uint48 includedAt, , uint256 stake) = pgtcr.items(itemID);

    vm.assertEq(uint8(status), 2); // Reincluded
    vm.assertEq(includedAt, uint48(block.timestamp));
    vm.assertEq(stake, submissionMinDeposit + challengeStake);

    vm.assertEq(bob.balance, 2 ether - arbCost);
    vm.assertEq(alice.balance, 2 ether - arbCost - loserAppealFund); // she didn't withdraw her contribution yet!
  }

  function test_Rule_FundAppeal_Challenger() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));
    uint48 prevIncludedAt = uint48(block.timestamp);

    (uint256 appealStart, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealStart + 1); // enter loser region for appeals
    // bob will appeal for himself.
    vm.startPrank(bob);

    uint256 loserAppealFund = arbitrator.appealCost(disputeID, "")
      + arbitrator.appealCost(disputeID, "") * pgtcr.loserStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();
    vm.expectEmit(true, true, false, true);
    emit PermanentGTCR.Contribution(
      itemID,
      0,
      1, // round 0 is the submitter challenger cycle (legacy)
      address(bob),
      loserAppealFund,
      PermanentGTCR.Party.Challenger
    );
    pgtcr.fundAppeal{value: loserAppealFund}(itemID, PermanentGTCR.Party.Challenger);
    vm.stopPrank();

    vm.warp((appealEnd + appealStart) / 2 + 1); // to test some extras: lets say alice funds but she doesnt fund enough
    uint256 winnerAppealFund = arbitrator.appealCost(disputeID, "")
      + arbitrator.appealCost(disputeID, "") * pgtcr.winnerStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();
    vm.prank(alice);
    pgtcr.fundAppeal{value: winnerAppealFund / 2}(itemID, PermanentGTCR.Party.Submitter);

    vm.assertEq(pgtcr.contributions(itemID, 0, 1, bob, 0), 0);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, bob, 1), 0);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, bob, 2), loserAppealFund);

    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 0), 0);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 1), winnerAppealFund / 2);
    vm.assertEq(pgtcr.contributions(itemID, 0, 1, alice, 2), 0);

    (PermanentGTCR.Party sideFunded, uint256 feeRewards) =
      pgtcr.rounds(itemID, 0, 1);
    
    vm.assertEq(uint8(sideFunded), 2); // Challenger (Bob) funded fully
    vm.assertEq(feeRewards, loserAppealFund + winnerAppealFund / 2);

    // i don't know how to access this; without it being cumbersome, so i wont.
    // vm.assertEq(amountPaid[0], 0);
    // vm.assertEq(amountPaid[1], winnerAppealFund / 2);
    // vm.assertEq(amountPaid[2], loserAppealFund);

    vm.warp(appealEnd + 1); // get out of period. Bob wins by default because Alice side didnt fund fully

    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.Challenger));
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Absent);
    arbitrator.executeRuling(0);
    // item is now Absent because Challenger won
    (PermanentGTCR.Status status, , , , , , ) = pgtcr.items(itemID);

    vm.assertEq(uint8(status), 0); // Absent

    vm.assertEq(bob.balance, 2 ether - loserAppealFund); // bob didnt withdraw his contrib yet, but got arbCost refunded
    vm.assertEq(alice.balance, 2 ether - arbCost - winnerAppealFund / 2); // she didn't withdraw her contribution yet!

    // now lets test the refunds
    // anyone can call these
    vm.expectEmit(true, true, false, true, address(pgtcr));
    emit PermanentGTCR.RewardWithdrawn(bob, itemID, 0, 1, loserAppealFund);
    pgtcr.withdrawFeesAndRewards(payable(bob), itemID, 0, 1); // because round wasn't fully funded, he gets loserAppealFund
    vm.assertEq(bob.balance, 2 ether);

    vm.expectEmit(true, true, false, true, address(pgtcr));
    emit PermanentGTCR.RewardWithdrawn(alice, itemID, 0, 1, winnerAppealFund / 2);
    pgtcr.withdrawFeesAndRewards(payable(alice), itemID, 0, 1); // because round wasn't fully funded, she gets her winnerAppealFund / 2
    vm.assertEq(alice.balance, 2 ether - arbCost); // net, she lost arbCost
  }

  function test_Withdraw_NotPossibleWhileDisputed() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.Submitter));

    vm.expectRevert(PermanentGTCR.RewardsPendingDispute.selector);
    pgtcr.withdrawFeesAndRewards(payable(alice), itemID, 0, 1);
  }

  function test_Rule_NoAppeal_RtA() public {
    vm.prank(king);
    arbitrator.giveRuling(0, uint256(PermanentGTCR.Party.None));

    (, uint256 appealEnd) = arbitrator.appealPeriod(disputeID);
    vm.warp(appealEnd + 1);
  
    vm.expectEmit(true, true, true, false, address(pgtcr));
    emit IArbitrable.Ruling(IArbitrator(arbitrator), disputeID, uint256(PermanentGTCR.Party.None));
    // first Bob will get his deposit
    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(address(pgtcr), bob, challengeStake);
    // then, Alice gets hers
    vm.expectEmit(true, true, false, true, address(token));
    emit IERC20.Transfer(address(pgtcr), alice, submissionMinDeposit);
    vm.expectEmit(true, false, false, false, address(pgtcr));
    emit PermanentGTCR.ItemStatusChange(itemID, PermanentGTCR.Status.Absent);
    arbitrator.executeRuling(0);
    
    (PermanentGTCR.Status status, uint128 arbitrationDeposit, uint120 challengeCount,
    address submitter, , , uint256 stake) = pgtcr.items(itemID);

    vm.assertEq(uint8(status), 0); // Absent
    vm.assertEq(arbitrationDeposit, uint128(arbCost) / 2); // in this case, half was awarded to Bob and substracted from this
    vm.assertEq(challengeCount, 1);
    vm.assertEq(submitter, alice);
    vm.assertEq(stake, submissionMinDeposit); // set before withdrawal was triggered

    // When RtA, item gets withdrawn. Both parties should've paid the arbitration costs equally*
    // * not really because arbitrator can change arbitrationFees, but whatever
    vm.assertEq(alice.balance, 2 ether - arbCost / 2);
    vm.assertEq(bob.balance, 2 ether - arbCost / 2);
  }

  function test_Rule_FailsIfNonArbitrator() public {
    vm.expectRevert(PermanentGTCR.ArbitratorOnly.selector);
    pgtcr.rule(uint256(itemID), uint256(PermanentGTCR.Party.Submitter));
  }

  function test_Rule_FailsIfBadRuling() public {
    // Arbitrator is trusted to not do this. If it did this on accident funds would prob get stuck forever.
    vm.prank(address(arbitrator));
    vm.expectRevert(PermanentGTCR.RulingInvalidOption.selector);
    pgtcr.rule(uint256(itemID), 69_420);
  }
}

contract SubmitEvidence is PGTCRTest {
  PermanentGTCR pgtcr;
  bytes32 itemID;
  uint256 arbCost;
  uint256 stake;
  uint256 challengeStake;
  uint256 disputeID;

  function setUp() public {
    vm.warp(1745776000); // o/w there are underflows when calculating settings.
    vm.deal(alice, 2 ether);
    vm.deal(bob, 2 ether);
    vm.deal(eve, 2 ether);

    vm.prank(alice);
    token = new PolloCoin(1e20);
    vm.prank(alice);
    token.transfer(bob, 1e19);

    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();

    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );

    arbCost = arbitrator.arbitrationCost(arbitratorExtraData);
    stake = submissionMinDeposit;
    challengeStake = stake * pgtcr.challengeStakeMultiplier() / pgtcr.MULTIPLIER_DIVISOR();

    vm.startPrank(alice);
    token.approve(address(pgtcr), stake);
    pgtcr.addItem{value: arbCost}("item1", stake);
    vm.stopPrank();

    itemID = keccak256(abi.encodePacked("item1"));

    vm.startPrank(bob);
    token.approve(address(pgtcr), challengeStake);
    pgtcr.challengeItem{value: arbCost}(itemID, "");
    vm.stopPrank();

    disputeID = 0;
  }

  function test_SubmitEvidence() public {
    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Evidence(IArbitrator(arbitrator), uint256(itemID), alice, "The item is good I swear!!!");
    vm.prank(alice);
    pgtcr.submitEvidence(itemID, "The item is good I swear!!!");

    vm.expectEmit(true, true, true, true, address(pgtcr));
    emit IEvidence.Evidence(IArbitrator(arbitrator), uint256(itemID), bob, "No its not");
    vm.prank(bob);
    pgtcr.submitEvidence(itemID, "No its not");
  }

  function test_SubmitEvidence_FailsIfAbsent() public {
    vm.prank(alice);
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.submitEvidence(bytes32(uint256(69_420)), "The item is good I swear!!!"); // item doesnt exist

    vm.prank(address(arbitrator));
    pgtcr.rule(0, 0); // make item absent with RtA
    vm.prank(alice);
    vm.expectRevert(PermanentGTCR.ItemWrongStatus.selector);
    pgtcr.submitEvidence(itemID, "The item is good I swear!!!");
  }
}

contract ChangingSettings is PGTCRTest {
  PermanentGTCR pgtcr;

  function setUp() public {
    vm.prank(king);
    arbitrator = new CentralizedArbitratorWithAppeal();
    pgtcr = pgtcrFactory.deploy(
      arbitrator, arbitratorExtraData, metaEvidence,
      governor, token, submissionMinDeposit, periods, multipliers
    );
  }

  function test_ChangeSubmissionPeriod() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeSubmissionPeriod(10_000);
    vm.assertEq(pgtcr.submissionPeriod(), 10_000);
  }

  function test_ChangeSubmissionPeriodFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeSubmissionPeriod(10_000);
  }

  function test_ChangeReinclusionPeriod() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeReinclusionPeriod(10_000);
    vm.assertEq(pgtcr.reinclusionPeriod(), 10_000);
  }

  function test_ChangeReinclusionPeriodFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeReinclusionPeriod(10_000);
  }

  function test_ChangeWithdrawingPeriod() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeWithdrawingPeriod(10_000);
    vm.assertEq(pgtcr.withdrawingPeriod(), 10_000);
  }

  function test_ChangeWithdrawingPeriodFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeWithdrawingPeriod(10_000);
  }

  function test_ChangeSubmissionMinDeposit() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeSubmissionMinDeposit(10_000);
    vm.assertEq(pgtcr.submissionMinDeposit(), 10_000);
  }

  function test_ChangeSubmissionMinDepositFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeSubmissionMinDeposit(10_000);
  }

  function test_ChangeGovernor() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeGovernor(eve);
    vm.assertEq(pgtcr.governor(), eve);
  }

  function test_ChangeGovernorFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeGovernor(eve);
  }

  function test_ChangeChallengeStakeMultiplier() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeChallengeStakeMultiplier(10_000);
    vm.assertEq(pgtcr.challengeStakeMultiplier(), 10_000);
  }

  function test_ChangeChallengeStakeMultiplierFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeChallengeStakeMultiplier(10_000);
  }

  function test_ChangeSharedStakeMultiplier() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeSharedStakeMultiplier(10_000);
    vm.assertEq(pgtcr.sharedStakeMultiplier(), 10_000);
  }

  function test_ChangeSharedStakeMultiplierFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeSharedStakeMultiplier(10_000);
  }

  function test_ChangeWinnerStakeMultiplier() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeWinnerStakeMultiplier(10_000);
    vm.assertEq(pgtcr.winnerStakeMultiplier(), 10_000);
  }

  function test_ChangeWinnerStakeMultiplierFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeWinnerStakeMultiplier(10_000);
  }

  function test_ChangeLoserStakeMultiplier() public {
    vm.expectEmit(true, true, true, true);
    emit PermanentGTCR.SettingsUpdated();
    vm.prank(governor);
    pgtcr.changeLoserStakeMultiplier(10_000);
    vm.assertEq(pgtcr.loserStakeMultiplier(), 10_000);
  }

  function test_ChangeLoserStakeMultiplierFail() public {
    vm.expectRevert(PermanentGTCR.GovernorOnly.selector);
    pgtcr.changeLoserStakeMultiplier(10_000);
  }

  // change arb settings already tested on Challenge
}
