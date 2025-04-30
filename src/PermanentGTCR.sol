/**
 *  @authors: [@greenlucid]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IArbitrable, IArbitrator} from "@kleros/erc-792/contracts/IArbitrator.sol";
import {IEvidence} from "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import {CappedMath} from "./utils/CappedMath.sol";
import {CappedMath128} from "./utils/CappedMath128.sol";

// It is the user responsibility to accept ETH. It is the ERC20 token responsibility to not revert transfers.
// ERC20 token are not trusted to not revert on transfers from Contract -> Beneficiary.
// > If the token reverts on valid transfers from Contract to a beneficiary, those funds are forever locked.
// > otherwise Item would get stuck in Disputed, and all appeal contributions would get stuck.

// Arbitrator is trusted to rule correctly.
// Governor is trusted to not spam 10000s of arbitration setting updates every cooldown period.
// > If it did, items would not be able to be challenged due to the gas limit on computing latest valid arb settings.

/**
 *  @title PermanentGTCR
 *  This contract is a curated registry for any type of items. It keeps submitters' stakes in the contract.
 *  Items are always collateralized and the incentives for challenging and removing them remain.
 *  It implements appeal fees crowdfunding.
 */
contract PermanentGTCR is IArbitrable, IEvidence {
    using CappedMath for uint256;
    using CappedMath128 for uint128;

    /* Enums */

    enum Status {
        Absent, // The item was never in the registry, was Withdrawn or was Removed.
        Submitted, // The item was included in the registry, challengeable, and considered valid if it went through the submissionPeriod.
        Reincluded, // The item was included as the result of a dispute, is challengeable, and considered valid if it went through the reinclusionPeriod.
        Disputed // The item is currently ongoing a Dispute.
    }

    enum Party {
        None, // Party per default when there is no challenger or requester. Also used for unconclusive ruling.
        Submitter, // Party that included an item.
        Challenger // Party that challenges the inclusion of an item.
    }

    /* Structs */

    struct Item {
        Status status; // The current status of the item.
        uint128 arbitrationDeposit; // Pays for juror fees. Since juror fees can mutate, these are recorded per item.
        uint120 requestCount; // The number of requests. Reminder, DO NOT DELETE this struct on removal, or this gets reset.
        address payable submitter; // Party who submitted the item, and eligible for its stake when withdrawn.
        uint48 includedAt; // When item was last submitted, OR when was last asserted as correct by dispute.
        uint48 withdrawingTimestamp; // When submitter starts the withdrawal process.
        uint256 stake; // Awarded to successful challenger, or returned to submitter on withdrawal.
    }

    struct Request {
        uint80 arbitrationParamsIndex; // The index for the arbitration params for the request.
        Party ruling; // The ruling given to a dispute. Only set after it has been resolved.
        uint8 roundCount; // The number of rounds.
        address payable challenger; // Address of the challenger, if any.
        uint256 stake; // Added into the item.stake on failure, or returned to challenger if successful challenge.
        uint256 disputeID; // The ID of the dispute on the arbitrator.
    }

    // Arrays with 3 elements map with the Party enum for better readability:
    // - 0: is unused, matches `Party.None`.
    // - 1: for `Party.Submitter`.
    // - 2: for `Party.Challenger`.
    struct Round {
        Party sideFunded; // Stores the side that successfully paid the appeal fees in the latest round. Note that if both sides have paid a new round is created.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        uint256[3] amountPaid; // Tracks the sum paid for each Party in this round.
    }

    struct ArbitrationParams {
        uint48 timestamp; // When these settings were put onto place.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
    }

    /* Constants */

    uint256 public constant RULING_OPTIONS = 2; // The amount of non 0 choices the arbitrator can give.
    uint256 private constant RESERVED_ROUND_ID = 0; // For compatibility with GeneralizedTCR consider the request/challenge cycle the first round (index 0).

    /* Storage */

    bool private initialized;

    address public governor; // The address that can make changes to the parameters of the contract.
    IERC20 public token; // The token to collateralize items and challenges. Governor cannot change it.

    uint256 public submissionMinDeposit; // The base deposit to submit an item, in tokens.

    uint256 public submissionPeriod; // The time after which a new item is considered valid. Only matters offchain.
    uint256 public reinclusionPeriod; // The time after which an item ruled to be accepted is considered valid. Only matters offchain.
    uint256 public withdrawingPeriod; // The time after which an item can be withdrawn

    // If this is lower, equal, or only slightly larger than withdrawingPeriod, the registry governor
    // can make all included items invalid before they get a chance to withdraw, potentially causing all of
    // them to get challenged and removed from the registry, losing funds.
    // Contract enforces withdrawingPeriod to be lower than half the cooldown.
    uint256 public arbitrationParamsCooldown; // Seconds until new arbitrationParams are enforced in all items, governor cannot change it.

    // Multipliers are in basis points.
    uint256 public challengeStakeMultiplier; // The ratio of the itemStake paid in the ERC20 Token to start a challenge.
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where arbitrator refused to arbitrate.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    mapping(bytes32 => Item) public items; // Maps the item ID to its data in the form items[_itemID].
    mapping(bytes32 => mapping(uint256 => Request)) public requests; // List of challenges, made against the item in the form requests[itemID][requestID].
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => Round))) public rounds; // Data of the different dispute rounds. rounds[itemID][requestID][roundId].
    mapping(bytes32 => mapping(
        uint256 => mapping(uint256 => mapping(address => uint256[3])))
    ) public contributions; // Maps contributors to their contributions for each side in the form contributions[itemID][requestID][roundID][address][party].

    mapping(uint256 => bytes32) public disputeIDToItemID; // Maps a dispute ID to the ID of the item with the disputed request in the form disputeIDToItemID[disputeID].
    IArbitrator public arbitrator; // Governor cannot change it.
    ArbitrationParams[] public arbitrationParamsChanges;

    /* Modifiers */

    modifier onlyGovernor() {
        if (msg.sender != governor) revert GovernorOnly();
        _;
    }

    /* Events */

    /**
     * @dev Emitted when someone submits an item for the first time.
     * @param _itemID The ID of the new item.
     * @param _data The item data URI.
     */
    event NewItem(bytes32 indexed _itemID, string _data);

    /**
     * @dev Emitted when a party makes a request, raises a dispute or when a request is resolved.
     * @param _itemID The ID of the affected item.
     */
    event ItemStatusChange(bytes32 indexed _itemID);

    /**
     * @dev Emitted when an item starts a withdrawing process.
     * @param _itemID The ID of the affected item.
     */
    event ItemStartsWithdrawing(bytes32 indexed _itemID);

    /**
     * @dev Emitted when a party contributes to an appeal. The roundID assumes the initial request and challenge deposits are the first round. This is done so indexers can know more information about the contribution without using call handlers.
     * @param _itemID The ID of the item.
     * @param _requestID The index of the request that received the contribution.
     * @param _roundID The index of the round that received the contribution.
     * @param _contributor The address making the contribution.
     * @param _contribution How much of the contribution was accepted.
     * @param _side The party receiving the contribution.
     */
    event Contribution(
        bytes32 indexed _itemID,
        uint256 _requestID,
        uint256 _roundID,
        address indexed _contributor,
        uint256 _contribution,
        Party _side
    );

    /**
     * @dev Emitted when someone withdraws more than 0 rewards.
     * @param _beneficiary The address that made contributions to a request.
     * @param _itemID The ID of the item submission to withdraw from.
     * @param _request The request from which to withdraw.
     * @param _round The round from which to withdraw.
     * @param _reward The amount withdrawn.
     */
    event RewardWithdrawn(
        address indexed _beneficiary,
        bytes32 indexed _itemID,
        uint256 _request,
        uint256 _round,
        uint256 _reward
    );

    /**
     * @dev Emitted when any settings are updated, to make subgraph index the changes.
     *  Not emitted whenever MetaEvidence is also emitted.
     */
     event SettingsUpdated();

    /**
     * @dev Initialize the arbitrable curated registry.
     * @param _arbitrator Arbitrator to resolve potential disputes. The arbitrator is trusted to support appeal periods and not reenter.
     * @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     * @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     * @param _governor The trusted governor of this contract.
     * @param _token The ERC20 token for stakes of items and challenges. Cannot be modified.
     * @param _submissionMinDeposit The minimum amount of token deposit required to submit an item.
     * @param _periods The amount of time in seconds of the periods in this contract:
     * - The period after an item is considered valid after submission.
     * - The period after an item is considered safe after being ruled as valid.
     * - The period after an item is considered withdrawn after the submitter starts a withdrawal process.
     * - The period after new arbitration parameters are enforced on all items.
     * @param _stakeMultipliers Multipliers of the arbitration cost in basis points (see MULTIPLIER_DIVISOR) as follows:
     * - The multiplier applied to each party's fee stake for a round when there is no winner/loser in the previous round (e.g. when the arbitrator refused to arbitrate).
     * - The multiplier applied to the winner's fee stake for the subsequent round.
     * - The multiplier applied to the loser's fee stake for the subsequent round.
     * - The multiplier applied to the item's token stake to obtain the required challenge deposit.
     */
    function initialize(
        IArbitrator _arbitrator,
        bytes calldata _arbitratorExtraData,
        string calldata _clearingMetaEvidence,
        address _governor,
        IERC20 _token,
        uint256 _submissionMinDeposit,
        uint256[4] calldata _periods,
        uint256[4] calldata _stakeMultipliers
    ) external {
        if (initialized) revert AlreadyInitialized();
        arbitrator = _arbitrator;
        governor = _governor;
        token = _token;
        submissionMinDeposit = _submissionMinDeposit;
        submissionPeriod = _periods[0]; 
        reinclusionPeriod = _periods[1];
        withdrawingPeriod = _periods[2];
        arbitrationParamsCooldown = _periods[3];
        sharedStakeMultiplier = _stakeMultipliers[0];
        winnerStakeMultiplier = _stakeMultipliers[1];
        loserStakeMultiplier = _stakeMultipliers[2];
        challengeStakeMultiplier = _stakeMultipliers[3];
        _doChangeArbitrationParams(0, _arbitratorExtraData, _clearingMetaEvidence);

        initialized = true;
    }

    /* External and Public */

    // ************************ //
    // *       Requests       * //
    // ************************ //

    /**
     * @dev Submit an item. Accepts enough ETH to cover the arbitration fees, reimburses the rest.
     *  The item will not be considered valid until the submission period ellapses.
     * @param _item The URI to the item data.
     * @param _deposit The amount of token that will be held as collateral to assert correctness.
     *  At the bare minimum it will equal the submissionMinDeposit, but it could be larger
     *  to impose a larger cost upon the griefer.
     */
    function addItem(string calldata _item, uint256 _deposit) external payable {
        bytes32 itemID = keccak256(abi.encodePacked(_item));
        Item storage item = items[itemID];
        if (item.status != Status.Absent) revert ItemWrongStatus();

        // In case item had been included before being Absent, NewItem is not emitted again.
        if (item.includedAt == 0) {
            emit NewItem(itemID, _item);
        } else {
            emit ItemStatusChange(itemID);
        }

        if (_deposit < submissionMinDeposit) revert BelowDeposit();
        if(!token.transferFrom(msg.sender, address(this), _deposit)) revert BelowDeposit();

        uint256 arbitrationParamsIndex = arbitrationParamsChanges.length - 1;
        bytes storage arbitratorExtraData = arbitrationParamsChanges[arbitrationParamsIndex].arbitratorExtraData;

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        if (msg.value < arbitrationCost) revert BelowArbitrationDeposit();

        // When items are Absent as a result of getting manually withdrawn or removed via dispute,
        // all other fields remained, but they will be overwritten here, with the exception of item.requestCount
        item.status = Status.Submitted;
        item.arbitrationDeposit = uint128(arbitrationCost);
        item.submitter = payable(msg.sender);
        item.includedAt = uint48(block.timestamp);
        item.withdrawingTimestamp = 0;
        item.stake = _deposit;
        // item.requestCount: can contain the requestCount on previous challenges, do not reset.

        if (msg.value > arbitrationCost) {
            item.submitter.send(msg.value - arbitrationCost);
        }
    }

    /**
     * @dev Submit a request to withdraw an item from the list.
     * @param _itemID The ID of the item to remove.
     */
    function startWithdrawItem(bytes32 _itemID) external payable {
        Item storage item = items[_itemID];

        // Can be done when Submitted, Reincluded, and Disputed.
        // Absent items don't really matter, but require is down here for correctness.
        if (item.status == Status.Absent) revert ItemWrongStatus();
        if (item.submitter != msg.sender) revert SubmitterOnly();
        if (item.withdrawingTimestamp > 0) revert ItemWithdrawingAlready();
        
        item.withdrawingTimestamp = uint48(block.timestamp);
        emit ItemStartsWithdrawing(_itemID);
    }

    /**
     * @dev Executes a withdrawal process on an item, can be executed by anyone.
     *  This returns the arbitration deposit and the token item stake to submitter.
     * @param _itemID The ID of the item to remove.
     */
    function withdrawItem(bytes32 _itemID) external payable {
        Item storage item = items[_itemID];

        if (item.status == Status.Absent || item.status == Status.Disputed) revert ItemWrongStatus();
        if (
            item.withdrawingTimestamp == 0
            || block.timestamp < item.withdrawingTimestamp + withdrawingPeriod
        ) revert ItemWithdrawingNotYet();

        _doWithdrawItem(_itemID);
        emit ItemStatusChange(_itemID);
    }

    /**
     * @dev Challenges the inclusion of an item. Accepts enough ETH to cover the deposit, reimburses the rest.
     *  Also requires some ERC20 deposit, that will be used to increase the stake of the item.
     *  The required amount is calculated by the contract.
     *  This makes a delay attack have this cost over time: c(t) = (1 + challengeStakeMultiplier) ^ sqrt(t)
     *  Susceptible to self challenges, could be disincetivized by burning some % stake of losing party.
     * @param _itemID The ID of the item which request to challenge.
     * @param _evidence A link to an evidence using its URI. Ignored if not provided.
     */
    function challengeItem(bytes32 _itemID, string calldata _evidence) external payable {
        Item storage item = items[_itemID];
        if (item.status == Status.Absent || item.status == Status.Disputed) revert ItemWrongStatus();

        if (
            item.withdrawingTimestamp > 0
            && block.timestamp >= item.withdrawingTimestamp + withdrawingPeriod
        ) revert ItemWrongStatus(); // Canonically withdrawn, just pending execution 

        uint256 challengeStake = item.stake * challengeStakeMultiplier / MULTIPLIER_DIVISOR;
        if (!token.transferFrom(msg.sender, address(this), challengeStake)) revert BelowDeposit();

        Request storage request = requests[_itemID][item.requestCount++];
        request.challenger = payable(msg.sender);
        request.stake = challengeStake;
        item.status = Status.Disputed;
        
        // Complexity O(N), Governor is trusted to not spam in order to surpass the gas limit.
        // That entails 10_000s of updates, and would cause all challenges to recent items to revert until cooldown.
        // The settings in use will be the latest settings such that: pass the cooldown period OR item was included after.
        // The first arbitrationParams always contains timestamp = 0.
        for (uint256 i = arbitrationParamsChanges.length - 1; i >= 0; i--) {
            uint48 settingsTimestamp = arbitrationParamsChanges[i].timestamp;
            // If an item initiated withdrawal, then the settings that will adjudicate that item are frozen.
            // If the item is not withdrawing, then this reference point is the current time.
            uint256 epochTimestamp = item.withdrawingTimestamp > 0 ? item.withdrawingTimestamp : block.timestamp;
            if (epochTimestamp - arbitrationParamsCooldown >= settingsTimestamp || item.includedAt >= settingsTimestamp) {
                request.arbitrationParamsIndex = uint80(i);
                break;
            }
        }

        ArbitrationParams storage arbitrationParams = arbitrationParamsChanges[request.arbitrationParamsIndex];

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitrationParams.arbitratorExtraData);

        if (msg.value < arbitrationCost) revert BelowArbitrationDeposit();

        // Raise a dispute.
        request.disputeID = arbitrator.createDispute{value: arbitrationCost}(
            RULING_OPTIONS,
            arbitrationParams.arbitratorExtraData
        );
        // For compatibility with GeneralizedTCR consider the request/challenge cycle
        // the first round (index 0), so we need to make the next round index 1.
        request.roundCount = 2;

        disputeIDToItemID[request.disputeID] = _itemID;

        // evidenceGroupID is itemID
        emit Dispute(arbitrator, request.disputeID, request.arbitrationParamsIndex, uint256(_itemID));

        if (bytes(_evidence).length > 0) {
            emit Evidence(arbitrator, uint256(_itemID), msg.sender, _evidence);
        }

        if (msg.value > arbitrationCost) {
            request.challenger.send(msg.value - arbitrationCost);
        }
    }

    /**
     * @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if both sides are fully funded.
     * @param _itemID The ID of the item which request to fund.
     * @param _side The recipient of the contribution.
     */
    function fundAppeal(bytes32 _itemID, Party _side) external payable {
        if (_side == Party.None) revert AppealNotRtA();

        Item storage item = items[_itemID];
        if (item.status != Status.Disputed) revert ItemWrongStatus();

        uint256 lastRequestIndex = item.requestCount - 1;
        Request storage request = requests[_itemID][lastRequestIndex];

        ArbitrationParams storage arbitrationParams = arbitrationParamsChanges[request.arbitrationParamsIndex];

        uint256 lastRoundIndex = request.roundCount - 1;
        Round storage round = rounds[_itemID][lastRequestIndex][lastRoundIndex];
        if (round.sideFunded == _side) revert AppealAlreadyFunded();

        uint256 multiplier;
        {
            (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(request.disputeID);
            if (!(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd)) revert AppealNotWithinPeriod();

            Party winner = Party(arbitrator.currentRuling(request.disputeID));
            if (winner == Party.None) {
                multiplier = sharedStakeMultiplier;
            } else if (_side == winner) {
                multiplier = winnerStakeMultiplier;
            } else {
                multiplier = loserStakeMultiplier;
                if(!(block.timestamp < (appealPeriodStart + appealPeriodEnd) / 2)) revert AppealNotWithinPeriod();
            }
        }

        uint256 appealCost = arbitrator.appealCost(request.disputeID, arbitrationParams.arbitratorExtraData);
        uint256 totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);
        contribute(_itemID, lastRequestIndex, lastRoundIndex, uint256(_side), payable(msg.sender), msg.value, totalCost);

        if (round.amountPaid[uint256(_side)] >= totalCost) {
            if (round.sideFunded == Party.None) {
                round.sideFunded = _side;
            } else {
                // Resets the value because both sides are funded.
                round.sideFunded = Party.None;

                // Raise appeal if both sides are fully funded.
                arbitrator.appeal{value: appealCost}(request.disputeID, arbitrationParams.arbitratorExtraData);
                request.roundCount++;
                round.feeRewards = round.feeRewards.subCap(appealCost);
            }
        }
    }

    /**
     * @dev If a dispute was raised, sends the fee stake rewards and reimbursements proportionally to the contributions made to the winner of a dispute.
     * @param _beneficiary The address that made contributions to a request.
     * @param _itemID The ID of the item submission to withdraw from.
     * @param _requestID The request from which to withdraw from.
     * @param _roundID The round from which to withdraw from.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        bytes32 _itemID,
        uint120 _requestID,
        uint256 _roundID
    ) external {
        Item storage item = items[_itemID];

        // If item.status is Disputed, that means latest Request is still an ongoing dispute.
        if (item.requestCount - 1 == _requestID && item.status == Status.Disputed) revert RewardsPendingDispute();

        Request storage request = requests[_itemID][_requestID];
        Round storage round = rounds[_itemID][_requestID][_roundID];
        uint256[3] storage contributions = contributions[_itemID][_requestID][_roundID][_beneficiary];
        uint256 reward;
        if (_roundID == request.roundCount - 1) {
            // Reimburse if not enough fees were raised to appeal the ruling.
            reward =
                contributions[uint256(Party.Submitter)] +
                contributions[uint256(Party.Challenger)];
        } else if (request.ruling == Party.None) {
            uint256 totalFeesInRound = round.amountPaid[uint256(Party.Challenger)] +
                round.amountPaid[uint256(Party.Submitter)];
            uint256 claimableFees = contributions[uint256(Party.Challenger)] +
                contributions[uint256(Party.Submitter)];
            reward = totalFeesInRound > 0 ? (claimableFees * round.feeRewards) / totalFeesInRound : 0;
        } else {
            // Reward the winner.
            reward = round.amountPaid[uint256(request.ruling)] > 0
                ? (contributions[uint256(request.ruling)] * round.feeRewards) /
                    round.amountPaid[uint256(request.ruling)]
                : 0;
        }
        contributions[uint256(Party.Submitter)] = 0;
        contributions[uint256(Party.Challenger)] = 0;

        if (reward > 0) {
            _beneficiary.send(reward);
            emit RewardWithdrawn(_beneficiary, _itemID, _requestID, _roundID, reward);
        }
    }

    /**
     * @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     * Accounts for the situation where the winner loses a case due to paying less appeal fees than expected.
     * @param _disputeID ID of the dispute in the arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external {
        if (_ruling > RULING_OPTIONS) revert RulingInvalidOption();
        if (address(arbitrator) != msg.sender) revert ArbitratorOnly();

        bytes32 itemID = disputeIDToItemID[_disputeID];
        Item storage item = items[itemID];
        if (item.status != Status.Disputed) revert ItemWrongStatus();
        Request storage request = requests[itemID][item.requestCount - 1];

        uint256 finalRuling;
        Round storage round = rounds[itemID][item.requestCount - 1][request.roundCount - 1];

        // If one side paid its fees, the ruling is in its favor.
        // Note that if the other side had also paid, sideFunded would have been reset
        // and an appeal would have been created.
        if (round.sideFunded == Party.Submitter) {
            finalRuling = uint256(Party.Submitter);
        } else if (round.sideFunded == Party.Challenger) {
            finalRuling = uint256(Party.Challenger);
        } else {
            finalRuling = _ruling;
        }

        emit Ruling(IArbitrator(msg.sender), _disputeID, finalRuling);

        request.ruling = Party(finalRuling);

        if (request.ruling == Party.None) {
            // If the Arbitrator refuses to rule:
            // - Either this Registry was using a Policy that the Arbitrator will always refuse (we don't care).
            // - Or the Registry behaved, but the Arbitrator misbehaved. We will asume this.
            // Since RtA is not a normal ruling, to minimize damage to both parties, split the cost of arb
            // among Submitter and Challenger. This means the item is no longer collateralized, so remove it.
            // Submitter and Challenger deposit will be returned to each respective party.

            // Refunding for challenger
            item.arbitrationDeposit = item.arbitrationDeposit / 2; // if odd, 1 wei will stay in contract
            request.challenger.send(item.arbitrationDeposit);
            try token.transfer(request.challenger, request.stake) {} catch {}
            // Refunding for submitter and removing the Item
            _doWithdrawItem(itemID);
        } else if (request.ruling == Party.Submitter) {
            // If the arbitrator asserts item correctness, the item is reincluded.
            // Also, the request.stake is added to the item.stake, to raise the cost of future challenges.
            item.status = Status.Reincluded;
            item.stake = item.stake + request.stake;
            item.includedAt = uint48(block.timestamp);

            // The submitter might have asked for a withdraw before the Dispute, or during the Dispute.
            // If that's the case, the item will be withdrawn.
            if (item.withdrawingTimestamp > 0) _doWithdrawItem(itemID);
        } else {
            // If the arbitrator rules to remove the item, the challenger is awarded with the arb deposit,
            // and whatever stake was collateralizing the item, plus the stake placed on chalenge.
            // The item is also removed.
            item.status = Status.Absent;

            try token.transfer(request.challenger, item.stake + request.stake) {} catch {}

            request.challenger.send(item.arbitrationDeposit);
        }

        emit ItemStatusChange(itemID);
    }

    /**
     * @dev Submit a reference to evidence. EVENT.
     * @param _itemID The ID of the item which the evidence is related to.
     * @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(bytes32 _itemID, string calldata _evidence) external {
        if (items[_itemID].status == Status.Absent) revert ItemWrongStatus();

        emit Evidence(arbitrator, uint256(_itemID), msg.sender, _evidence);
    }

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /**
     * @dev Change the duration of the submission period.
     * @param _submissionPeriod The new duration of the submission period.
     */
    function changeSubmissionPeriod(uint256 _submissionPeriod) external onlyGovernor {
        submissionPeriod = _submissionPeriod;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the duration of the reinclusion period.
     * @param _reinclusionPeriod The new duration of the reinclusion period.
     */
    function changeReinclusionPeriod(uint256 _reinclusionPeriod) external onlyGovernor {
        reinclusionPeriod = _reinclusionPeriod;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the duration of the withdrawing period.
     * @param _withdrawingPeriod The new duration of the withdrawing period.
     */
    function changeWithdrawingPeriod(uint256 _withdrawingPeriod) external onlyGovernor {
        withdrawingPeriod = _withdrawingPeriod;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the minimum amount required as a deposit to submit an item.
     * @param _submissionMinDeposit The new minimum amount of token required to submit an item.
     */
    function changeSubmissionMinDeposit(uint256 _submissionMinDeposit) external onlyGovernor {
        submissionMinDeposit = _submissionMinDeposit;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the governor of the curated registry.
     * @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
        emit SettingsUpdated();
    }
    
    /**
     * @dev Change the proportion of item.stake that must be deposit as token stake by the challenger of an item.
     * @param _challengeStakeMultiplier Multiplier of item.stake that must be deposit on challenge. In basis points.
     */
    function changeChallengeStakeMultiplier(uint256 _challengeStakeMultiplier) external onlyGovernor {
        challengeStakeMultiplier = _challengeStakeMultiplier;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by parties when there is no winner or loser.
     * @param _sharedStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) external onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by the winner of the previous round.
     * @param _winnerStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) external onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
        emit SettingsUpdated();
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by the party that lost the previous round.
     * @param _loserStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) external onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
        emit SettingsUpdated();
    }

    /**
     * @notice Changes the params related to arbitration.
     * @dev Effectively makes all new items use the new set of params, and older items be eventually subject to them.
     * @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     * @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     */
    function changeArbitrationParams(
        bytes calldata _arbitratorExtraData,
        string calldata _clearingMetaEvidence
    ) external onlyGovernor {
        _doChangeArbitrationParams(uint48(block.timestamp), _arbitratorExtraData, _clearingMetaEvidence);
    }

    /* Internal */

    /**
     * @dev Effectively makes all new items use the new set of params, and older items be eventually subject to them.
     * @param _timestamp Set to 0 on contract initialization, set to block.timestamp on governor arbitration change.
     * @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     * @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     */
    function _doChangeArbitrationParams(
        uint48 _timestamp,
        bytes memory _arbitratorExtraData,
        string memory _clearingMetaEvidence
    ) internal {
        emit MetaEvidence(arbitrationParamsChanges.length, _clearingMetaEvidence);

        arbitrationParamsChanges.push(
            ArbitrationParams({
                timestamp: _timestamp, arbitratorExtraData: _arbitratorExtraData
            })
        );
    }

    /**
     * @dev Effectively triggers the withdrawal of an item, making it Absent and returning funds to the submitter.
     * @param _itemID ID of the Item to withdraw.
     */
    function _doWithdrawItem(
        bytes32 _itemID
    ) internal {
        Item storage item = items[_itemID];

        item.status = Status.Absent;
        
        item.submitter.send(item.arbitrationDeposit);

        try token.transfer(item.submitter, item.stake) {} catch {}
    }

    /**
     * @notice Make a fee contribution.
     * @dev It cannot be inlined in fundAppeal because of the stack limit.
     * @param _itemID The item receiving the contribution.
     * @param _requestID The request to contribute.
     * @param _roundID The round to contribute.
     * @param _side The side for which to contribute.
     * @param _contributor The contributor.
     * @param _amount The amount contributed.
     * @param _totalRequired The total amount required for this side.
     */
    function contribute(
        bytes32 _itemID,
        uint256 _requestID,
        uint256 _roundID,
        uint256 _side,
        address payable _contributor,
        uint256 _amount,
        uint256 _totalRequired
    ) internal {
        Round storage round = rounds[_itemID][_requestID][_roundID];
        uint256 pendingAmount = _totalRequired.subCap(round.amountPaid[_side]);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        if (pendingAmount > _amount) {
            contribution = _amount;
        } else {
            contribution = pendingAmount;
            remainingETH = _amount - pendingAmount;
        }

        contributions[_itemID][_requestID][_roundID][_contributor][_side] += contribution;
        round.amountPaid[_side] += contribution;
        round.feeRewards += contribution;

        // Reimburse leftover ETH.
        if (remainingETH > 0) {
            _contributor.send(remainingETH);
        }

        if (contribution > 0) {
            emit Contribution(_itemID, _requestID, _roundID, _contributor, contribution, Party(_side));
        }
    }

    /* Errors */

    error AlreadyInitialized();
    error GovernorOnly();
    error SubmitterOnly();
    error ArbitratorOnly();
    error ItemWrongStatus();
    error BelowDeposit();
    error BelowArbitrationDeposit();
    error ItemWithdrawingAlready();
    error ItemWithdrawingNotYet();
    error AppealNotRtA();
    error AppealAlreadyFunded();
    error AppealNotWithinPeriod();
    error RewardsPendingDispute();
    error RulingInvalidOption();
}