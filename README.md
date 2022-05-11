# aleph-node-runner

# Prerequisites

You will need `docker` and `wget`. If you are using Linux, we recommend that you add your user to the `docker` group so that using `docker` doesn’t require sudo access. You can find the instructions [here](https://docs.docker.com/engine/install/linux-postinstall/).

Clone the repo at https://github.com/Cardinal-Cryptography/aleph-node-runner:

```bash
git clone [https://github.com/Cardinal-Cryptography/aleph-node](https://github.com/Cardinal-Cryptography/aleph-node-runner)
cd aleph-node-runner
```

# Setup and running

Once inside the `aleph-node-runner` folder, run:

```bash
./run_validator.sh -n <your_nodes_name>
```

It might take quite some time before you actually get the node running: the script will first download required files, including a database snapshot (sized ~100GB). It will then run the node for you and you should start seeing some block-related output.

💡 The choice of `your_nodes_name` is entirely up to you but for the sake of more comprehensible logs please try using something unique and memorable.
