---
title: "Using Source Code"
slug: "run-validator-node-using-source"
---

# Using Aptos-core source code

This is a step-by-step guide to install an Aptos node using source code. Follow these steps to configure a validator node and a validator fullnode on separate machines. Use the `fullnode.yaml` to run a validator fullnode&mdash;see Step 12.

## Before you proceed

Make sure the following are installed on your local computer:
   - **Aptos CLI**: https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli

## Install

:::tip One validator node + one validator fullnode
Follow the below instructions **twice**, i.e., first on one machine to run a validator node and the second time on another machine to run a validator fullnode. 
:::

1. Clone the Aptos repo.

      ```bash
      git clone https://github.com/aptos-labs/aptos-core.git
      ```

2. `cd` into `aptos-core` directory.

    ```bash
    cd aptos-core
    ```

3. Run the `scripts/dev_setup.sh` Bash script as shown below. This will prepare your developer environment.

    ```bash
    ./scripts/dev_setup.sh
    ```

4. Update your current shell environment.

    ```bash
    source ~/.cargo/env
    ```

With your development environment ready, now you can start to setup your validator node.

5. Checkout the `mainnet` branch using `git checkout --track origin/mainnet`.

6. Create a directory for your Aptos node composition, and pick a username for your node. e.g.
    ```bash
    export WORKSPACE=mainnet
    export USERNAME=alice
    mkdir ~/$WORKSPACE
    ```

7. Generate the key pairs (node owner, voter, operator key, consensus key and networking key) in your working directory.

    ```bash
    aptos genesis generate-keys --output-dir ~/$WORKSPACE/keys
    ```

    This will create 4 key files under `~/$WORKSPACE/keys` directory: 
      - `public-keys.yaml`
      - `private-keys.yaml`
      - `validator-identity.yaml`, and
      - `validator-full-node-identity.yaml`.
      
      :::danger IMPORTANT

       Backup your `private-keys.yaml` somewhere safe. These keys are important for you to establish ownership of your node. **Never share private keys with anyone.**
      :::

8. Configure validator information. You need to setup a static IP / DNS address (DNS is much preferred) which can be used by the node, and make sure the network / firewalls are properly configured to accept external connections.

    ```bash
    cd ~/$WORKSPACE
    aptos genesis set-validator-configuration \
        --local-repository-dir ~/$WORKSPACE \
        --username $USERNAME \
        --owner-public-identity-file ~/$WORKSPACE/keys/public-keys.yaml \
        --validator-host <validator node IP / DNS address>:<Port> \
        --full-node-host <Full Node IP / DNS address>:<Port> \
        --stake-amount 100000000000000

    # for example, with IP:

    aptos genesis set-validator-configuration \
        --local-repository-dir ~/$WORKSPACE \
        --username $USERNAME \
        --owner-public-identity-file ~/$WORKSPACE/keys/public-keys.yaml \
        --validator-host 35.232.235.205:6180 \
        --full-node-host 34.135.169.144:6182 \
        --stake-amount 100000000000000

    # For example, with DNS:

    aptos genesis set-validator-configuration \
        --local-repository-dir ~/$WORKSPACE \
        --username $USERNAME \
        --owner-public-identity-file ~/$WORKSPACE/keys/public-keys.yaml \
        --validator-host bot.aptosdev.com:6180 \
        --full-node-host fn.bot.aptosdev.com:6182 \
        --stake-amount 100000000000000
    ```

    This will create two YAML files in the `~/$WORKSPACE/$USERNAME` directory: `owner.yaml` and `operator.yaml`. 

9. Download the genesis blob and waypoint for the network you want to connect to. See [Node Files](/nodes/node-files.md) for a full list of files you should download and the download commands. 

10. Copy the `validator.yaml`, `fullnode.yaml` files into this directory.
    ```bash
    mkdir ~/$WORKSPACE/config
    cp docker/compose/aptos-node/validator.yaml ~/$WORKSPACE/config/validator.yaml
    cp docker/compose/aptos-node/fullnode.yaml ~/$WORKSPACE/config/fullnode.yaml
    ```

    Modify the config files to update the data directory, key path, genesis file path, waypoint path. User must have write access to data directory.

11. <span id="source-code-vfn">To recap, in your working directory (`~/$WORKSPACE`), you should have a list of files:</span>

    - `config` folder containing:
      - `validator.yaml` validator config file
      - `fullnode.yaml` fullnode config file
    - `keys` folder containing:
      - `public-keys.yaml`: Public keys for the owner account, consensus, networking (from step 7).
      - `private-keys.yaml`: Private keys for the owner account, consensus, networking (from step 7).
      - `validator-identity.yaml`: Private keys for setting the Validator identity (from step 7).
      - `validator-full-node-identity.yaml`: Private keys for setting validator full node identity (from step 7).
    - `username` folder containing: 
      - `owner.yaml`: Define owner, operator, and voter mapping. They are all the same account in test mode (from step 8).
      - `operator.yaml`: Node information that will be used for both the Validator and the fullnode (from step 8). 
    - `waypoint.txt`: The waypoint for the genesis transaction (from step 9).
    - `genesis.blob` The genesis binary that contains all the information about the framework, validatorSet and more (from step 9).

12. Start your validator by running the below command:

    ```bash
    cargo run -p aptos-node --release -- -f ~/$WORKSPACE/config/validator.yaml
    ```

    Run validator fullnode on **another machine**:

    ```bash
    cargo run -p aptos-node --release -- -f ~/$WORKSPACE/config/fullnode.yaml
    ```

Now you have completed setting up your node.
