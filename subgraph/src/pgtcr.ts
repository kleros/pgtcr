import { BigInt, DataSourceContext, log } from "@graphprotocol/graph-ts";
import { ArbitrationSetting, Challenge, Contribution, Evidence, Item, Registry, Round, Submission } from "../generated/schema";
import { Contribution as ContributionEvent, Dispute, ItemStartsWithdrawing, ItemStatusChange, MetaEvidence, NewItem, PermanentGTCR, PermanentGTCR__challengesResult, PermanentGTCR__itemsResult, RewardWithdrawn, SettingsUpdated,
  Evidence as EvidenceEvent,
  Ruling
 } from "../generated/templates/PermanentGTCR/PermanentGTCR";
import { AppealPossible, AppealDecision, IArbitrator } from "../generated/templates/IArbitrator/IArbitrator";
import { ItemMetadata as ItemMetadataTemplate,
  EvidenceMetadata as EvidenceMetadataTemplate,
  RegistryMetadata as RegistryMetadataTemplate } from "../generated/templates"
import { extractPath } from "./utils";

let ABSENT_CODE = 0;
let SUBMITTED_CODE = 1;
let REINCLUDED_CODE = 2;
let DISPUTED_CODE = 3;
let ABSENT = 'Absent';
let SUBMITTED = 'Submitted';
let REINCLUDED = 'Reincluded';
let DISPUTED = 'Disputed';

let NO_RULING_CODE = 0;
let REQUESTER_CODE = 1;
let CHALLENGER_CODE = 2;
let NONE = 'None';
let ACCEPT = 'Accept';
let REJECT = 'Reject';

let ZERO = BigInt.fromU32(0);
let ONE = BigInt.fromU32(1);

let RULING_NAMES = new Map<number, string>();
RULING_NAMES.set(NO_RULING_CODE, NONE);
RULING_NAMES.set(REQUESTER_CODE, ACCEPT);
RULING_NAMES.set(CHALLENGER_CODE, REJECT);

let CONTRACT_STATUS_NAMES = new Map<number, string>();
CONTRACT_STATUS_NAMES.set(ABSENT_CODE, ABSENT);
CONTRACT_STATUS_NAMES.set(SUBMITTED_CODE, SUBMITTED);
CONTRACT_STATUS_NAMES.set(REINCLUDED_CODE, REINCLUDED);
CONTRACT_STATUS_NAMES.set(DISPUTED_CODE, DISPUTED);

function buildNewRound(
  roundID: string,
  challengeID: string,
  timestamp: BigInt,
): Round {
  let newRound = new Round(roundID);
  newRound.amountPaidRequester = ZERO;
  newRound.amountPaidChallenger = ZERO;
  newRound.hasPaidRequester = false;
  newRound.hasPaidChallenger = false;
  newRound.lastFundedRequester = ZERO;
  newRound.lastFundedChallenger = ZERO;
  newRound.feeRewards = ZERO;
  newRound.challenge = challengeID;
  newRound.appealPeriodStart = ZERO;
  newRound.appealPeriodEnd = ZERO;
  newRound.rulingTime = ZERO;
  newRound.ruling = NONE;
  newRound.creationTime = timestamp;
  newRound.numberOfContributions = ZERO;
  newRound.appealed = false;
  return newRound;
}

export function handleNewItem(event: NewItem): void {
  // Construct the item entity ID as <itemID>@<tcrAddress>
  let graphItemID = event.params._itemID.toHexString() + '@' + event.address.toHexString();

  let registry = Registry.load(event.address.toHexString()) as Registry;
  // NewItem means, item didn't exist before. net gain.
  registry.numberOfSubmitted = registry.numberOfSubmitted.plus(ONE);
  let pgtcr = PermanentGTCR.bind(event.address);

  let item = new Item(graphItemID);
  item.itemID = event.params._itemID;
  item.data = event.params._data;
  item.status = SUBMITTED;
  item.numberOfSubmissions = ONE; // this subm is added later on this handler.
  item.numberOfChallenges = ZERO;
  item.registry = registry.id;
  item.registryAddress = event.address;
  item.createdAt = event.block.timestamp;
  item.includedAt = event.block.timestamp;
  item.withdrawingTimestamp = ZERO;
  item.submitter = event.transaction.from;
  let __itemsRes: PermanentGTCR__itemsResult = pgtcr.items(event.params._itemID);
  item.stake = __itemsRes.getStake();
  item.arbitrationDeposit = __itemsRes.getArbitrationDeposit();

  // Extract IPFS hash for metadata, if available
  const ipfsHash = extractPath(event.params._data);
  item.metadata = ipfsHash ? ipfsHash : null;

  log.debug('Creating datasource for ipfs hash : {}', [ipfsHash]);
  
  const context = new DataSourceContext();
  context.setString('graphItemID', graphItemID);
  context.setString('address', event.address.toHexString());
  
  ItemMetadataTemplate.createWithContext(ipfsHash, context);

  // create the first Submission. submissions are only created on NewItem or ItemStatusChange("Submitted")
  let submissionID = graphItemID + '-0';
  let submission = new Submission(submissionID);
  submission.item = item.id;
  submission.submissionID = ZERO;
  submission.createdAt = event.block.timestamp;
  submission.withdrawingTimestamp = ZERO;
  submission.submitter = event.transaction.from;
  submission.initialStake = __itemsRes.getStake();
  submission.arbitrationDeposit = ZERO;
  submission.save();
  item.save();
  registry.save();
}

export function handleStatusChange(event: ItemStatusChange): void {
  let graphItemID = event.params._itemID.toHexString() + '@' + event.address.toHexString();
  let registry = Registry.load(event.address.toHexString()) as Registry;
  let item = Item.load(graphItemID) as Item;

  // when Absent -> Submitted (because it means item was resubmitted, we create new submission)
  // anything else, and we mostly do accounting.
  if (event.params._status === SUBMITTED_CODE) {
    let submission = new Submission(graphItemID + "-" + item.numberOfSubmissions.toString());

    let pgtcr = PermanentGTCR.bind(event.address);
    submission.item = item.id;
    submission.submissionID = item.numberOfSubmissions;
    submission.createdAt = event.block.timestamp;
    submission.withdrawingTimestamp = ZERO;
    submission.submitter = event.transaction.from;
    let __itemsRes: PermanentGTCR__itemsResult = pgtcr.items(event.params._itemID);
    submission.initialStake = __itemsRes.getStake();
    submission.arbitrationDeposit = __itemsRes.getArbitrationDeposit();
    submission.save();
  
    item.numberOfSubmissions = item.numberOfSubmissions.plus(ONE);
    // when the item was Absent, we didn't reset the fields, but we need to do it now.
    item.withdrawingTimestamp = ZERO;
    item.includedAt = submission.createdAt;
    item.stake = submission.initialStake;
    item.arbitrationDeposit = submission.arbitrationDeposit;
    item.submitter = submission.submitter;
    
    // accounting
    registry.numberOfAbsent = registry.numberOfAbsent.minus(ONE);
    registry.numberOfSubmitted = registry.numberOfSubmitted.plus(ONE);
  } else if (event.params._status === ABSENT_CODE) {
    // accounting, was it disputed before?
    if (item.status === DISPUTED) {
      registry.numberOfDisputed = registry.numberOfDisputed.minus(ONE);
    } else {
      registry.numberOfSubmitted = registry.numberOfSubmitted.minus(ONE);
    }
    registry.numberOfAbsent = registry.numberOfAbsent.plus(ONE);
  } else if (event.params._status === REINCLUDED_CODE) {
    item.includedAt = event.block.timestamp;
    // stake was handled in Ruling. withdrawingTimestamp is known to be ZERO, arbDeposit, submitter are unchanged...
    // accounting
    registry.numberOfDisputed = registry.numberOfDisputed.minus(ONE);
    registry.numberOfSubmitted = registry.numberOfSubmitted.plus(ONE);
  } else if (event.params._status === DISPUTED_CODE) {
    registry.numberOfSubmitted = registry.numberOfSubmitted.minus(ONE);
    registry.numberOfDisputed = registry.numberOfDisputed.plus(ONE);
  }

  registry.save();

  item.status = CONTRACT_STATUS_NAMES.get(event.params._status);
  if (event.params._status === SUBMITTED_CODE || event.params._status === REINCLUDED_CODE) {
    item.includedAt = event.block.timestamp;
  }

  item.save();
}

export function handleItemStartsWithdrawing(event: ItemStartsWithdrawing): void {
  let graphItemID = event.params._itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;

  // start withdrawal in item and in submission.
  item.withdrawingTimestamp = event.block.timestamp;
  let submission = Submission.load(graphItemID + "-" + item.numberOfSubmissions.minus(ONE).toString()) as Submission;
  submission.withdrawingTimestamp = event.block.timestamp;
  submission.save();
  item.save();
}

export function handleDispute(event: Dispute): void {
  // some accounting was already done in status change!
  let pgtcr = PermanentGTCR.bind(event.address);

  let itemID = pgtcr.disputeIDToItemID(event.params._disputeID);
  let graphItemID = itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;

  let challengeID = item.numberOfChallenges;
  let challenge = new Challenge(graphItemID + '-' + challengeID.toString());

  item.numberOfChallenges = item.numberOfChallenges.plus(ONE);

  challenge.item = item.id;
  challenge.challengeID = challengeID;
  challenge.disputeID = event.params._disputeID;
  challenge.createdAt = event.block.timestamp;
  challenge.creationTx = event.transaction.hash;
  challenge.submission = graphItemID + "-" + item.numberOfSubmissions.minus(ONE).toString();
  let __challengeRes: PermanentGTCR__challengesResult =  pgtcr.challenges(item.itemID, challengeID);
  challenge.challenger = __challengeRes.getChallenger();
  challenge.arbitrationSetting = event.address.toHexString() + "-" + __challengeRes.getArbitrationParamsIndex().toString();
  challenge.itemStake = item.stake;
  challenge.challengerStake = __challengeRes.getStake();
  // challenge.disputeOutcome = NONE;
  challenge.numberOfRounds = BigInt.fromU32(2);
  challenge.registry = event.address.toHexString();
  challenge.registryAddress = event.address;

  let newRoundID = challenge.id + '-1'; // When a dispute is created, the new round is always id 1
  let round = buildNewRound(newRoundID, challenge.id, event.block.timestamp);
  round.save();
  challenge.save();
}

export function handleAppealPossible(event: AppealPossible): void {
  let registry = Registry.load(event.params._arbitrable.toHexString());
  if (registry == null) return; // Event not related to a PGTCR.
  let pgtcr = PermanentGTCR.bind(event.params._arbitrable);
  let itemID = pgtcr.disputeIDToItemID(event.params._disputeID);
  
  // get item, current challenge and current round.
  let graphItemID = itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;
  let challenge = Challenge.load(graphItemID + "-" + item.numberOfChallenges.minus(ONE).toString()) as Challenge;
  let round = Round.load(challenge.id + "-" + challenge.numberOfRounds.minus(ONE).toString()) as Round;
  
  let arbitrator = IArbitrator.bind(event.address);
  let appealPeriod = arbitrator.appealPeriod(event.params._disputeID);
  round.appealPeriodStart = appealPeriod.getStart();
  round.appealPeriodEnd = appealPeriod.getEnd();
  let currentRuling = arbitrator.currentRuling(event.params._disputeID);
  round.ruling = CONTRACT_STATUS_NAMES.get(currentRuling.toU32());
  round.rulingTime = event.block.timestamp;
  round.txHashAppealPossible = event.transaction.hash;
  round.save();
}

export function handleAppealDecision(event: AppealDecision): void {
  let registry = Registry.load(event.params._arbitrable.toHexString());
  if (registry == null) return; // Event not related to a PGTCR.
  let pgtcr = PermanentGTCR.bind(event.params._arbitrable);
  let itemID = pgtcr.disputeIDToItemID(event.params._disputeID);
  
  // get item, current challenge and current round.
  let graphItemID = itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;
  let challenge = Challenge.load(graphItemID + "-" + item.numberOfChallenges.minus(ONE).toString()) as Challenge;
  let round = Round.load(challenge.id + "-" + challenge.numberOfRounds.minus(ONE).toString()) as Round;
  
  round.appealed = true;
  round.appealedAt = event.block.timestamp;
  round.txHashAppealDecision = event.transaction.hash;

  round.hasPaidRequester = true;
  round.hasPaidChallenger = true;

  // create new round
  let newRoundID = challenge.id + '-' + challenge.numberOfRounds.toString(); // not inc yet
  let newRound = buildNewRound(newRoundID, challenge.id, event.block.timestamp);
  newRound.save();
  round.save();

  challenge.numberOfRounds = challenge.numberOfRounds.plus(ONE);
  challenge.save();
}

export function handleContribution(event: ContributionEvent): void {
  let registry = Registry.load(event.address.toHexString());
  if (registry == null) return; // Event not related to a PGTCR.
  let pgtcr = PermanentGTCR.bind(event.address);
  
  // get item, current challenge and current round.
  let graphItemID = event.params._itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;
  let challenge = Challenge.load(graphItemID + "-" + item.numberOfChallenges.minus(ONE).toString()) as Challenge;
  let round = Round.load(challenge.id + "-" + challenge.numberOfRounds.minus(ONE).toString()) as Round;
  
  let contributionID = round.id + "-" + round.numberOfContributions.toString();
  let contribution = new Contribution(contributionID);
  contribution.contributor = event.params._contributor;
  contribution.withdrawable = false;
  contribution.round = round.id;
  contribution.side = BigInt.fromU32(event.params._side);

  // handle round now.
  round.numberOfContributions = round.numberOfContributions.plus(ONE);
  if (event.params._side === 1) {
    round.lastFundedRequester = event.block.timestamp;
  } else {
    round.lastFundedChallenger = event.block.timestamp;
  }
  let amountPaidArray = pgtcr.getRoundAmountPaid(event.params._itemID, event.params._challengeID, event.params._roundID);
  let __roundsRes = pgtcr.rounds(event.params._itemID, event.params._challengeID, event.params._roundID);
  round.amountPaidRequester = amountPaidArray[REQUESTER_CODE];
  round.amountPaidChallenger = amountPaidArray[CHALLENGER_CODE];
  round.feeRewards = __roundsRes.getFeeRewards();
  // note that, on AppealDecision, both are turned into the true value
  round.hasPaidRequester = __roundsRes.getSideFunded() === 1;
  round.hasPaidChallenger = __roundsRes.getSideFunded() === 2;

  round.save();
  contribution.save();
}

export function handleRuling(event: Ruling): void {
  let pgtcr = PermanentGTCR.bind(event.address);

  let disputeID = event.params._disputeID;
  let itemID = pgtcr.disputeIDToItemID(disputeID);
  let graphItemID = itemID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;
  let challenge = Challenge.load(item.id + "-" + item.numberOfChallenges.minus(ONE).toString()) as Challenge;
  
  challenge.disputeOutcome = RULING_NAMES.get(event.params._ruling.toU32());
  challenge.resolutionTime = event.block.timestamp;
  challenge.resolutionTx = event.transaction.hash;
  challenge.save();
  if (challenge.disputeOutcome === ACCEPT) {
    // update item stake, nothing else. must be done here instead of update status,
    // since Ruling => Accept but item.withdrawingTimestamp is a possibility
    item.stake = challenge.itemStake.plus(item.stake);
    item.save();
  }
  // Paste and slightly adapted from kleros/gtcr-subgraph
  // Iterate over every contribution and mark it as withdrawable if it is.
  // Start from the second round as the first is automatically withdrawn
  // when the request resolves.
    for (
      let i = BigInt.fromI32(1);
      i.lt(challenge.numberOfRounds);
      i = i.plus(ONE)
    ) {
      // Iterate over every round of the request.
      let roundID = challenge.id + '-' + i.toString();
      let round = Round.load(roundID);
      if (!round) {
        log.error(`Round {} not found.`, [roundID]);
        return;
      }
  
      for (
        let j = BigInt.fromI32(0);
        j.lt(round.numberOfContributions);
        j = j.plus(ONE)
      ) {
        // Iterate over every contribution of the round.
        let contributionID = roundID + '-' + j.toString();
        let contribution = Contribution.load(contributionID);
        if (!contribution) {
          log.error(`Contribution {} not found.`, [contributionID]);
          return;
        }
  
        if (event.params._ruling == BigInt.fromU32(NO_RULING_CODE)) {
          // The final ruling is refuse to rule. There is no winner
          // or loser so every contribution is withdrawable.
          contribution.withdrawable = true;
        } else if (event.params._ruling == BigInt.fromU32(REQUESTER_CODE)) {
          // The requester won so only contributions to the requester
          // are withdrawable.
          // The only exception is in the case the last round the loser
          // (challenger in this case) raised some funds but not enough
          // to be fully funded before the deadline. In this case
          // the contributors get to withdraw.
          if (contribution.side == BigInt.fromI32(REQUESTER_CODE)) {
            contribution.withdrawable = true;
          } else if (i.equals(challenge.numberOfRounds.minus(ONE))) {
            // Contribution was made to the challenger (loser) and this
            // is the last round.
            contribution.withdrawable = true;
          }
        } else {
          // The challenger won so only contributions to the challenger
          // are withdrawable.
          // The only exception is in the case the last round the loser
          // (requester in this case) raised some funds but not enough
          // to be fully funded before the deadline. In this case
          // the contributors get to withdraw.
          if (contribution.side == BigInt.fromI32(CHALLENGER_CODE)) {
            contribution.withdrawable = true;
          } else if (i.equals(challenge.numberOfRounds.minus(ONE))) {
            // Contribution was made to the requester (loser) and this
            // is the last round.
            contribution.withdrawable = true;
          }
        }
  
        contribution.save();
      }
    }

  // item might had been withdrawing, in which case the end result is it would withdraw
  // Item status change is handled last, so do i need to do anything to signal it withdrew automatically?
  // no, because it turns into absent afterwards. so thats it.
}

export function handleRewardWithdrawn(event: RewardWithdrawn): void {
  let graphItemID =
    event.params._itemID.toHexString() + '@' + event.address.toHexString();
  let challengeID = graphItemID + '-' + event.params._challenge.toString();
  let roundID = challengeID + '-' + event.params._round.toString();
  let round = Round.load(roundID);
  if (!round) {
    log.error(`Round {} not found.`, [roundID]);
    return;
  }

  for (
    let i = BigInt.fromI32(0);
    i.lt(round.numberOfContributions);
    i = i.plus(BigInt.fromI32(1))
  ) {
    let contributionID = roundID + '-' + i.toString();
    let contribution = Contribution.load(contributionID);
    if (!contribution) {
      log.error(`Contribution {} not found.`, [contributionID]);
      return;
    }
    // Check if the contribution is from the beneficiary.

    if (
      contribution.contributor.toHexString() !=
      event.params._beneficiary.toHexString()
    )
      continue;

    contribution.withdrawable = false;
    contribution.save();
  }
}

export function handleSettingsUpdated(event: SettingsUpdated): void {
  // just go over every setting and force update. these are the settings that may change
  let pgtcr = PermanentGTCR.bind(event.address);
  let registry = Registry.load(event.address.toHexString());
  if (!registry) {
  log.error(`Registry {} not found.`, [event.address.toHexString()]);
  return;
  }
  registry.submissionMinDeposit = pgtcr.submissionMinDeposit();
  registry.submissionPeriod = pgtcr.submissionPeriod();
  registry.reinclusionPeriod = pgtcr.reinclusionPeriod();
  registry.withdrawingPeriod = pgtcr.withdrawingPeriod();
  registry.arbitrationParamsCooldown = pgtcr.arbitrationParamsCooldown();
  registry.challengeStakeMultiplier = pgtcr.challengeStakeMultiplier();
  registry.winnerStakeMultiplier = pgtcr.winnerStakeMultiplier();
  registry.loserStakeMultiplier = pgtcr.loserStakeMultiplier();
  registry.sharedStakeMultiplier = pgtcr.sharedStakeMultiplier();

  registry.save()
}

export function handleMetaEvidence(event: MetaEvidence): void {
  let pgtcr = PermanentGTCR.bind(event.address);
  let registry = Registry.load(event.address.toHexString());
  if (!registry) {
    log.error(`Registry {} not found.`, [event.address.toHexString()]);
    return;
  }

  let arbitrationSetting = new ArbitrationSetting(registry.id + "-" + registry.arbitrationSettingCount.toString());
  arbitrationSetting.registry = registry.id;
  arbitrationSetting.timestamp = event.block.timestamp;
  let __arbitrationPCRes = pgtcr.arbitrationParamsChanges(registry.arbitrationSettingCount);
  arbitrationSetting.arbitratorExtraData = __arbitrationPCRes.getArbitratorExtraData();
  // arbSettings are mapped 1:1 with MetaEvidences!
  arbitrationSetting.metaEvidenceURI = event.params._evidence;

  const ipfsHash = extractPath(event.params._evidence);
  const context = new DataSourceContext();
  context.setString('address', event.address.toHexString());
  context.setBigInt('count', registry.arbitrationSettingCount);
  RegistryMetadataTemplate.createWithContext(ipfsHash, context);

  // this is done last deliberately.
  registry.arbitrationSettingCount = registry.arbitrationSettingCount.plus(ONE);

  arbitrationSetting.save();
  registry.save();
}

export function handleEvidence(event: EvidenceEvent): void {
  let graphItemID =
    event.params._evidenceGroupID.toHexString() + '@' + event.address.toHexString();
  let item = Item.load(graphItemID) as Item;
  let evidenceNumber = item.numberOfEvidences;
  let evidence = new Evidence(graphItemID + "-" + evidenceNumber.toString());
  item.numberOfEvidences = item.numberOfEvidences.plus(ONE);

  evidence.arbitrator = event.params._arbitrator;
  evidence.party = event.params._party;
  evidence.URI = event.params._evidence;
  evidence.number = evidenceNumber;
  evidence.timestamp = event.block.timestamp;
  evidence.txHash = event.transaction.hash;

  const ipfsHash = extractPath(event.params._evidence);
  evidence.metadata = `${ipfsHash}-${evidence.id}`;

  const context = new DataSourceContext();
  context.setString('evidenceId', evidence.id);
  EvidenceMetadataTemplate.createWithContext(ipfsHash, context);

  evidence.save();
}

