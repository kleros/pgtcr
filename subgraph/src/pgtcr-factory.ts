/* eslint-disable prefer-const */
import { BigInt } from '@graphprotocol/graph-ts';
import { NewGTCR } from '../generated/PermanentGTCRFactory/PermanentGTCRFactory';
import { Arbitrator, Registry } from '../generated/schema';
import { PermanentGTCR as PGTCRDataSource, IArbitrator as IArbitratorDataSource } from '../generated/templates';
import { PermanentGTCR } from '../generated/templates/PermanentGTCR/PermanentGTCR';

export function handleNewGTCR(event: NewGTCR): void {
  PGTCRDataSource.create(event.params._address);
  let registry = new Registry(event.params._address.toHexString());
  let pgtcr = PermanentGTCR.bind(event.address);

  // we dont create arbsetting here! goto handleMetaEvidence in pgtcr.ts
  let arbitratorAddress = pgtcr.arbitrator();
  let arbitrator = Arbitrator.load(arbitratorAddress.toHexString());
  if (!arbitrator) {
    // Use this opportunity to create the arbitrator datasource
    // to start monitoring it for events (if we aren't already).
    IArbitratorDataSource.create(arbitratorAddress);
    arbitrator = new Arbitrator(arbitratorAddress.toHexString());
    arbitrator.save();
  }

  registry.arbitrationSettingCount = BigInt.fromI32(0);
  registry.numberOfSubmitted = BigInt.fromI32(0);
  registry.numberOfAbsent = BigInt.fromI32(0);
  registry.numberOfDisputed = BigInt.fromI32(0);
  registry.createdAt = event.block.timestamp;
  registry.arbitrator = arbitrator.id;
  registry.token = pgtcr.token();
  registry.submissionMinDeposit = pgtcr.submissionMinDeposit();
  registry.submissionPeriod = pgtcr.submissionPeriod();
  registry.reinclusionPeriod = pgtcr.reinclusionPeriod();
  registry.withdrawingPeriod = pgtcr.withdrawingPeriod();
  registry.arbitrationParamsCooldown = pgtcr.arbitrationParamsCooldown();
  registry.challengeStakeMultiplier = pgtcr.challengeStakeMultiplier();
  registry.winnerStakeMultiplier = pgtcr.winnerStakeMultiplier();
  registry.loserStakeMultiplier = pgtcr.loserStakeMultiplier();
  registry.sharedStakeMultiplier = pgtcr.sharedStakeMultiplier();
  registry.save();
}