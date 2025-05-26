/**
 *  @authors: [@greenlucid]
 *  @reviewers: [@fcanela, @jaybuidl, @kokialgo]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.8.27;

import {PermanentGTCR, IArbitrator} from "./PermanentGTCR.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 *  @title PermanentGTCRFactory
 *  This contract acts as a registry for PermanentGTCR instances.
 */
contract PermanentGTCRFactory {
    /**
     *  @dev Emitted when a new Generalized TCR contract is deployed using this factory.
     *  @param _address The address of the newly deployed Generalized TCR.
     */
    event NewGTCR(PermanentGTCR indexed _address);

    PermanentGTCR[] public instances;
    address public GTCR;

    /**
     *  @dev Constructor.
     *  @param _GTCR Address of the generalized TCR contract that is going to be used for each new deployment.
     */
    constructor(address _GTCR) {
        GTCR = _GTCR;
    }

    /**
     * @dev Deploy the arbitrable curated registry.
     * @param _arbitrator Arbitrator to resolve potential disputes. The arbitrator is trusted to support appeal periods and not reenter.
     * @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     * @param _metaEvidence The URI of the meta evidence object.
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
     * @return instance Address the instance was deployed at.
     */
    function deploy(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        string memory _metaEvidence,
        address _governor,
        IERC20 _token,
        uint256 _submissionMinDeposit,
        uint256[4] calldata _periods,
        uint256[4] calldata _stakeMultipliers
    ) public returns (PermanentGTCR instance) {
        instance = clone(GTCR);

        instance.initialize(
            _arbitrator,
            _arbitratorExtraData,
            _metaEvidence,
            _governor,
            _token,
            _submissionMinDeposit,
            _periods,
            _stakeMultipliers
        );

        instances.push(instance);
        emit NewGTCR(instance);
    }

    /**
     * @notice Adaptation of @openzeppelin/contracts/proxy/Clones.sol.
     * @dev Deploys and returns the address of a clone that mimics the behaviour of `GTCR`.
     * @param _implementation Address of the contract to clone.
     * This function uses the create opcode, which should never revert.
     */
    function clone(address _implementation) internal returns (PermanentGTCR instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, _implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != PermanentGTCR(address(0)), "ERC1167: create failed");
    }

    /**
     * @return The number of deployed tcrs using this factory.
     */
    function count() external view returns (uint256) {
        return instances.length;
    }
}
