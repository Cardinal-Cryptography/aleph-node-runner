# Aleph Node Runner

A convenience wrapper for running a node, using the Aleph Node docker image under the hood.

## Prerequisites

You will need `docker` and `wget`. If you are using Linux, we recommend that you add your user to the `docker` group so that using `docker` doesn’t require sudo access. You can find the instructions [here](https://docs.docker.com/engine/install/linux-postinstall/).

Clone the repo at https://github.com/Cardinal-Cryptography/aleph-node-runner:

```bash
git clone [https://github.com/Cardinal-Cryptography/aleph-node](https://github.com/Cardinal-Cryptography/aleph-node-runner)
cd aleph-node-runner
```

## Setup and running

Once inside the `aleph-node-runner` folder, run:

```bash
./run_node.sh --name <your_nodes_name> --ip <your IP>  --stash_account <validator_stash_account_id>
```

It might take quite some time before you actually get the node running: the script will first download required files, including a database snapshot (sized ~100GB). You can alternatively skip this step by providing the `--sync_from_genesis` flag (see the 'Additional Options' section). The script will then run the node for you and you should start seeing some block-related output.

> 💡 The choice of <code>your_nodes_name</code> is entirely up to you but for the sake of more comprehensible logs please try using something unique and memorable.

> 💡 Instead of `--ip`,you can provide a domain by using `--dns`.

## Running as an archivist

The default is to run the node as a validator. Should you choose to run as an archivist instead, you need to supply the `--archivist` flag:

```bash
./run_node.sh --archivist --name <your_nodes_name>
```

> 💡 To run as an archivist, you will need additional network config [TODO].

## Additional options

The script allows you to customize the run in several ways, as listed below:

* `--ip`: your public IP (this or `--dns` is required)
* `--dns`: your public domain address (this or `--ip` is required)
* `--data_dir`: specify the directory in which all of the chain data will be stored (defaults to `~/.alephzero`)
* `--mainnet`: join the Aleph Mainnet instead of the default Testnet
* `--sync_from_genesis`: by providing this option, you're choosing not to download and use a DB snapshot, but rather perform a full sync
* `--build_only`: the script will only download and setup everything but will not actually run the binary in case you don't want to join the network yet
* `--image`: you can provide the name and tag of your own Aleph Node image in case you don't want to use one from the official image repository
* `--archivist`: (as described above) run the node as an archivist instead of a validator
* `--name`: (as described above) set the name of the node. If you omit this option, one will be generated for you but it's not encouraged.
* `--stash_account`: provide `AccountId` of the stash account linked to your validator node. If you run as validator, then this argument is mandatory.

