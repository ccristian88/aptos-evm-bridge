module bridge::token_bridge {
    use std::error;
    use std::vector;
    use std::signer::{address_of};
    use std::string;

    use aptos_std::table::{Self, Table};
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::from_bcs::to_address;

    use aptos_token::token::{Self, Token, TokenStore, Collections, TokenId, WithdrawCapability};
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;

    use layerzero_common::serde;
    use layerzero_common::utils::{vector_slice, assert_u16, assert_signer, assert_length};
    use layerzero::endpoint::{Self, UaCapability};
    use layerzero::lzapp;
    use layerzero::remote;
    use zro::zro::ZRO;

    const EBRIDGE_UNREGISTERED_COLLECTION: u64 = 0x00;
    const EBRIDGE_REMOTE_TOKEN_NOT_FOUND: u64 = 0x01;
    const EBRIDGE_INVALID_TOKEN_TYPE: u64 = 0x02;
    const EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND: u64 = 0x03;
    const EBRIDGE_TOKEN_NOT_UNWRAPPABLE: u64 = 0x04;
    const EBRIDGE_INSUFFICIENT_LIQUIDITY: u64 = 0x05;
    const EBRIDGE_INVALID_ADDRESS: u64 = 0x06;
    const EBRIDGE_INVALID_SIGNER: u64 = 0x07;
    const EBRIDGE_INVALID_PACKET_TYPE: u64 = 0x08;
    const EBRIDGE_PAUSED: u64 = 0x09;
    const EBRIDGE_SENDING_AMOUNT_TOO_FEW: u64 = 0x0a;
    const EBRIDGE_INVALID_ADAPTER_PARAMS: u64 = 0x0b;
    const EBRIDGE_COLLECTION_ALREADY_EXISTS: u64 = 0x0c;

    // paceket type, in line with EVM
    const PRECEIVE: u8 = 0;
    const PSEND: u8 = 1;

    const SEND_PAYLOAD_SIZE: u64 = 74;

    // layerzero user application generic type for this app
    struct BridgeUA {}

    struct Path has copy, drop {
        remote_chain_id: u64,
        remote_token_addr: vector<u8>,
    }

    struct LzCapability has key {
        cap: UaCapability<BridgeUA>
    }

    struct Config has key {
        paused_global: bool,
        custom_adapter_params: bool,
        registered_collection: address,
    }

    struct RemoteToken has store, drop {
        remote_address: vector<u8>,
        // in shared decimals
        tvl_sd: u64,
        // whether the token can be unwrapped into native token on remote chain, like WETH -> ETH on ethereum, WBNB -> BNB on BSC
        unwrappable: bool,
    }

    struct EventStore has key {
        send_events: EventHandle<SendEvent>,
        receive_events: EventHandle<ReceiveEvent>,
        claim_events: EventHandle<ClaimEvent>,
    }

    struct SendEvent has drop, store {
        collection: string::String,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        token: string::String,
    }

    struct ReceiveEvent has drop, store {
        token_type: TypeInfo,
        src_chain_id: u64,
        receiver: address,
        amount_ld: u64,
        stashed: bool,
    }

    struct ClaimEvent has drop, store {
        token_type: TypeInfo,
        receiver: address,
        amount_ld: u64,
    }

    fun init_module(account: &signer) {
        let cap = endpoint::register_ua<BridgeUA>(account);
        lzapp::init(account, cap);
        remote::init(account);

        move_to(account, LzCapability { cap });

        move_to(account, Config {
            paused_global: false,
            custom_adapter_params: false,
            registered_collection: collection
        });

        move_to(account, EventStore {
            send_events: account::new_event_handle<SendEvent>(account),
            receive_events: account::new_event_handle<ReceiveEvent>(account),
            claim_events: account::new_event_handle<ClaimEvent>(account),
        });
        let collection_name = string::utf8(b"ONFT");
        let description = string::utf8(b"Description");
        let collection_uri = string::utf8(b"Collection uri");

        // create the nft collection
        let maximum_supply = 1000;
        let mutate_setting = vector<bool>[ false, false, false ];
        token::create_collection(account, collection_name, description, collection_uri, maximum_supply, mutate_setting);


    }

    public entry fun set_global_pause(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.paused_global = paused;
    }


    public entry fun enable_custom_adapter_params(account: &signer, enabled: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.custom_adapter_params = enabled;
    }

    //
    // token transfer functions
    //
    public fun send_token(
        account: &signer,
        token_id: TokenId,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        fee: Coin<AptosCoin>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): Coin<AptosCoin> acquires EventStore, Config, LzCapability {
        let (native_refund, zro_refund) = send_token_with_zro(account, token_id, dst_chain_id, dst_receiver, fee, coin::zero<ZRO>(), adapter_params, msglib_params);
        coin::destroy_zero(zro_refund);
        native_refund
    }

    public fun send_token_with_zro(
        account: &signer,
        token_id: TokenId,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires EventStore, Config, LzCapability {

        let (native_refund, zro_refund) = send_token_internal(account, token_id, dst_chain_id, dst_receiver, native_fee, zro_fee, adapter_params, msglib_params);

        (native_refund, zro_refund)
    }

    fun send_token_internal(
        account: &signer,
        token_id: TokenId,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires EventStore, Config, LzCapability {
        assert_registered_collection();
        assert_unpaused();
        assert_u16(dst_chain_id);
        assert_length(&dst_receiver, 32);

        // burn the token
        token::burn(account, @bridge, token_id.token_data_id.collection, token_id.token_data_id.name, 0, 1);

        // check gas limit with adapter params
        check_adapter_params(dst_chain_id, &adapter_params);

        let payload = encode_send_payload(dst_receiver, token_id.token_data_id.name);

        // send lz msg to remote bridge
        let lz_cap = borrow_global<LzCapability>(@bridge);
        let dst_address = remote::get(@bridge, dst_chain_id);
        let (_, native_refund, zro_refund) = lzapp::send_with_zro<BridgeUA>(
            dst_chain_id,
            dst_address,
            payload,
            native_fee,
            zro_fee,
            adapter_params,
            msglib_params,
            &lz_cap.cap
        );

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event<SendEvent>(
            &mut event_store.send_events,
            SendEvent {
                collection: token_id.token_data_id.collection,
                dst_chain_id,
                dst_receiver,
                token: token_id.token_data_id.name,
            },
        );

        (native_refund, zro_refund)
    }

    public entry fun lz_receive(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires EventStore, Config, LzCapability {
        assert_registered_collection();
        assert_unpaused();
        assert_u16(src_chain_id);

        // assert the payload is valid
        remote::assert_remote(@bridge, src_chain_id, src_address);
        let lz_cap = borrow_global<LzCapability>(@bridge);
        endpoint::lz_receive<BridgeUA>(src_chain_id, src_address, payload, &lz_cap.cap);

        // decode payload and get token amount
        let (token_name, receiver_bytes, token_uri) = decode_receive_payload(&payload);

        // stash if the receiver has not yet registered to receive the token
        let receiver = to_address(receiver_bytes);

        let stashed = exists<TokenStore>(receiver);
        if (stashed) {
            //Make Claiming
            let claimable_ld = table::borrow_mut_with_default(&mut token_store.claimable_amt_ld, receiver, 0);
            *claimable_ld = *claimable_ld + amount_ld;
        } else {
            //Mint TOKEN
        };

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.receive_events,
            ReceiveEvent {
                src_chain_id,
                receiver,
                token_name,
                stashed,
            }
        );
    }

    public entry fun claim_token(receiver: &signer) acquires CollectionStore, EventStore, Config {
        assert_registered_collection();
        assert_unpaused();

        // register the user if needed
        let receiver_addr = address_of(receiver);
        if (!token::is_account_registered(receiver_addr)) {
            token::register(receiver);
        };

        // assert the receiver has receivable and it is more than 0
        let token_store = borrow_global_mut<CollectionStore<TokenType>>(@bridge);
        assert!(table::contains(&token_store.claimable_amt_ld, receiver_addr), error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));
        let claimable_ld = table::remove(&mut token_store.claimable_amt_ld, receiver_addr);
        assert!(claimable_ld > 0, error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));

        let tokens_minted = token::mint(claimable_ld, &token_store.mint_cap);
        token::deposit(receiver_addr, tokens_minted);

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.claim_events,
            ClaimEvent {
                token_type: type_info::type_of<TokenType>(),
                receiver: receiver_addr,
                amount_ld: claimable_ld,
            }
        );
    }

    //
    // public view functions
    //
    public fun lz_receive_types(src_chain_id: u64, _src_address: vector<u8>, payload: vector<u8>): vector<TypeInfo> acquires TokenTypeStore {
        let (remote_token_addr, _receiver, _amount) = decode_receive_payload(&payload);
        let path = Path { remote_chain_id: src_chain_id, remote_token_addr };

        let type_store = borrow_global<TokenTypeStore>(@bridge);
        let token_type_info = table::borrow(&type_store.type_lookup, path);

        vector::singleton<TypeInfo>(*token_type_info)
    }

    public fun has_collection_registered(): bool {
        exists<CollectionStore>(@bridge)
    }

    public fun quote_fee(dst_chain_id: u64, pay_in_zro: bool, adapter_params: vector<u8>, msglib_params: vector<u8>): (u64, u64) {
        endpoint::quote_fee(@bridge, dst_chain_id, SEND_PAYLOAD_SIZE, pay_in_zro, adapter_params, msglib_params)
    }

    public fun remove_dust_ld(amount_ld: u64): u64 acquires CollectionStore {
        let token_store = borrow_global<CollectionStore<TokenType>>(@bridge);
        amount_ld / token_store.ld2sd_rate * token_store.ld2sd_rate
    }

    // encode payload: packet type(1) + remote token(32) + receiver(32) + amount(8) + unwarp flag(1)
    fun encode_send_payload(dst_token_addr: vector<u8>, dst_receiver: vector<u8>, amount_sd: u64): vector<u8> {
        assert_length(&dst_token_addr, 32);
        assert_length(&dst_receiver, 32);

        let payload = vector::empty<u8>();
        serde::serialize_u8(&mut payload, PSEND);
        serde::serialize_vector(&mut payload, dst_token_addr);
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u64(&mut payload, amount_sd);
        let unwrap = if (unwrap) { 1 } else { 0 };
        serde::serialize_u8(&mut payload, unwrap);
        payload
    }

    // decode payload: packet type(1) + remote token(32) + receiver(32) + amount(8)
    fun decode_receive_payload(payload: &vector<u8>): (vector<u8>, vector<u8>, u64) {
        assert_length(payload, 73);

        let packet_type = serde::deserialize_u8(&vector_slice(payload, 0, 1));
        assert!(packet_type == PRECEIVE, error::aborted(EBRIDGE_INVALID_PACKET_TYPE));

        let remote_token_addr = vector_slice(payload, 1, 33);
        let receiver_bytes = vector_slice(payload, 33, 65);
        let amount_sd = serde::deserialize_u64(&vector_slice(payload, 65, 73));
        (remote_token_addr, receiver_bytes, amount_sd)
    }

    fun check_adapter_params(dst_chain_id: u64, adapter_params: &vector<u8>) acquires Config {
        let config = borrow_global<Config>(@bridge);
        if (config.custom_adapter_params) {
            lzapp::assert_gas_limit(@bridge, dst_chain_id,  (PSEND as u64), adapter_params, 0);
        } else {
            assert!(vector::is_empty(adapter_params), error::invalid_argument(EBRIDGE_INVALID_ADAPTER_PARAMS));
        }
    }

    fun assert_registered_collection() acquires Config {
        assert!(
            exists<Collections>(@bridge),
            error::not_found(EBRIDGE_UNREGISTERED_COLLECTION),
        );
    }

    fun assert_unpaused() acquires Config {
        let config = borrow_global<Config>(@bridge);
        assert!(!config.paused_global, error::unavailable(EBRIDGE_PAUSED));
    }
}