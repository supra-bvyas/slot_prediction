module my_address::slot_prediction{
    use std::signer;
    use std::error;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use std::debug::print;
    use std::timestamp;
    use supra_framework::coin;
    use supra_framework::supra_coin;
    use supra_framework::event;
    #[test_only]
    use supra_framework::account;
    use std::string::{Self,String};
    use supra_framework::supra_coin::SupraCoin;

    ///The slot id doesnot exist.
    const ERROR_SLOT_ID_NOT_PRESENT:u64=1;
    ///No prediction with particular slot and user address found.
    const ERROR_NO_PREDICTION_FOUND:u64=2;
    ///The account is not registered/able to accept the supra coin.
    const ERROR_NOT_INITIALISED_FOR_SUPRA:u64=3;
    ///The account balance is less than what is required.
    const ERROR_NOT_ENOUGH_BALANCE:u64=4;
    ///The account is not the owner.
    const ERROR_NOT_AUTH:u64=5;
    ///Prediction is already present in the slot.
    const ERROR_ALREADY_PRESENT_IN_SLOT:u64=6;
    ///The prediction time is not met.
    const ERROR_PREDICTION_TIME_IS_NOT_MET:u64=7;
    ///Final is not set by the owner.
    const ERROR_FINAL_PRICE_NOT_SET:u64=8;
    ///Contract is not initialised.
    const ERROR_CONTRACT_NOT_INITIALISED:u64=9;
    ///Start time should be greater than end time
    const ERROR_START_TIME_SHOULD_BE_GREATER_THAN_END_TIME:u64=10;
    ///Current time should be less than the slot's end time
    const ERROR_CANNOT_PREDICT_AFTER_INTERVAL:u64=11;

    struct GlobalVars has key,store{
        auth_cum_lock:address,
        slot_to_user_addresses:Table<u256,vector<address>>,
        user_to_prediction:Table<address,vector<PredictionInfo>>,
        slot_id_to_slot_details:Table<u256,SlotDetails>
    }

    struct SlotDetails has key,store,copy,drop{
        start_time:u64,
        end_time:u64,
        final_price:u64,

    }

    struct PredictionInfo has key,store,drop,copy {
        slot_id:u256,
        coins: u64,
        reference_price:u64,
        // up_from_predictedprice:bool,//up->true,down->false
    }

    fun transferring_coins(account:&signer,coins:u64,pool_address:address)  {
        //Checking the supra store
        assert!(coin::is_account_registered<supra_coin::SupraCoin>(pool_address),error::unavailable(ERROR_NOT_INITIALISED_FOR_SUPRA));
        //Checking balance
        let account_balance=coin::balance<supra_coin::SupraCoin>(signer::address_of(account));
        assert!(account_balance>=coins,error::unavailable(ERROR_NOT_ENOUGH_BALANCE));
        //Transferring token to the pool address
        coin::transfer<supra_coin::SupraCoin>(account, pool_address,coins);
    }

    public entry fun init(auth_cum_lock:&signer){
        move_to(auth_cum_lock,GlobalVars {
            auth_cum_lock:signer::address_of(auth_cum_lock),
            slot_to_user_addresses:table::new<u256,vector<address>>(),
            user_to_prediction:table::new<address,vector<PredictionInfo>>(),
            slot_id_to_slot_details:table::new<u256,SlotDetails>()
        });
    }

    public entry fun create_slot(account:&signer,slot_id:u256,start_time:u64,end_time:u64,)acquires GlobalVars{
        assert!(exists<GlobalVars>(@my_address),error::unavailable(ERROR_CONTRACT_NOT_INITIALISED));
        assert!(end_time > start_time,error::aborted(ERROR_START_TIME_SHOULD_BE_GREATER_THAN_END_TIME));
        let global_vars=borrow_global_mut<GlobalVars>(@my_address);
        assert!(global_vars.auth_cum_lock==signer::address_of(account),error::permission_denied(ERROR_NOT_AUTH));
        let slot_table=&mut global_vars.slot_id_to_slot_details;
        //Will automatically revert if the slot_id is already created
        table::add(slot_table,slot_id,SlotDetails{
            start_time,
            end_time,
            final_price:0,
        })
    }


    public entry fun create_prediction(account:&signer,slot_id:u256,coins:u64,reference_price:u64)acquires GlobalVars{
        assert!(exists<GlobalVars>(@my_address),error::unavailable(ERROR_CONTRACT_NOT_INITIALISED));
        let account_addr=signer::address_of(account);
        let global_vars=borrow_global_mut<GlobalVars>(@my_address);
        assert!(table::contains(&global_vars.slot_id_to_slot_details,slot_id),error::not_found(ERROR_SLOT_ID_NOT_PRESENT));
        let slot_table=&mut global_vars.slot_id_to_slot_details;
        let slot_details=table::borrow_mut(slot_table,slot_id);
        assert!(slot_details.end_time>timestamp::now_seconds(),error::aborted(ERROR_CANNOT_PREDICT_AFTER_INTERVAL));
        let check_if_slot_vector_created=table::contains(&global_vars.slot_to_user_addresses,slot_id);
        if(!check_if_slot_vector_created){
            let add_vector=vector::empty<address>();
            vector::push_back(&mut add_vector,account_addr);
            table::add(&mut global_vars.slot_to_user_addresses,slot_id,add_vector);
        }else{
            let slot_user_addresses=table::borrow(& global_vars.slot_to_user_addresses,slot_id);
            assert!(!vector::contains(slot_user_addresses,&account_addr),error::already_exists(ERROR_ALREADY_PRESENT_IN_SLOT));
        };

        transferring_coins(account,coins,global_vars.auth_cum_lock);


        let pred=PredictionInfo{
            slot_id,
            reference_price,
            coins
        };
        let check_if_address_vector_created=table::contains(&global_vars.user_to_prediction,account_addr);
        if(!check_if_address_vector_created){
            let add_vector=vector::empty<PredictionInfo>();
            vector::push_back(&mut add_vector,pred);
            table::add(&mut global_vars.user_to_prediction,account_addr,add_vector);
        }else{
            let prediction_vectors=table::borrow_mut( &mut global_vars.user_to_prediction,account_addr);
            vector::push_back(prediction_vectors,pred);
        };

    }

    fun get_prediction_and_slot(user_address:address,slot_id:u256):(PredictionInfo,SlotDetails)acquires GlobalVars{
        let global_vars=borrow_global<GlobalVars>(@my_address);
        assert!(table::contains(&global_vars.slot_id_to_slot_details,slot_id),error::not_found(ERROR_SLOT_ID_NOT_PRESENT));

        let slot_user_addresses=table::borrow(&global_vars.slot_to_user_addresses,slot_id);
        assert!(vector::contains(slot_user_addresses,&user_address),error::not_found(ERROR_NO_PREDICTION_FOUND));

        let slot_details=table::borrow(&global_vars.slot_id_to_slot_details,slot_id);
        // check on the start time and the end time
        assert!(timestamp::now_seconds()>slot_details.start_time && timestamp::now_seconds()>slot_details.end_time,error::permission_denied(ERROR_PREDICTION_TIME_IS_NOT_MET));

        assert!(slot_details.final_price>0,error::aborted(ERROR_FINAL_PRICE_NOT_SET));

        let all_predictions=table::borrow(&global_vars.user_to_prediction,user_address);
        let value=vector::filter(*all_predictions,|prediction|  {
            let prediction:&PredictionInfo=prediction;
            prediction.slot_id == slot_id
        } );
        (vector::pop_back(&mut value),*slot_details)
    }

    public entry fun update_final_price(account:&signer,slot_id:u256,final_price:u64)acquires GlobalVars{
        let global_vars=borrow_global_mut<GlobalVars>(@my_address);
        assert!(global_vars.auth_cum_lock==signer::address_of(account),error::permission_denied(ERROR_NOT_AUTH));
        assert!(table::contains(&global_vars.slot_id_to_slot_details,slot_id),error::not_found(ERROR_SLOT_ID_NOT_PRESENT));
        let slot_table=&mut global_vars.slot_id_to_slot_details;
        let slot_details=table::borrow_mut(slot_table,slot_id);
        slot_details.final_price=final_price;
    }

    // #[view]
    // public fun decide_winner(user_address:address,slot_id:u256):(bool) acquires GlobalVars{
    //     //Checks necessary to decide the winner
    //     let (exact_prediction,slot_details)=get_prediction_and_slot(user_address,slot_id);
    //     let decided_result:bool;
    //     if(exact_prediction.up_from_predictedprice){
    //         decided_result=slot_details.final_price>exact_prediction.reference_price;
    //     }else{
    //         decided_result=exact_prediction.reference_price>slot_details.final_price;
    //     };
    //     decided_result
    // }

    #[view]
    public fun get_slot_details(slot_id:u256):SlotDetails acquires GlobalVars{
        let global_vars=borrow_global_mut<GlobalVars>(@my_address);
        assert!(table::contains(&global_vars.slot_id_to_slot_details,slot_id),error::not_found(ERROR_SLOT_ID_NOT_PRESENT));
        let slot_table=&mut global_vars.slot_id_to_slot_details;
        let slot_details=table::borrow_mut(slot_table,slot_id);
        *slot_details
    }

    #[test_only]
    fun setup_enviroment(supra_framework:&signer,user:&signer,lock_cum_auth_acc:&signer,user_2:&signer) {
        account::create_account_for_test(signer::address_of(user));
        account::create_account_for_test(signer::address_of(supra_framework));
        account::create_account_for_test(signer::address_of(lock_cum_auth_acc));
        account::create_account_for_test(signer::address_of(user_2));
        timestamp::set_time_has_started_for_testing(supra_framework);
        timestamp::update_global_time_for_test(10000000);//10 SECONDS ADDED , 1 seconds=> 1000000 microseconds

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<SupraCoin>(
            supra_framework,//0x1
            string::utf8(b"TestCoin"),
            string::utf8(b"TC"),
            8,
            false,
        );
        coin::register<SupraCoin>(supra_framework);
        coin::register<SupraCoin>(lock_cum_auth_acc);
        let coins=coin::mint<SupraCoin>(2_000_000_000,&mint_cap);
        let coins_2=coin::mint<SupraCoin>(2_000_000_000,&mint_cap);
        coin::register<SupraCoin>(user);
        coin::register<SupraCoin>(user_2);
        coin::deposit(signer::address_of(user), coins);
        coin::deposit(signer::address_of(user_2), coins_2);
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    public entry fun create_multiple_predictions_on_multiple_slots_test(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer)acquires GlobalVars{
        setup_enviroment(supra_framework,user,lock_cum_auth_acc,user_2);
        my_address::slot_prediction::init(lock_cum_auth_acc);
        //contract init
        let coins_1=1_000_000;
        let coins_2=3_000_000;

        let slot_id_1=1;
        let slot_id_2=2;

        let start_time_1=timestamp::now_seconds() ;
        let end_time_1=timestamp::now_seconds() + 60*60;
        // let up_from_predictedprice_1=true;
        // let up_from_predictedprice_2=false;
        let reference_price_1=100000;
        //Creating MULTIPLE slot
        my_address::slot_prediction::create_slot(lock_cum_auth_acc,slot_id_1,start_time_1,end_time_1);
        my_address::slot_prediction::create_slot(lock_cum_auth_acc,slot_id_2,start_time_1,end_time_1);
        // Prediction on first slot
        my_address::slot_prediction::create_prediction(user,slot_id_1,coins_1,reference_price_1);
        my_address::slot_prediction::create_prediction(user_2,slot_id_1,coins_2,reference_price_1);
        //Prediction on second slot
        my_address::slot_prediction::create_prediction(user,slot_id_2,coins_2,reference_price_1);

    }

    // #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    // public entry fun predict_and_decide_winner(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer) acquires GlobalVars {
    //     create_multiple_predictions_on_multiple_slots_test(supra_framework,lock_cum_auth_acc,user,user_2);
    //     timestamp::fast_forward_seconds(60*60 +1);
    //     print(&timestamp::now_seconds());
    //     update_final_price(lock_cum_auth_acc,1,8000000000);
    //     let slot_details=get_slot_details(1);
    //     assert!(slot_details.final_price==8000000000,123);
    //     let result=decide_winner(signer::address_of(user),1);
    //     assert!(result==true,234);
    // }
    // #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    // #[expected_failure(abort_code=327687)]
    // public entry fun before_time_decide_fail_test(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer) acquires GlobalVars{
    //     create_multiple_predictions_on_multiple_slots_test(supra_framework,lock_cum_auth_acc,user,user_2);
    //     update_final_price(lock_cum_auth_acc,1,8000000000);
    //     let global_vars=borrow_global<GlobalVars>(@my_address);
    //     let slot_details=table::borrow(&global_vars.slot_id_to_slot_details,1);
    //     assert!(slot_details.final_price==8000000000,123);
    //     let result=decide_winner(signer::address_of(user),1);
    //     assert!(result==true,234);
    // }

    #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    #[expected_failure(abort_code=393217)]
    public entry fun slot_id_incorrect_fail_test(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer) acquires GlobalVars{
        create_multiple_predictions_on_multiple_slots_test(supra_framework,lock_cum_auth_acc,user,user_2);
        update_final_price(lock_cum_auth_acc,11,8000000000);
    }

    #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    #[expected_failure(abort_code=327685)]
    public entry fun not_auth_fail_test(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer) acquires GlobalVars{
        create_multiple_predictions_on_multiple_slots_test(supra_framework,lock_cum_auth_acc,user,user_2);
        update_final_price(user,11,8000000000);
    }

    #[test(supra_framework=@supra_framework,lock_cum_auth_acc=@my_address,user=@user,user_2=@user_2)]
    #[expected_failure(abort_code=524294)]
    public entry fun create_multiple_predictions_on_same_slots_fail_test(supra_framework:&signer,lock_cum_auth_acc:&signer,user:&signer,user_2:&signer)acquires GlobalVars{
        setup_enviroment(supra_framework,user,lock_cum_auth_acc,user_2);
        my_address::slot_prediction::init(lock_cum_auth_acc);
        //contract init
        let coins_1=1_000_000;
        let coins_2=3_000_000;

        let slot_id_1=1;

        let start_time_1=timestamp::now_seconds() ;
        let end_time_1=timestamp::now_seconds() + 60*60;
        let up_from_predictedprice_1=true;
        let up_from_predictedprice_2=false;
        let reference_price_1=100000;
        //Creating slot
        my_address::slot_prediction::create_slot(lock_cum_auth_acc,slot_id_1,start_time_1,end_time_1);
        // Predictions on first slot
        my_address::slot_prediction::create_prediction(user,slot_id_1,coins_1,reference_price_1);
        my_address::slot_prediction::create_prediction(user,slot_id_1,coins_2,reference_price_1);
    }

}
