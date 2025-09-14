// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Strategy} from "./../AaveV3Strategy.sol";
import {AaveV3BaseSepolia, AaveV3BaseSepoliaAssets} from "./../libraries/AaveV3BaseSepolia.sol";
import {VaultCore} from "./../VaultCore.sol";
import {BaseDeployScript, console} from "./BaseDeployScript.sol";

/**
 * @title DeployVault
 * @notice Deployment script for VaultCore and AaveV3Strategy using deterministic CREATE2
 */
contract DeployVault is BaseDeployScript {
    // -----------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------

    bytes32 public constant DEPLOYMENT_SALT = bytes32(uint256(0));

    string public constant VAULT_NAME = "Yield Nest USDC Vault";
    string public constant VAULT_SYMBOL = "ynUSDC";
    string public constant STRATEGY_NAME = "Aave V3 USDC Strategy";

    // -----------------------------------------------------------------------------------------
    // Deployed Contracts
    // -----------------------------------------------------------------------------------------

    VaultCore public vaultCore;
    AaveV3Strategy public aaveV3Strategy;

    // -----------------------------------------------------------------------------------------
    // Network Configuration
    // -----------------------------------------------------------------------------------------

    struct NetworkConfig {
        address asset;
        address aavePool;
        string networkName;
    }

    function getNetworkConfig() internal view returns (NetworkConfig memory config) {
        uint256 chainId = block.chainid;

        if (chainId == 8453) {
            // Base Mainnet - TODO: Add Base mainnet addresses when needed
            revert("Base Mainnet not yet configured");
        } else if (chainId == 84532) {
            // Base Sepolia
            config = NetworkConfig({
                asset: AaveV3BaseSepoliaAssets.USDC_UNDERLYING,
                aavePool: address(AaveV3BaseSepolia.POOL),
                networkName: "Base Sepolia"
            });
        } else {
            revert("Unsupported network");
        }
    }

    function run() public override {
        NetworkConfig memory config = getNetworkConfig();

        console.log("=== DEPLOYING ON", config.networkName, "===");
        console.log("Asset address:", config.asset);
        console.log("Aave Pool address:", config.aavePool);

        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();

        writeDeploymentJson();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("VaultCore deployed at:", address(vaultCore));
        console.log("AaveV3Strategy deployed at:", address(aaveV3Strategy));
    }

    function deploy() internal override {
        NetworkConfig memory config = getNetworkConfig();

        // Determine owner address based on network
        // The owner is anvil address 0 in local testing and anvil deployments, and the HappyChain deployer otherwise.
        address owner = block.chainid == 84532 || block.chainid == 8453
            ? 0x74637F06a8914beB5D00079681c48494FbccBdB9 // Base funded wallet (testnet + mainnet :p)
            : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil default account 0

        // -----------------------------------------------------------------------------------------
        // Deploy Vault First (with no strategy initially)
        // -----------------------------------------------------------------------------------------

        (address payable _vaultCore,) = deployDeterministic(
            "VaultCore",
            type(VaultCore).creationCode,
            abi.encode(IERC20(config.asset), VAULT_NAME, VAULT_SYMBOL, owner),
            DEPLOYMENT_SALT
        );
        vaultCore = VaultCore(_vaultCore);

        // -----------------------------------------------------------------------------------------
        // Deploy Strategy with Vault Reference
        // -----------------------------------------------------------------------------------------

        (address payable _aaveV3Strategy,) = deployDeterministic(
            "AaveV3Strategy",
            type(AaveV3Strategy).creationCode,
            abi.encode(address(vaultCore), config.asset),
            DEPLOYMENT_SALT
        );
        aaveV3Strategy = AaveV3Strategy(_aaveV3Strategy);

        // -----------------------------------------------------------------------------------------
        // Initialize Strategy in Vault
        // -----------------------------------------------------------------------------------------

        // Initialize the strategy in the vault (can only be called once)
        vaultCore.initStrategy(address(aaveV3Strategy));

        console.log("Vault and Strategy deployed and linked successfully");
        console.log("Vault:", address(vaultCore));
        console.log("Strategy:", address(aaveV3Strategy));
    }
}
