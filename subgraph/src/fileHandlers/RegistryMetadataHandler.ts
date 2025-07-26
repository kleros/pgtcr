import { Bytes, dataSource, json, log } from '@graphprotocol/graph-ts';
import { RegistryMetadata } from '../../generated/schema';
import { JSONValueToBool, JSONValueToMaybeString } from '../utils';

export function handleRegistryMetadata(content: Bytes): void {
  const ipfsHash = dataSource.stringParam();

  const parsedResult = json.try_fromBytes(content);

  const context = dataSource.context();
  const count = context.getBigInt('count');
  const address = context.getString('address');

  const id = `${address}-${count.toString()}`;

  const metadata = new RegistryMetadata(id);

  log.debug(`ipfs hash : {}, content : {}`, [ipfsHash, content.toString()]);

  if (!parsedResult.isOk || parsedResult.isError) {
    log.warning(`Error converting object for hash {}`, [ipfsHash]);
    metadata.save();
    return;
  }

  const value = parsedResult.value.toObject();

  const metadataValue = value.get('metadata');
  if (!metadataValue) {
    log.warning(`Error getting metadata values from ipfs hash {}`, [ipfsHash]);
    metadata.save();
    return;
  }

  const data = metadataValue.toObject();

  const title = data.get('tcrTitle');
  const description = data.get('tcrDescription');
  const itemName = data.get('itemName');
  const itemNamePlural = data.get('itemNamePlural');
  const policyURI = value.get("fileURI"); // taken from root, not from metadata!
  const logoURI = data.get('logoURI');
  const requireRemovalEvidence = data.get('requireRemovalEvidence');

  metadata.title = JSONValueToMaybeString(title);
  metadata.description = JSONValueToMaybeString(description);
  metadata.itemName = JSONValueToMaybeString(itemName);
  metadata.itemNamePlural = JSONValueToMaybeString(itemNamePlural);
  metadata.policyURI = JSONValueToMaybeString(policyURI);
  metadata.logoURI = JSONValueToMaybeString(logoURI);
  metadata.requireRemovalEvidence = JSONValueToBool(requireRemovalEvidence);

  metadata.save();
}