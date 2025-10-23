import { task } from 'hardhat/config'
import { utils } from 'ethers'

task('add-minter', 'Adds minter')
  .addParam('address', 'New minter')
  .setAction(async function ({ address }, { ethers: { getNamedSigner, provider, getContract } }) {
    const admin = await getNamedSigner('admin')
    const deployer = await getNamedSigner('deployer')

    const adminBal = await provider.getBalance(admin.address)
    const deployerBal = await provider.getBalance(deployer.address)

    const signer = adminBal.gt(utils.parseEther('0.005')) ? admin : deployer
    console.log(`Using signer ${signer.address} to add minter (admin=${admin.address}, deployer=${deployer.address})`)

    const accessControl = await getContract('MISOAccessControls', signer)

    console.log('Adding minter...')
    await (await accessControl.addMinterRole(address)).wait()
    console.log('Minter added!')
  })
