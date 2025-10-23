import { DeployFunction } from 'hardhat-deploy/types'
import { FACTORY_ADDRESS } from '@sushiswap/core-sdk'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

const deployFunction: DeployFunction = async function ({
  deployments,
  getNamedAccounts,
  getChainId,
  ethers,
  run,
}: HardhatRuntimeEnvironment) {
  console.log('Running MISOReceipe deploy script')

  const chainId = parseInt(await getChainId())

  const { deploy, getOrNull } = deployments

  const { deployer } = await getNamedAccounts()

  const misoTokenFactory = await ethers.getContract('MISOTokenFactory')
  const listFactory = await ethers.getContract('ListFactory')
  const misoLauncher = await ethers.getContract('MISOLauncher')
  const misoMarket = await ethers.getContract('MISOMarket')

  // Resolve AMM factory address: prefer SDK mapping; otherwise deploy or reuse local UniswapV2Factory
  let ammFactoryAddress: string | undefined = (FACTORY_ADDRESS as Record<number, string>)[chainId]
  if (!ammFactoryAddress) {
    const existing = await getOrNull('UniswapV2Factory')
    if (existing?.address) {
      ammFactoryAddress = existing.address
    } else {
      const deployedFactory = await deploy('UniswapV2Factory', {
        from: deployer,
        log: true,
        deterministicDeployment: false,
        args: [deployer], // feeToSetter
      })
      ammFactoryAddress = deployedFactory.address
    }
  }

  const { address } = await deploy('AuctionCreation', {
    from: deployer,
    log: true,
    args: [
      misoTokenFactory.address,
      listFactory.address,
      misoLauncher.address,
      misoMarket.address,
      ammFactoryAddress,
    ],
    deterministicDeployment: false,
  })

  console.log('MISOReceipe deployed at ', address)

  console.log('Adding minter ', address)
  await run('add-minter', { address })
  console.log('Minter added ', address)
}

export default deployFunction

deployFunction.dependencies = ['MISOTokenFactory', 'ListFactory', 'MISOLauncher', 'MISOMarket']

deployFunction.tags = ['AuctionCreation']
