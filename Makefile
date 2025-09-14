# Unlock more powerful features than plain POSIX sh.
SHELL := /bin/bash

# add node_modules from one layer up
ADD_PATH = $(eval PATH := $(if $(findstring :$(PATH_TO_ADD):,:$(PATH):),$(PATH),$(1):$(PATH)))
$(call ADD_PATH , ./node_modules/.bin)

# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Set CONFIG to "LOCAL" by default. Other valid values: "TEST" or "MAIN".
# Must be exported as some deploy scripts depend on it.
export CONFIG ?= LOCAL

# Type of proxy contract to use for vault deployment.
# Valid values: "BEACON" or "UUPS". Defaults to BEACON.
export PROXY_TYPE ?= BEACON

# Port at which Anvil will be running.
export ANVIL_PORT ?= 8545

# Block time for Anvil, automining if 0
export ANVIL_BLOCK_TIME ?= 2

ANVIL_BLOCK_TIME_ARG := $(if $(findstring '0','$(ANVIL_BLOCK_TIME)'),,--block-time $(ANVIL_BLOCK_TIME))

# Deployment mode:
# - "deploy" — deploy contracts normally
# - "dry" — for a dry-run that doesn't send transactions
# - "resume" — resumes the previous deployment
DEPLOY ?= deploy

# Flags for `ln` (symlink creation)
LN_FLAGS := $(if $(findstring Darwin,$(shell uname)),-shF,-sfT)

# Flag to include or exclude metadata based on configuration
METADATA_FLAG := $(if $(findstring false,$(APPEND_METADATA_$(CONFIG))),--no-metadata,)

# See README.md for more documentation.

# Location of node_modules in the current contracts directory.
NODE_MODULES := ./node_modules

# The reason for this weird setup is that the IntelliJ solidity plugin will not resolve imports
# if they're not in `lib` and do not have a `src` directory (the `remappings.txt` file is ignored).
setup:
	if [ ! -f .env ]; then cp .env.example .env; fi
	bun install
	rm -rf lib
	mkdir -p lib/{openzeppelin,oz-upgradeable,aave-core-v3,yieldnest-vault,uniswap-v3-periphery,uniswap-v3-core}
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/solady lib/solady
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/forge-std lib/forge-std
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/yieldnest-vault lib/yieldnest-vault
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/@uniswap/v3-periphery lib/uniswap-v3-periphery
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/@uniswap/v3-core lib/uniswap-v3-core
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/@openzeppelin/contracts lib/openzeppelin/src
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/@openzeppelin/contracts-upgradeable lib/oz-upgradeable/src
	ln $(LN_FLAGS) $$(pwd)/$(NODE_MODULES)/@aave/core-v3 lib/aave-core-v3

.PHONY: setup

####################################################################################################
# Build

build: ## Builds all contracts
	forge build $(METADATA_FLAG)
.PHONY: build

watch: ## Builds contracts & runs tests on contract change
	forge test --watch src/
.PHONY: watch

clean: ## Removes build output
	@# Avoid failures when trying to clean after a preceding `make nuke`.
	forge clean > /dev/null 2> /dev/null || true
	rm -rf node_modules/.tmp
	rm -rf docs
.PHONY: clean

nuke: clean ## Removes build output and dependencies
	rm -rf lib
.PHONY: nuke

####################################################################################################
##@ Testing

test: ## Runs tests
	forge test -vvv
.PHONY: test

test-aave: ## Runs Aave V3 supply tests
	forge test --match-contract AaveV3SupplyTest -vvv
.PHONY: test-aave

test-curve: ## Runs Curve swap tests
	forge test --match-contract CurveSwapTest -vvv
.PHONY: test-curve

test-uniswap: ## Runs Uniswap V3 swap tests
	forge test --match-contract UniswapV3SwapTest -vvv
.PHONY: test-uniswap

test-leverage: ## Runs leverage looping tests
	forge test --match-contract LeverageLoopingTest -vvv
.PHONY: test-leverage

test-vault: ## Runs main vault tests
	forge test --match-contract YieldNestLoopingVaultTest -vvv
.PHONY: test-vault

testv: ## Runs test with max verbosity
	forge test -vvvv
.PHONY: testv

forge-fmt-check:
	@forge fmt --check src || true
.PHONY: forge-fmt-check

forge-fmt:
	@forge fmt src || true
.PHONY: forge-fmt

solhint-check:
	@npx solhint --config ./.solhint.json "src/**/*.sol" || echo "Solhint check skipped"
.PHONY: solhint-check

solhint:
	@echo "y" | npx solhint --config ./.solhint.json "src/**/*.sol" --fix || echo "Solhint fixes skipped"
.PHONY: solhint

check: forge-fmt-check solhint-check ## Checks formatting & linting (no files touched)
	biome check ./;
.PHONY: check

format: forge-fmt solhint ## Formats & lint (autofixes)
	@biome check ./ --write || true
.PHONY: format

anvil: ## Runs anvil at $ANVIL_PORT (blocking)
	anvil --port $(ANVIL_PORT) $(ANVIL_BLOCK_TIME_ARG) --print-traces
.PHONY: anvil

anvil-background: ## Runs anvil at in the background at $ANVIL_PORT, logging to anvil.log
	anvil --port $(ANVIL_PORT) $(ANVIL_BLOCK_TIME_ARG) > anvil.log 2>&1 &
	@echo "Running Anvil at {http,ws}://localhost:$(ANVIL_PORT)"
.PHONY: anvil-background

kill-anvil: ## Kill an existing Anvil process running at $ANVIL_PORT
	@lsof -t -iTCP:$(ANVIL_PORT) -sTCP:LISTEN | xargs kill -9 2>/dev/null || true
.PHONY: kill-anvil

####################################################################################################
##@ Deployment

strip_quotes = $(shell echo $(1) | sed -e 's/^["'\'']//; s/["'\'']$$//')
VERIFY_FLAG := $(if $(findstring true,$(VERIFY_$(CONFIG))),--verify,)
VERIFIER_FLAG := $(if $(findstring true,$(VERIFY_$(CONFIG))),$(call strip_quotes,$(VERIFIER_FLAG_$(CONFIG))),)
VIA_IR_FLAG := $(if $(findstring true,$(VIA_IR)),--via-ir,)
CHECK_UPGRADE := true

ifeq ($(DEPLOY),deploy)
	BROADCAST_FLAG := --broadcast
endif

ifeq ($(DEPLOY),dry)
	BROADCAST_FLAG :=
	VERIFY_FLAG :=
endif

ifeq ($(DEPLOY),resume)
	BROADCAST_FLAG := --resume
	CHECK_UPGRADE := false
endif

# Deploys contracts locally, to testnet or mainnet depending on the $CONFIG value.
# You can also specify MODE=dry to not submit the tx, or MODE=resume to resume the last deployment.
deploy:
	$(call run-deploy-script,src/deploy/$(DEPLOY_SCRIPT))
	$(call post-deploy)
	$(call save-deployment)
.PHONY: deploy

# Defines run-deploy-script to use environment variable keys or Foundry accounts depending on the
# value of USE_FOUNDRY_ACCOUNT.
define run-deploy-script
	$(eval __USE_ACC := $(findstring true,$(USE_FOUNDRY_ACCOUNT)))
	$(eval __DEPLOY_FUNC := $(if $(__USE_ACC),run-deploy-script-account,run-deploy-script-key))
	$(call $(__DEPLOY_FUNC),$(1))
endef

# Deploys using a private key supplied in an environment variable (dependent on the $CONFIG value).
define run-deploy-script-key
    @# Command intentionally output.
	forge script $(1) \
		--fork-url $(RPC_$(CONFIG)) \
		--private-key $(PRIVATE_KEY_$(CONFIG)) \
		$(BROADCAST_FLAG) \
		$(VERIFY_FLAG) \
		$(VERIFIER_FLAG) \
		$(VIA_IR_FLAG) \
		$(METADATA_FLAG) -vvvv
endef

# Deploys using a private key supplied by a Foundry account. The account name and password file
# are supplied in environment variables (dependent on the $CONFIG value).
define run-deploy-script-account
	@$(eval DEPLOY_SENDER := `cast wallet address \
		--account $(ACCOUNT_$(CONFIG)) \
		--password-file $(PASSFILE_$(CONFIG))`)
	@# Command intentionally output.
	forge script $(1) \
		--fork-url $(RPC_$(CONFIG)) \
		--account $(ACCOUNT_$(CONFIG)) \
		--password-file $(PASSFILE_$(CONFIG)) \
		--sender $(DEPLOY_SENDER) \
		$(BROADCAST_FLAG) \
		$(VERIFY_FLAG) \
		$(VERIFIER_FLAG) \
		$(VIA_IR_FLAG) \
		$(METADATA_FLAG) -vvvv
endef

# Post-processes the deployment output.
define post-deploy
	@# Print address logs from the deploy script.
	@cat out/deployment.json && printf "\n"

	@# Extract ABIs from the deployed contracts and save to out/abis.json.
	@# The metadata flag is crucial to avoid invalidating the build.
	@export CONTRACTS=$$(bun node-jq '[.[]] | unique' out/abiMap.json) && \
	node-jq '[.[]] | unique[]' out/abiMap.json \
		| xargs -I'{}' forge inspect {} abi --json $(METADATA_FLAG) \
		| node-jq --slurp --argjson contracts "$$CONTRACTS" '[$$contracts, .] | transpose | map({ (.[0]): .[1] }) | add' \
		> out/abis.json;

	@# Generate "as const" TypeScript ABI definitions for type usage.
	@# To use you will want to symlink this file from the deployments dir to the consuming package,
	@# and .gitignore it.

	@cat scripts/abi_types_fragment_begin.ts.txt > out/abis.ts
	@printf "\n\n" >> out/abis.ts

	@printf "const contractToAbi = (" >> out/abis.ts
	@cat out/abis.json >> out/abis.ts
	@printf ") as const\n\n" >> out/abis.ts

	@printf "const aliasToContract = (" >> out/abis.ts
	@cat out/abiMap.json >> out/abis.ts
	@printf ") as const\n\n" >> out/abis.ts

	@printf "export const deployment = (" >> out/abis.ts
	@cat out/deployment.json >> out/abis.ts
	@printf ") as const\n\n" >> out/abis.ts

	@cat scripts/abi_types_fragment_end.ts.txt >> out/abis.ts
	@printf "\n" >> out/abis.ts
endef

# Explanation of the jq command;
#    CONTRACTS == [ "Contract1", "Contract2", ... ]
#    The command up to xargs sequentially emit the ABI (JSON objects) of each contract.
#	 The jq command in the '--slurp' line starts by creating [CONTRACTS, ArrayOfABIs]
#    It then transposes it: [ ["Contract1", ABI1], ["Contract2", ABI2], ... ]
#    Finally, it maps it to [{ "Contract1": ABI1 } , { "Contract2": ABI2 } , ... ]
#    then joins alls of them in a single JSON dictionary.

# Saves all information pertaining to a deployment to deployments/$DEPLOYMENT_NAME.
# The suggested $DEPLOYMENT_NAME format is "CHAIN/NAME", e.g. "sepolia/vault".
# Will save the latest deployment from $DEPLOY_SCRIPT.
define save-deployment
	@mkdir -p deployments/$(DEPLOYMENT_NAME)
	@cp -f out/{deployment.json,abiMap.json,abis.json,abis.ts} deployments/$(DEPLOYMENT_NAME)
	$(eval __CHAIN_ID := `cast chain-id --rpc-url $(RPC_$(CONFIG))`)
	$(eval __RUN_FILE := broadcast/$(DEPLOY_SCRIPT)/$(__CHAIN_ID)/run-latest.json)
	@echo "Saved deployment to deployments/$(DEPLOYMENT_NAME)"
endef

####################################################################################################
# Deploy Scripts

# Defines and exports CONFIG
define set-config
	export CONFIG=$(1)
endef

# Sets CHAIN_ID based on RPC.
define set-chain-id
	CHAIN_ID = $(shell cast chain-id --rpc-url $(RPC_$(CONFIG)))
endef

# Sets CHAIN_NAME based on CHAIN_ID when called.
define set-chain-name
	ifeq ($(CHAIN_ID),31337)
		CHAIN_NAME = anvil
	else ifeq ($(CHAIN_ID),84532)
		CHAIN_NAME = base-sepolia
	else ifeq ($(CHAIN_ID),11155111)
		CHAIN_NAME = sepolia
	else ifeq ($(CHAIN_ID),8453)
		CHAIN_NAME = base
	else ifeq ($(CHAIN_ID),1)
		CHAIN_NAME = ethereum
	else
		CHAIN_NAME = unknown
	endif
endef

# Sets CHAIN_ID and CHAIN_NAME, defines and *exports* DEPLOYMENT_NAME = CHAIN_NAME/$(1)
# Call like this: $(eval $(call set-deployment-name,myDeployment))
define set-deployment-name
	$(eval $(set-chain-id))
	$(eval $(set-chain-name))
	# Export for use in recursive make invocations.
	export DEPLOYMENT_NAME := $(CHAIN_NAME)/$(1)
endef

deploy-mocks: ## Deploys mock contracts for testing
	$(eval $(call set-deployment-name,mocks))
	make deploy DEPLOY_SCRIPT=DeployMocks.s.sol
.PHONY: deploy-mocks

deploy-vault: ## Deploys the looping vault contracts
	$(eval $(call set-deployment-name,vault))
	make deploy DEPLOY_SCRIPT=DeployLoopingVault.sol
.PHONY: deploy-vault
