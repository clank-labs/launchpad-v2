# Clank launchpad verification sources

This directory contains the exact production Solidity sources used for the two
Robinhood Chain launchpad deployments:

- `v2-beta/` — only a few tokens are launched with this factory 
- `v2/` — use this for all new launches

Contracts above are identical except that V2 tokens are burnable and beta
version tokens are not.

In each version,
`deployment.json` records the deployed addresses and transactions from that exact
deployment.

## Requirements

- Foundry with `forge` and `cast`
- Node.js and pnpm
- `jq`
- A Robinhood Chain RPC URL in `ROBINHOOD_RPC_URL`

## Build the exact sources

Choose one snapshot and install its pinned Solidity dependencies:

```bash
cd v2
pnpm install
FOUNDRY_PROFILE=production forge build --force --skip test --skip script --build-info
```

The deployment compiler settings are preserved in `foundry.toml`: Solidity
`0.8.26`, Cancun EVM, optimizer enabled with 200 runs, and `via_ir = true`.

## Verify on Robinhood Blockscout

Read the target address from `deployment.json`, encode the original constructor
arguments, and run `forge verify-contract` from the selected version directory.
For example, the historical `ClankLaunchAndBuy` constructor takes only the
factory address:

```bash
export ROBINHOOD_RPC_URL="https://rpc.mainnet.chain.robinhood.com"

launch_and_buy=$(jq -er '.deployment.launchAndBuy' deployment.json)
factory=$(jq -er '.deployment.factory' deployment.json)
constructor_args=$(cast abi-encode 'constructor(address)' "$factory")

FOUNDRY_PROFILE=production forge verify-contract \
  "$launch_and_buy" contracts/ClankLaunchAndBuy.sol:ClankLaunchAndBuy \
  --chain 4663 \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/ \
  --constructor-args "$constructor_args" \
  --watch
```

Repeat with the address and source identifier for each deployed contract:

| Deployment key | Source identifier | Original constructor arguments |
| --- | --- | --- |
| `hookDeployer` | `contracts/ClankHookDeployer.sol:ClankHookDeployer` | None |
| `hook` | `contracts/ClankInitializationGuardHook.sol:ClankInitializationGuardHook` | `poolManager, deployer` |
| `factory` | `contracts/ClankLaunchFactory.sol:ClankLaunchFactory` | One tuple: `(deployer, poolManager, positionManager, permit2, hook)` |
| `launchDeployer` | `contracts/ClankLaunchDeployer.sol:ClankLaunchDeployer` | `factory` |
| `launchAndBuy` | `contracts/ClankLaunchAndBuy.sol:ClankLaunchAndBuy` | `factory` |
| `feeEscrow` | `contracts/ClankFeeEscrow.sol:ClankFeeEscrow` | None |
| `locker` | `contracts/ClankLaunchLocker.sol:ClankLaunchLocker` | `positionManager` |
| `graduationGuard` | `contracts/ClankGraduationGuard.sol:ClankGraduationGuard` | None |
| `graduationExecutor` | `contracts/ClankGraduationExecutor.sol:ClankGraduationExecutor` | `factory, poolManager, positionManager, permit2, hook, locker, feeEscrow, factory` |

Use these Robinhood Chain dependencies when encoding constructor arguments:

```text
poolManager     0x8366a39CC670B4001A1121B8F6A443A643e40951
positionManager 0x58daec3116aae6D93017bAAea7749052E8a04fA7
permit2         0x000000000022D473030F116dDEE9F6B43aC78BA3
```

For the factory tuple, encode a single tuple argument:

```bash
constructor_args=$(cast abi-encode \
  'constructor((address,address,address,address,address))' \
  "($deployer,$pool_manager,$position_manager,$permit2,$hook)")
```

For contracts without constructor arguments, omit `--constructor-args`. Use the
original deployment values, not current ownership or configuration. A successful
Blockscout response publishes the sources and compiler settings; it does not
audit the contracts or verify their current state.
