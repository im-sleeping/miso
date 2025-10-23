pragma solidity 0.6.12;

import "@sushiswap/bentobox/contracts/MasterContractManager.sol";

// Thin adapter reusing audited upstream modules (clone factory + approval manager).
// Note: does not explicitly implement local IBentoBoxFactory to avoid 0.6.12 override conflicts
// with BoringFactory (function + public getters). Function signatures are compatible.
contract BentoFactoryLite is MasterContractManager {}
