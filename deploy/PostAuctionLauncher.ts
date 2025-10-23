import { DeployFunction } from 'hardhat-deploy/types'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { WNATIVE_ADDRESS } from '@sushiswap/core-sdk'

const deployFunction: DeployFunction = async function ({
  deployments,
  getNamedAccounts,
  getChainId,
}: HardhatRuntimeEnvironment) {
  console.log('Running PostAuctionLauncher deploy script')

  const chainId = parseInt(await getChainId())

  const { deploy, getOrNull } = deployments

  // Resolve WETH/WNATIVE: prefer env var, then SDK mapping, then local deployment
  let wnativeAddress: string | undefined = process.env.WETH_ADDRESS || (WNATIVE_ADDRESS as Record<number, string>)[chainId]
  if (!wnativeAddress) {
    // Try to reuse an existing local deployment
    const existingWeth = await getOrNull('WETH9')
    if (existingWeth?.address) {
      wnativeAddress = existingWeth.address
    } else {
      const { deployer } = await getNamedAccounts()
      const weth9 = await deploy('WETH9', {
        from: deployer,
        log: true,
        deterministicDeployment: false,
        args: [],
      })
      wnativeAddress = weth9.address
    }
  }

  const { deployer } = await getNamedAccounts()

  const { address } = await deploy('PostAuctionLauncher', {
    from: deployer,
    log: true,
    deterministicDeployment: false,
    args: [wnativeAddress],
  })

  console.log('PostAuctionLauncher deployed at ', address, 'with WETH', wnativeAddress)
}

export default deployFunction

deployFunction.dependencies = []

deployFunction.tags = ['PostAuctionLauncher']
