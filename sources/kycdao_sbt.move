

module kycdao_sbt_obj::kycdao_sbt {

    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option;
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::resource_account;
    use aptos_std::ed25519;
    use aptos_std::string_utils;
    use aptos_std::math64::pow;
    use aptos_framework::object::{Self};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use pyth::pyth;
    use pyth::price_identifier;
    use pyth::i64;
    use pyth::price;

    #[test_only]
    use aptos_framework::account::create_account_for_test;
    use aptos_std::ed25519::ValidatedPublicKey;

    // This struct stores the token receiver's address in the event of token minting
    struct TokenMintingEvent has drop, store {
        token_receiver_address: address,
        token_address: address,
    }

    // This struct stores the collection's relevant information
    struct ModuleData has key {
        public_key: ed25519::ValidatedPublicKey,
        signer_cap: account::SignerCapability,
        token_minting_events: EventHandle<TokenMintingEvent>,
        token_uri_base: vector<u8>,
        subscription_cost_per_year: u64,
        price_feed_identifier: vector<u8>,
    }

    // This struct stores the challenge message that proves that the resource signer wants to mint this token
    // to the receiver. This struct will need to be signed by the resource signer to pass the verification.
    struct MintProofChallenge has drop {
        receiver_account_sequence_number: u64,
        receiver_account_address: address,
        metadata_cid: String, 
        expiry: u64, 
        seconds_to_pay: u64, 
        verification_tier: String        
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// The ambassador token
    struct KycDAOToken has key {
        /// Used to mutate the token uri
        mutator_ref: token::MutatorRef,
        /// Whether the token is considered verified
        verified: bool,
        /// The expiry date of the token in seconds since the epoch
        expiry: u64,
        /// The KYC tier of the token
        verification_tier: String,
    }

    /// Action not authorized because the signer is not the admin of this module
    const ENOT_AUTHORIZED: u64 = 1;
    /// Specified proof of knowledge required to prove ownership of a public key is invalid
    const EINVALID_PROOF_OF_KNOWLEDGE: u64 = 2;
    /// Specified address does not have a valid token
    const EINVALID_TOKEN: u64 = 3;

    /// The ambassador token collection name
    const COLLECTION_NAME: vector<u8> = b"kycDAO SBT Collection";
    /// The ambassador token collection description
    const COLLECTION_DESCRIPTION: vector<u8> = b"A collection of kycDAO SBTs for on-chain KYC";
    /// The ambassador token collection URI
    const COLLECTION_URI: vector<u8> = b"https://kycdao.xyz";
    /// The base of the token name, to which the receiver's address will be appended
    const TOKEN_NAME_BASE: vector<u8> = b"kycDAO SBT owner: ";
    /// The token description
    const TOKEN_DESCRIPTION: vector<u8> = b"A kycDAO SBT";
    /// The base of the token URI, to which the token metadata CID will be appended
    const TOKEN_URI_BASE: vector<u8> = b"https://ipfs.io/ipfs/";
    /// The factor by which the subscription cost is multiplied to get the actual cost
    const SUBSCRIPTION_COST_FACTOR: u64 = 100000000;
    /// The number of seconds in a year
    const SECS_IN_YEAR: u64 = 365 * 24 * 60 * 60;
    /// The initial subscription cost in USD, can be updated with `set_subscription_cost`
    const INITIAL_SUBSCRIPTION_COST: u64 = 5 * 100000; // 0.005 USD (testnet) 

    /// The initial public key used by the signer for minting (testnet), can be updated with `set_public_key`
    const MINT_PUBLIC_KEY: vector<u8> = x"7D5A3BAB5C4BB2E00BA1C51DD0C2A14C54231684025A1C72FCB144BE59B4C996";

    /// The Pyth network price identifier for APT/USD (testnet), can be updated with `set_price_feed_identifier`
    const PRICE_FEED_IDENTIFIER: vector<u8> = x"44a93dddd8effa54ea51076c4e851b6cbbfd938e82eb90197de38fe8876bb66e";

    /// Octas per aptos coin
    const OCTAS_PER_APTOS: u64 = 100000000;

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
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(resource_signer, @kycdao_deployer);

        // setting the admin public key here but can be updated with `set_public_key`
        let pk_bytes = MINT_PUBLIC_KEY;
        let public_key = std::option::extract(&mut ed25519::new_validated_public_key_from_bytes(pk_bytes));
        move_to(resource_signer, ModuleData {
            public_key,
            signer_cap: resource_signer_cap,
            token_minting_events: account::new_event_handle<TokenMintingEvent>(resource_signer),
            token_uri_base: TOKEN_URI_BASE,
            subscription_cost_per_year: INITIAL_SUBSCRIPTION_COST,
            price_feed_identifier: PRICE_FEED_IDENTIFIER,
        });
    }

    fun add_address_to_string(str: vector<u8>, addr: &address): String {
        let addr_string = string_utils::to_string<address>(addr);
        vector::append(&mut str, *string::bytes(&addr_string));
        string::utf8(str)
    }

    /// Mint an NFT to the receiver.
    /// `mint_proof_signature` should be the `MintProofChallenge` signed by the admin's private key
    /// `public_key_bytes` should be the public key of the admin
    public entry fun mint_with_signature(receiver: &signer, metadata_cid: String, expiry: u64, seconds_to_pay: u64, verification_tier: String, mint_proof_signature: vector<u8>) acquires ModuleData {
        let receiver_addr = signer::address_of(receiver);

        if (seconds_to_pay > 0) {
            // calculate the mint cost in APT
            let mint_cost = get_required_mint_cost_for_seconds(seconds_to_pay);
            // transfer the mint cost from the receiver to the admin
            coin::transfer<AptosCoin>(receiver, @kycdao_admin, mint_cost);
        };

        // get the collection minter
        let module_data = borrow_global_mut<ModuleData>(@kycdao_sbt_obj);

        // verify that the `mint_proof_signature` is valid against the admin's public key
        verify_proof_of_knowledge(receiver_addr, metadata_cid, expiry, seconds_to_pay, verification_tier, mint_proof_signature, module_data.public_key);

        // mint token to the receiver
        let resource_signer = account::create_signer_with_capability(&module_data.signer_cap);
        let collection_name = string::utf8(COLLECTION_NAME);
        // As the seed used to generate the token address is based on the token name, we add the receiver's address
        // to the token name to make it unique and deterministic
        let token_name = add_address_to_string(TOKEN_NAME_BASE, &receiver_addr);
        let token_uri = module_data.token_uri_base;
        vector::append(&mut token_uri, *string::bytes(&metadata_cid));
        let token_description = string::utf8(TOKEN_DESCRIPTION);

        let constructor_ref = token::create_named_token(
            &resource_signer,
            collection_name,
            token_description,
            token_name,
            option::none(),
            string::utf8(token_uri),
        );

        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&constructor_ref);

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

        let kycdao_token = KycDAOToken {
            mutator_ref,
            verified: true,
            expiry: expiry,
            verification_tier: verification_tier,
        };
        move_to(&object_signer, kycdao_token);
    }

    /// Verify that the collection token minter intends to mint the given token_data_id to the receiver
    fun verify_proof_of_knowledge(receiver_addr: address, metadata_cid: String, expiry: u64, seconds_to_pay: u64, verification_tier: String, mint_proof_signature: vector<u8>, public_key: ValidatedPublicKey) {
        let sequence_number = account::get_sequence_number(receiver_addr);

        let proof_challenge = MintProofChallenge {
            receiver_account_sequence_number: sequence_number,
            receiver_account_address: receiver_addr,
            metadata_cid: metadata_cid, 
            expiry: expiry, 
            seconds_to_pay: seconds_to_pay, 
            verification_tier: verification_tier             
        };

        let signature = ed25519::new_signature_from_bytes(mint_proof_signature);
        let unvalidated_public_key = ed25519::public_key_to_unvalidated(&public_key);
        assert!(ed25519::signature_verify_strict_t(&signature, &unvalidated_public_key, proof_challenge), error::invalid_argument(EINVALID_PROOF_OF_KNOWLEDGE));
    }

    // Admin set functions

    /// Set the public key of this minting contract
    public entry fun set_public_key(caller: &signer, pk_bytes: vector<u8>) acquires ModuleData {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @kycdao_admin, error::permission_denied(ENOT_AUTHORIZED));
        let module_data = borrow_global_mut<ModuleData>(@kycdao_sbt_obj);
        module_data.public_key = std::option::extract(&mut ed25519::new_validated_public_key_from_bytes(pk_bytes));
    }

    public entry fun set_price_feed_identifier(caller: &signer, price_feed_id: vector<u8>) acquires ModuleData {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @kycdao_admin, error::permission_denied(ENOT_AUTHORIZED));
        let module_data = borrow_global_mut<ModuleData>(@kycdao_sbt_obj);
        module_data.price_feed_identifier = price_feed_id;
    }

    public entry fun set_subscription_cost(caller: &signer, new_subscription_cost: u64) acquires ModuleData {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @kycdao_admin, error::permission_denied(ENOT_AUTHORIZED));
        let module_data = borrow_global_mut<ModuleData>(@kycdao_sbt_obj);
        module_data.subscription_cost_per_year = new_subscription_cost;
    }

    public entry fun set_token_verified(caller: &signer, token_addr: address, new_verified: bool) acquires KycDAOToken {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @kycdao_admin, error::permission_denied(ENOT_AUTHORIZED));
        let token = borrow_global_mut<KycDAOToken>(token_addr);
        token.verified = new_verified;
    }

    public entry fun set_token_expiry(caller: &signer, token_addr: address, new_expiry: u64) acquires KycDAOToken {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @kycdao_admin, error::permission_denied(ENOT_AUTHORIZED));
        let token = borrow_global_mut<KycDAOToken>(token_addr);
        token.expiry = new_expiry;
    }

    // View functions

    #[view]
    /// Get the token address from the receiver's address, fails if the token does not exist
    public fun get_token_addr_from_acct(addr: address): address {
        let collection_name = string::utf8(COLLECTION_NAME);
        let token_name = add_address_to_string(TOKEN_NAME_BASE, &addr);
        let token_addr = token::create_token_address(&@kycdao_sbt_obj, &collection_name, &token_name);
        assert!(object::is_object(token_addr), error::invalid_argument(EINVALID_TOKEN));
        token_addr
    }

    #[view]
    public fun tier_from_token_addr(token_addr: address): String acquires KycDAOToken {
        let token = borrow_global<KycDAOToken>(token_addr);
        token.verification_tier
    }
    
    #[view]
    public fun expiry_from_token_addr(token_addr: address): u64 acquires KycDAOToken {
        let token = borrow_global<KycDAOToken>(token_addr);
        token.expiry
    }

    #[view]
    public fun has_valid_token(addr: address): bool acquires KycDAOToken {
        let collection_name = string::utf8(COLLECTION_NAME);
        let token_name = add_address_to_string(TOKEN_NAME_BASE, &addr);
        let token_addr = token::create_token_address(&@kycdao_sbt_obj, &collection_name, &token_name);
        if (!object::is_object(token_addr)) return false;
        let token = borrow_global<KycDAOToken>(token_addr);
        token.verified && timestamp::now_seconds() < token.expiry
    }

    #[view]
    public fun get_required_mint_cost_for_seconds(seconds: u64): u64 acquires ModuleData {
        let module_data = borrow_global<ModuleData>(@kycdao_sbt_obj);
        let cost_usd = (seconds * module_data.subscription_cost_per_year) / SECS_IN_YEAR;
        (cost_usd * get_apt_usd_price(module_data.price_feed_identifier)) / SUBSCRIPTION_COST_FACTOR
    }

    /// Uses the Pyth Network to return the APT/USD price.
    fun get_apt_usd_price(price_feed_id: vector<u8>): u64 {
        // Now we can use the prices which we have just updated
        let apt_usd_price_id = price_identifier::from_byte_vec(price_feed_id);
        let price = pyth::get_price_unsafe(apt_usd_price_id);
        let price_positive = i64::get_magnitude_if_positive(&price::get_price(&price)); // This will fail if the price is negative
        let expo_magnitude = i64::get_magnitude_if_negative(&price::get_expo(&price)); // This will fail if the exponent is positive

        let price_in_aptos_coin =  (OCTAS_PER_APTOS * pow(10, expo_magnitude)) / price_positive; // 1 USD in APT
        price_in_aptos_coin
    }

    //
    // Tests
    //

    #[test_only]
    public fun set_up_test(
        origin_account: &signer,
        resource_account: &signer,
        collection_token_minter_public_key: &ValidatedPublicKey,
        nft_receiver: &signer,
        aptos_framework: &signer,
    ) acquires ModuleData {
        // set up global time for testing purpose
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(10);

        create_account_for_test(signer::address_of(origin_account));

        // create a resource account from the origin account, mocking the module publishing process
        resource_account::create_resource_account(origin_account, vector::empty<u8>(), vector::empty<u8>());

        init_module(resource_account);

        let admin = create_account_for_test(@kycdao_admin);
        let pk_bytes = ed25519::validated_public_key_to_bytes(collection_token_minter_public_key);
        set_public_key(&admin, pk_bytes);

        create_account_for_test(signer::address_of(nft_receiver));
    }

    #[test (aptos_framework = @aptos_framework, origin_account = @0xcafe, resource_account = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, nft_receiver = @0x123)]
    public entry fun test_mint_happy_path(aptos_framework: signer, origin_account: signer, resource_account: signer, nft_receiver: signer) acquires ModuleData, KycDAOToken {
        let (admin_sk, admin_pk) = ed25519::generate_keys();
        set_up_test(&origin_account, &resource_account, &admin_pk, &nft_receiver, &aptos_framework);
        let receiver_addr = signer::address_of(&nft_receiver);
        let proof_challenge = MintProofChallenge {
            receiver_account_sequence_number: account::get_sequence_number(receiver_addr),
            receiver_account_address: receiver_addr,
            metadata_cid: string::utf8(b"1234"), 
            expiry: 100000000000, 
            seconds_to_pay: 0, 
            verification_tier: string::utf8(b"KYC_1")             
        };

        let sig = ed25519::sign_struct(&admin_sk, proof_challenge);

        // mint sbt to this receiver
        mint_with_signature(
            &nft_receiver, 
            string::utf8(b"1234"), 
            100000000000, 
            0, 
            string::utf8(b"KYC_1"), 
            ed25519::signature_to_bytes(&sig)
        );

        // check that the token was minted
        let token_addr = get_token_addr_from_acct(receiver_addr);
        assert!(object::is_object(token_addr), 1);

        // check has_valid_token
        assert!(has_valid_token(receiver_addr), 2);

    }

    #[test (aptos_framework = @aptos_framework, origin_account = @0xcafe, resource_account = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, nft_receiver = @0x123)]
    #[expected_failure(abort_code = 0x10002, location = kycdao_sbt_obj::kycdao_sbt)]
    public entry fun test_invalid_proof_struct(aptos_framework: signer, origin_account: signer, resource_account: signer, nft_receiver: signer) acquires ModuleData {
        let (admin_sk, admin_pk) = ed25519::generate_keys();
        set_up_test(&origin_account, &resource_account, &admin_pk, &nft_receiver, &aptos_framework);
        let receiver_addr = signer::address_of(&nft_receiver);
        let proof_challenge = MintProofChallenge {
            receiver_account_sequence_number: account::get_sequence_number(receiver_addr),
            receiver_account_address: receiver_addr,
            metadata_cid: string::utf8(b"1234"), 
            expiry: 100000000000, 
            seconds_to_pay: 0, 
            verification_tier: string::utf8(b"KYC_1")             
        };

        let sig = ed25519::sign_struct(&admin_sk, proof_challenge);

        // change seconds_to_pay and expect failure
        mint_with_signature(
            &nft_receiver, 
            string::utf8(b"1111"), 
            100000000000, 
            0, 
            string::utf8(b"KYC_1"), 
            ed25519::signature_to_bytes(&sig)
        );
    }

    #[test (aptos_framework = @aptos_framework, origin_account = @0xcafe, resource_account = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, nft_receiver = @0x123)]
    #[expected_failure(abort_code = 0x10002, location = kycdao_sbt_obj::kycdao_sbt)]
    public entry fun test_invalid_signature(aptos_framework: signer, origin_account: signer, resource_account: signer, nft_receiver: signer) acquires ModuleData {
        let (admin_sk, admin_pk) = ed25519::generate_keys();
        set_up_test(&origin_account, &resource_account, &admin_pk, &nft_receiver, &aptos_framework);
        let receiver_addr = signer::address_of(&nft_receiver);
        let proof_challenge = MintProofChallenge {
            receiver_account_sequence_number: account::get_sequence_number(receiver_addr),
            receiver_account_address: receiver_addr,
            metadata_cid: string::utf8(b"1234"), 
            expiry: 100000000000, 
            seconds_to_pay: 0, 
            verification_tier: string::utf8(b"KYC_1")             
        };

        let sig = ed25519::sign_struct(&admin_sk, proof_challenge);
        let sig_bytes = ed25519::signature_to_bytes(&sig);

        // Pollute signature.
        let first_sig_byte = vector::borrow_mut(&mut sig_bytes, 0);
        *first_sig_byte = *first_sig_byte + 1;

        mint_with_signature(
            &nft_receiver, 
            string::utf8(b"1234"), 
            100000000000, 
            0, 
            string::utf8(b"KYC_1"), 
            sig_bytes
        );
    }

    #[test (aptos_framework = @aptos_framework, admin = @kycdao_admin, origin_account = @0xcafe, resource_account = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, nft_receiver = @0x123)]
    public entry fun test_set_subscription_cost(aptos_framework: signer, admin: signer, origin_account: signer, resource_account: signer, nft_receiver: signer) acquires ModuleData {
        let (_admin_sk, admin_pk) = ed25519::generate_keys();
        set_up_test(&origin_account, &resource_account, &admin_pk, &nft_receiver, &aptos_framework);
        set_subscription_cost(&admin, 0);
    }

    #[test (aptos_framework = @aptos_framework, origin_account = @0xcafe, resource_account = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, nft_receiver = @0x123)]
    #[expected_failure(abort_code = 0x50001, location = kycdao_sbt_obj::kycdao_sbt)]
    public entry fun test_set_subscription_cost_not_admin(aptos_framework: signer, origin_account: signer, resource_account: signer, nft_receiver: signer) acquires ModuleData {
        let (_admin_sk, admin_pk) = ed25519::generate_keys();
        set_up_test(&origin_account, &resource_account, &admin_pk, &nft_receiver, &aptos_framework);
        set_subscription_cost(&origin_account, 0);
    }
}