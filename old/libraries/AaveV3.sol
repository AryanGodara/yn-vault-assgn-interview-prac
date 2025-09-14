// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function setPoolImpl(address newPoolImpl) external;
    function getPoolConfigurator() external view returns (address);
    function setPoolConfiguratorImpl(address newPoolConfiguratorImpl) external;
    function getPriceOracle() external view returns (address);
    function setPriceOracle(address newPriceOracle) external;
    function getACLManager() external view returns (address);
    function setACLManager(address newAclManager) external;
    function getACLAdmin() external view returns (address);
    function setACLAdmin(address newAclAdmin) external;
    function getPriceOracleSentinel() external view returns (address);
    function setPriceOracleSentinel(address newPriceOracleSentinel) external;
    function getPoolDataProvider() external view returns (address);
    function setPoolDataProvider(address newDataProvider) external;
}

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
}

interface IPoolConfigurator {
    function initReserves(
        address[] calldata assets,
        address[] calldata aTokens,
        address[] calldata stableDebtTokens,
        address[] calldata variableDebtTokens,
        address[] calldata interestRateStrategyAddresses
    ) external;
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
}

interface IPoolDataProvider {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}

interface IACLManager {
    function addPoolAdmin(address admin) external;
    function removePoolAdmin(address admin) external;
    function isPoolAdmin(address admin) external view returns (bool);
    function addEmergencyAdmin(address admin) external;
    function removeEmergencyAdmin(address admin) external;
    function isEmergencyAdmin(address admin) external view returns (bool);
}

interface ICollector {
    function transfer(address token, address recipient, uint256 amount) external;
}
