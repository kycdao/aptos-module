# aptos-module
The Aptos implementation for kycDAO Soulbound tokens (SBTs)

## Install
Install the [Aptos CLI](https://aptos.dev/tools/aptos-cli/install-cli/)

The rest of the dependencies will be installed when compiling using the Aptos CLI.
## Config
You'll need to generate a bunch of accounts which will be used by the Aptos module. Note that the price feed Pyth is only deployed on `Testnet` so you'll need to use that network (instead of `Devnet`).

To generate each account run:

```bash
aptos init --profile <PROFILE_NAME> --network testnet
```

You should generate the following accounts:
- `default`
- `admin`
- `nft-receiver`

All accounts are stored in `.aptos/config.yaml`

Update the `admin-addr` in `Move.toml` with the newly generated admin address.

## Compiling
Compile with: `aptos move compile`. This will install all required dependencies as listed in `Move.toml` and compile the module.

## Deploying
Each deployment uses a different seed and will deploy the package to a different address, which we're naming `kycdao_sbt_obj`.

```bash
aptos move create-resource-account-and-publish-package --seed 1234 --address-name kycdao_sbt_obj --profile default --named-addresses source_addr=<DEFAULT_ADDR>
```

Find the created resource address and use it to enter the `kycdao_sbt_obj` account in `.aptos/config.yaml`.

i.e.:
```yaml
  kycdao_sbt_obj:
    account: <RESOURCE_ADDR>
```

## Running
To mint an kycDAO SBT, for this module, you can either create a valid signature or comment out the relevant line from the module (and redeploy).

### Skip signature
Comment out the line in `mint_with_signature()` which calls `verify_proof_of_knowledge()`.

### Generate valid signature
The instructions in [example/create_nft_getting_production_ready.move]() can be used to generate a valid signature (see line 64)

However, as the struct for `MintProofChallenge` has changed, you'll need to update the code in `mint_nft.rs` to use the new struct when generating the signature.

### Actually minting
To mint an SBT, you'll need to call the `mint_with_signature()` function with the following parameters:
```bash
aptos move run --function-id kycdao_sbt_obj::kycdao_sbt::mint_with_signature --args <METADATA_CID> <EXPIRY> <SECONDS_TO_PAY> <TIER> <SIGNATURE> --profile nft-receiver
```

e.g.

```bash
aptos move run --function-id kycdao_sbt_obj::kycdao_sbt::mint_with_signature --args string:QmRuPuDNFRhvm5RsbCyM5x5ZR2hsVNt533n9tv5nppRmHw u64:1721537916 u64:32000000 string:KYC_1  hex:3e37ab7f72633a856327e5f206519b957bb1e4fa4fec39f69d2f29e2d36ca3c57589c35e2656cb6901d5e902430fcc3122b5a864c811993cc42fe78fc5882f0d --profile nft-receiver
```

## Testing

We should... add some tests


