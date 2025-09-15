// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseDeployScript, console} from "src/deploy/BaseDeployScript.s.sol";
import {LoopingVaultProvider} from "src/LoopingVaultProvider.sol";
import {YieldNestLoopingVault} from "src/YieldNestLoopingVault.sol";

/**
 * @title DeployLoopingVault
 * @notice Deployment script for YieldNestLoopingVault using deterministic CREATE2
 */
contract DeployLoopingVault is BaseDeployScript {
    bytes32 public constant DEPLOYMENT_SALT = bytes32(uint256(0));

    string public constant VAULT_NAME = "YieldNest Looping wstETH Vault";
    string public constant VAULT_SYMBOL = "ynLoopwstETH";

    YieldNestLoopingVault public vault;
    LoopingVaultProvider public provider;

    struct NetworkConfig {
        address weth;
        address wstETH;
        address aavePool;
        address uniswapRouter;
        string networkName;
    }

    function getNetworkConfig()
        internal
        view
        returns (NetworkConfig memory config)
    {
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            // Ethereum Mainnet
            return
                NetworkConfig({
                    weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    wstETH: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
                    aavePool: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
                    uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                    networkName: "Ethereum Mainnet"
                });
        } else if (chainId == 8453) {
            // Base Mainnet
            return
                NetworkConfig({
                    weth: 0x4200000000000000000000000000000000000006,
                    wstETH: 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452,
                    aavePool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
                    uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                    networkName: "Base Mainnet"
                });
        } else if (chainId == 84532) {
            // Base Sepolia
            return
                NetworkConfig({
                    weth: 0x4200000000000000000000000000000000000006,
                    wstETH: 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452,
                    aavePool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
                    uniswapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
                    networkName: "Base Sepolia"
                });
        } else {
            revert("Unsupported network");
        }
    }

    function run() public override {
        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();

        writeDeploymentJson();
    }

    function deploy() internal override {
        // Determine owner address based on network
        address owner = block.chainid == 84532 || block.chainid == 8453
            ? 0x74637F06a8914beB5D00079681c48494FbccBdB9 // Base funded wallet (testnet + mainnet)
            : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil default account 0

        // -----------------------------------------------------------------------------------------
        // Deploy YieldNestLoopingVault Implementation
        // -----------------------------------------------------------------------------------------

        // Deploy provider first
        provider = new LoopingVaultProvider();
        console.log("Provider deployed at:", address(provider));

        YieldNestLoopingVault implementation = new YieldNestLoopingVault();
        console.log("Implementation deployed at:", address(implementation));

        // -----------------------------------------------------------------------------------------
        // Deploy ERC1967Proxy with initialization
        // -----------------------------------------------------------------------------------------

        bytes memory initData = abi.encodeWithSelector(
            YieldNestLoopingVault.initialize.selector,
            owner,
            VAULT_NAME,
            VAULT_SYMBOL
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        vault = YieldNestLoopingVault(payable(address(proxy)));

        console.log("Proxy deployed at:", address(proxy));

        // -----------------------------------------------------------------------------------------
        // Configure Vault
        // -----------------------------------------------------------------------------------------

        configureVault(owner);
    }

    function configureVault(address owner) internal {
        // Grant additional roles (owner already has DEFAULT_ADMIN_ROLE, ALLOCATOR_ROLE, STRATEGY_MANAGER_ROLE, EMERGENCY_ROLE from initialize)
        vault.grantRole(vault.UNPAUSER_ROLE(), owner);
        vault.grantRole(vault.PROVIDER_MANAGER_ROLE(), owner);

        // Set the provider (required before unpausing)
        vault.setProvider(address(provider));

        // Set initial strategy parameters (conservative defaults)
        vault.setStrategyParameters(
            6500, // 65% target LTV (conservative)
            3, // 3 loops
            100 // 1% slippage tolerance
        );

        // Unpause the vault to make it ready for use
        vault.unpause();
    }

    /// @dev Deployment for tests - simplified without configuration
    function deployForTests() external {
        // Determine owner address based on network
        address owner = block.chainid == 84532 || block.chainid == 8453
            ? 0x74637F06a8914beB5D00079681c48494FbccBdB9 // Base funded wallet (testnet + mainnet)
            : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil default account 0

        // Deploy provider first
        provider = new LoopingVaultProvider();

        YieldNestLoopingVault implementation = new YieldNestLoopingVault();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            YieldNestLoopingVault.initialize.selector,
            owner,
            VAULT_NAME,
            VAULT_SYMBOL
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        vault = YieldNestLoopingVault(payable(address(proxy)));
    }
}
