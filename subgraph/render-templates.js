const fs = require('fs-extra');
const mustache = require('mustache');

const chainNameToChainId = {
  gnosis: 100,
  xdai: 100, // For Goldsky: https://docs.goldsky.com/chains/supported-networks
  mainnet: 1,
  goerli: 5,
  sepolia: 11155111,
};

async function main() {
  const networkName = process.argv[2];
  if (networkName === undefined) throw new Error("You need to pass chainId");
  const chainId = chainNameToChainId[networkName];
  const deployments = JSON.parse(fs.readFileSync('networks.json', 'utf8'));
  const { address: pgtcrFactory, startBlock: pgtcrFactoryStartBlock } =
    deployments['PermanentGTCRFactory'][chainId];
  const templateData = {
    network: networkName,
  };
  templateData['PermanentGTCRFactory'] = {
    address: pgtcrFactory,
    addressLowerCase: pgtcrFactory.toLowerCase(),
    startBlock: pgtcrFactoryStartBlock,
  };

  for (const templatedFileDesc of [['subgraph', 'yaml']]) {
    const template = fs
      .readFileSync(`${templatedFileDesc[0]}.template.${templatedFileDesc[1]}`)
      .toString();
    fs.writeFileSync(
      `${templatedFileDesc[0]}.${templatedFileDesc[1]}`,
      mustache.render(template, templateData),
    );
  }
}

main();