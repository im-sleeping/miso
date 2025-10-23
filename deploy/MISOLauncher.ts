import { BENTOBOX_ADDRESS } from '@sushiswap/core-sdk'
import { BigNumber } from '@ethersproject/bignumber'
import { DeployFunction } from 'hardhat-deploy/types'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

const deployFunction: DeployFunction = async function ({
  deployments,
  getNamedAccounts,
  getChainId,
  ethers,
}: HardhatRuntimeEnvironment) {
  console.log('Running MISOLauncher deploy script')

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

  const { address } = await deploy('MISOLauncher', {
    from: deployer,
    log: true,
    deterministicDeployment: false,
  })

  console.log('MISOLauncher deployed at ', address)

  const misoLauncher = await ethers.getContract('MISOLauncher')

  if ((await misoLauncher.accessControls()) === ethers.constants.AddressZero) {
    const accessControls = await ethers.getContract('MISOAccessControls')
    console.log('MISOAccessControls initilising')
    await (await misoLauncher.initMISOLauncher(accessControls.address, bentoBoxAddress)).wait()
    console.log('MISOAccessControls initilised')
  }

  const launcherTemplateId: BigNumber = await misoLauncher.launcherTemplateId()

  if (launcherTemplateId.toNumber() == 0) {
    const postAuction = await ethers.getContract('PostAuctionLauncher')
    await (await misoLauncher.addLiquidityLauncherTemplate(postAuction.address)).wait()
  }
}

export default deployFunction

deployFunction.dependencies = ['MISOAccessControls', 'PostAuctionLauncher']

deployFunction.tags = ['MISOLauncher']
