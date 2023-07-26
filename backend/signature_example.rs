// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use crate::{assert_success, tests::common, MoveHarness};
use aptos_crypto::{
    ed25519::{Ed25519PrivateKey, Ed25519Signature},
    SigningKey, ValidCryptoMaterialStringExt,
};
use aptos_types::{
    account_address::{create_resource_address, AccountAddress},
    event::EventHandle,
    state_store::{state_key::StateKey, table::TableHandle},
};
use move_core_types::parser::parse_struct_tag;
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
struct TokenDataId {
    creator: AccountAddress,
    collection: Vec<u8>,
    name: Vec<u8>,
}

#[derive(Deserialize, Serialize)]
struct TokenId {
    token_data_id: TokenDataId,
    property_version: u64,
}

#[derive(Deserialize, Serialize)]
struct MintProofChallenge {
    account_address: AccountAddress,
    module_name: String,
    struct_name: String,
    receiver_account_sequence_number: u64,
    receiver_account_address: AccountAddress,
    token_data_id: TokenDataId,
}

#[derive(Deserialize, Serialize)]
struct TokenStore {
    tokens: TableHandle,
    direct_transfer: bool,
    deposit_events: EventHandle,
    withdraw_events: EventHandle,
    burn_events: EventHandle,
    mutate_token_property_events: EventHandle,
}

/// Run `cargo test generate_nft_tutorial_part4_signature -- --nocapture`
/// to generate a valid signature for `[resource_account_address]::create_nft_getting_production_ready::mint_event_pass()` function
/// in `aptos-move/move-examples/mint_nft/4-Getting-Production-Ready/sources/create_nft_getting_production_ready.move`. åååååååå
#[test]
fn generate_nft_tutorial_part4_signature() {
    let mut h = MoveHarness::new();

    // When running this test to generate a valid signature, supply the actual resource_address to line 217.
    // Uncomment line 223 and comment out line 224 (it's just a placeholder).
    let resource_address = h.new_account_at(AccountAddress::from_hex_literal("0xa59fb4dbd377a7964283e911791e5b6f291236281d82e1ccfe24d331c5b64ef1").unwrap());
    // let resource_address = h.new_account_at(AccountAddress::from_hex_literal("0xcafe").unwrap());

    // When running this test to generate a valid signature, supply the actual nft_receiver's address to line 222.
    // Uncomment line 228 and comment out line 229.
    let nft_receiver = h.new_account_at(AccountAddress::from_hex_literal("0xf8fa7e90680fef5402bf1820d1dac7cd4d18824a989375980bb1f9d7c9d373bc").unwrap());
    // let nft_receiver = h.new_account_at(AccountAddress::from_hex_literal("0xcafe").unwrap());

    // When running this test to generate a valid signature, supply the actual private key to replace the (0000...) in line 232.
    let admin_private_key = Ed25519PrivateKey::from_encoded_string(
        "B2F97F8D52EBB7E404B7F117D2C339B9D1430993274F7750844C35AE8173BE14",
    )
    .unwrap();

    // construct the token_data_id and mint_proof, which are required to mint the nft
    let token_data_id = TokenDataId {
        creator: *resource_address.address(),
        collection: String::from("Collection name").into_bytes(),
        name: String::from("Token name").into_bytes(),
    };

    let mint_proof = MintProofChallenge {
        account_address: *resource_address.address(),
        module_name: String::from("create_nft_getting_production_ready"),
        struct_name: String::from("MintProofChallenge"),
        // change the `receiver_account_sequence_number` to the right sequence number
        // you can find an account's sequence number by searching for the account's address on explorer.aptoslabs.com and going to the `Info` tab
        receiver_account_sequence_number: 2,
        receiver_account_address: *nft_receiver.address(),
        token_data_id,
    };

    // sign the MintProofChallenge using the resource account's private key
    let mint_proof_msg = bcs::to_bytes(&mint_proof);

    let mint_proof_signature = admin_private_key.sign_arbitrary_message(&mint_proof_msg.unwrap());
    println!(
        "Mint Proof Signature for NFT receiver: {:?}",
        mint_proof_signature
    );
}
