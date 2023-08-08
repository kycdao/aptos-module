

module kycdao_example::verified_sbt {

    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option;
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::resource_account;
    use aptos_std::string_utils;
    use aptos_framework::object::{Self};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use kycdao_sbt_obj::kycdao_sbt;

    // This struct stores the token receiver's address in the event of token minting
    struct TokenMintingEvent has drop, store {
        token_receiver_address: address,
        token_address: address,
    }

    // This struct stores the collection's relevant information
    struct ModuleData has key {
        signer_cap: account::SignerCapability,
        token_minting_events: EventHandle<TokenMintingEvent>,
    }

    /// Receiver is not verified
    const ENOT_VERIFIED: u64 = 1;

    /// The ambassador token collection name
    const COLLECTION_NAME: vector<u8> = b"Verified SBT Collection";
    /// The ambassador token collection description
    const COLLECTION_DESCRIPTION: vector<u8> = b"A collection of SBTs for verified users";
    /// The ambassador token collection URI
    const COLLECTION_URI: vector<u8> = b"https://example.xyz";
    /// The base of the token name, to which the receiver's address will be appended
    const TOKEN_NAME_BASE: vector<u8> = b"Verified SBT owner: ";
    /// The token description
    const TOKEN_DESCRIPTION: vector<u8> = b"A verified SBT";
    /// The fixed token URI for this example
    const FIXED_TOKEN_URI: vector<u8> = b"https://ipfs.io/ipfs/";

    fun init_module(resource_signer: &signer) {        
        let collection_description = string::utf8(COLLECTION_DESCRIPTION);
        let collection_name = string::utf8(COLLECTION_NAME);
        let collection_uri = string::utf8(COLLECTION_URI);

        // Creates the collection with unlimited supply and without establishing any royalty configuration.
        collection::create_unlimited_collection(
            resource_signer,
            collection_description,
            collection_name,
            option::none(),
            collection_uri,
        );

        // store the token data id within the module, so we can refer to it later
        // when we're minting the NFT
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(resource_signer, @source_addr);

        move_to(resource_signer, ModuleData {
            signer_cap: resource_signer_cap,
            token_minting_events: account::new_event_handle<TokenMintingEvent>(resource_signer),
        });
    }

    fun add_address_to_string(str: vector<u8>, addr: &address): String {
        let addr_string = string_utils::to_string<address>(addr);
        vector::append(&mut str, *string::bytes(&addr_string));
        string::utf8(str)
    }

    /// Mint an SBT to the receiver if the receiver has a valid token, checked with kycDAO's has_valid_token function
    public entry fun mint_verified(receiver: &signer) acquires ModuleData {
        let receiver_addr = signer::address_of(receiver);

        // get the collection minter
        let module_data = borrow_global_mut<ModuleData>(@kycdao_example);

        // verify that the receiver has a valid token
        assert!(kycdao_sbt::has_valid_token(receiver_addr), error::invalid_argument(ENOT_VERIFIED));

        // mint token to the receiver
        let resource_signer = account::create_signer_with_capability(&module_data.signer_cap);
        let collection_name = string::utf8(COLLECTION_NAME);
        // As the seed used to generate the token address is based on the token name, we add the receiver's address
        // to the token name to make it unique and deterministic
        let token_name = add_address_to_string(TOKEN_NAME_BASE, &receiver_addr);
        let token_description = string::utf8(TOKEN_DESCRIPTION);

        let constructor_ref = token::create_named_token(
            &resource_signer,
            collection_name,
            token_description,
            token_name,
            option::none(),
            string::utf8(FIXED_TOKEN_URI),
        );

        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        // Transfers the token to the `reciver_addr` address
        let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, receiver_addr);

        // Disables ungated transfer, thus making the token soulbound and non-transferable
        object::disable_ungated_transfer(&transfer_ref);

        event::emit_event<TokenMintingEvent>(
            &mut module_data.token_minting_events,
            TokenMintingEvent {
                token_receiver_address: receiver_addr,
                token_address: signer::address_of(&object_signer),
            }
        );

    }

    //
    // Tests
    //

}