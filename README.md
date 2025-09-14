# YieldNest Looping Strategy

I built this looping strategy vault for YieldNest's MAX LRT system. It's basically a leveraged yield strategy that uses Aave V3 to loop cbETH and WETH positions.

## Directory Structure

```
src/
├── YieldNestLoopingVault.sol    # Main vault implementation
├── LoopingVaultProvider.sol     # Strategy parameter provider
└── deploy/
    ├── BaseDeployScript.s.sol   # Base deployment utilities
    └── DeployLoopingVault.s.sol # Vault deployment script

test/
└── fork/
    ├── YieldNestLoopingVault.t.sol  # Main vault tests
    ├── LeverageLooping.t.sol        # Leverage strategy tests
    ├── AaveV3Supply.t.sol           # Aave V3 integration tests
    ├── CurveSwap.t.sol              # Curve swap tests
    └── UniswapV3Swap.t.sol          # Uniswap V3 swap tests
```

## Getting Started

You'll need [Foundry](https://getfoundry.sh/) and [Bun](https://bun.sh/) installed.

```bash
# Initialize the repo
make setup
forge build

# Run all tests
make test

# Run specific test suites
make test-vault      # Main vault functionality
make test-leverage   # Leverage looping logic
make test-aave       # Aave V3 integration
make test-curve      # Curve swaps
make test-uniswap    # Uniswap V3 swaps
```

## What This Does

Users deposit WETH into the vault and get ynLoopETH tokens back. Behind the scenes, I'm using that WETH to build a leveraged position on Aave. The strategy goes like this: deposit WETH as collateral, borrow cbETH against it, swap that cbETH back to WETH on Curve, then repeat the whole thing a few times. This gets you about 3x leverage on ETH staking yields.

The reason I picked cbETH/WETH is pretty straightforward. These assets move together since cbETH is just staked ETH from Coinbase. This means we don't have to worry much about liquidations even with leverage. I've seen other protocols get rekt using uncorrelated pairs, so this seemed like the safer approach.

## Technical Choices

I decided to inherit from YieldNest's BaseVault contract since they already have a solid ERC4626 implementation with all the access control stuff built in. No point reinventing the wheel there.

For swaps, I'm using Curve instead of Uniswap. Curve just handles stable pairs better, and cbETH/WETH is basically a stable pair since they track each other closely. Less slippage means better returns for users.

The looping logic caps out at 5 loops. I tested with more, but the gas costs get ridiculous and the extra yield isn't worth it. Plus, keeping it at 5 loops maintains a health factor above 1.5, which gives us a nice buffer against any black swan events.

## How the Integration Works

YieldNest's MAX vault needs to know how much each strategy token is worth in ETH terms. So I implemented a `getStrategyTokenRate()` function that calculates the current value of ynLoopETH tokens. This lets the MAX vault properly value its holdings and make allocation decisions.

The vault uses role based permissions:

- Only allocators can deposit/withdraw (this will be the MAX vault)
- Admin can update strategy parameters
- Emergency role can pause everything if something goes wrong

## Security Stuff

I'm making a few key assumptions here:

1. Aave V3 won't break (it's been battle tested for a while now)
2. Chainlink oracles stay reliable (needed for liquidation calculations)
3. cbETH and ETH stay correlated (if this breaks, we have bigger problems)
4. Curve pool has enough liquidity for our swaps

To manage risks, I've added:

- Health factor monitoring that keeps us above 1.5 at all times
- Slippage protection on swaps (10% max by default, but it's configurable)
- Emergency pause functionality if we need to stop everything
- Gradual unwinding for large withdrawals to avoid dumping on the market

## Testing

I wrote tests for all the main flows using Foundry's mainnet forking. You can run them with:

```bash
forge test --match-contract YieldNestLoopingVaultTest -v
```

The tests cover normal operations, edge cases like zero deposits, emergency scenarios, and multi user interactions. I'm forking mainnet at a recent block to test against real liquidity conditions.

## Notes on the Implementation

The trickiest part was getting the unwinding logic right. When users withdraw, we need to unwind the leveraged position proportionally without getting liquidated. I ended up implementing an iterative approach that slowly reduces leverage while maintaining a safe health factor.

Another challenge was dealing with Aave's minimum borrow amounts. If someone tries to deposit a tiny amount, the loops might fail because Aave won't let you borrow dust. I added checks for this.

The proxy pattern allows us to upgrade the implementation if we find bugs or want to add features. User funds stay in the proxy, so upgrades don't require migration.

## Deployment

Deploy the implementation first, then the proxy with initialization data. Set up roles after deployment. The MAX vault address needs the ALLOCATOR_ROLE to deposit funds.

## What Could Go Wrong

Honestly, the biggest risk is if cbETH and ETH decorrelate significantly. This could happen if there's a major issue with Coinbase's staking operation. We're also exposed to Aave getting hacked or having a bug, though that seems unlikely at this point.

Liquidation risk is pretty minimal with our conservative parameters, but it's not zero. In extreme market conditions, positions could still get liquidated if we can't rebalance fast enough.

The Curve pool could also run low on liquidity during high volatility, which would make unwinding positions expensive or impossible. I've added slippage controls, but in a real crisis, those might not be enough.
