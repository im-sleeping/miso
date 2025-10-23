import { BENTOBOX_ADDRESS } from '@sushiswap/core-sdk'
import { BigNumber } from '@ethersproject/bignumber'
import { DeployFunction } from 'hardhat-deploy/types'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

const deployFunction: DeployFunction = async function ({
  deployments,
  getNamedAccounts,
  ethers,
  getChainId,
}: HardhatRuntimeEnvironment) {
  console.log('Running MISOMarket deploy script')

  const chainId = parseInt(await getChainId())

  const { deploy, getOrNull } = deployments

  const { deployer } = await getNamedAccounts()

  // Resolve BentoBox address: prefer SDK mapping; otherwise deploy or reuse BentoFactoryLite
  let bentoBoxAddress: string | undefined = (BENTOBOX_ADDRESS as Record<number, string>)[chainId]
  if (!bentoBoxAddress) {
    const existingLite = await getOrNull('BentoFactoryLite')
    if (existingLite?.address) {
      bentoBoxAddress = existingLite.address
    } else {
      const deployedLite = await deploy('BentoFactoryLite', {
        from: deployer,
        log: true,
        deterministicDeployment: false,
      })
      bentoBoxAddress = deployedLite.address
    }
  }

  const { address } = await deploy('MISOMarket', {
    from: deployer,
    log: true,
    deterministicDeployment: false,
  })

  console.log('MISOMarket deployed at ', address)

  const misoMarket = await ethers.getContract('MISOMarket')

  const templateId: BigNumber = await misoMarket.auctionTemplateId()

  if (templateId.toNumber() === 0) {
    const accessControls = await ethers.getContract('MISOAccessControls')
    const batchAuction = await ethers.getContract('BatchAuction')
    const crowdsale = await ethers.getContract('Crowdsale')
    const dutchAuction = await ethers.getContract('DutchAuction')
    const hyperbolicAuction = await ethers.getContract('HyperbolicAuction')
    const proRataFixedPrice = await ethers.getContract('ProRataFixedPrice')
    console.log('MISOMarket initilising')
    await (
      await misoMarket.initMISOMarket(
        accessControls.address,
        bentoBoxAddress,
        [batchAuction.address, crowdsale.address, dutchAuction.address, hyperbolicAuction.address, proRataFixedPrice.address],
        {
          from: deployer,
        }
      )
    ).wait()
    console.log('MISOMarket initilising')
  }
}

export default deployFunction

deployFunction.dependencies = ['MISOAccessControls', 'BatchAuction', 'Crowdsale', 'DutchAuction', 'HyperbolicAuction', 'ProRataFixedPrice']

deployFunction.tags = ['MISOMarket']
