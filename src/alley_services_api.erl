-module(alley_services_api).

-ignore_xref([{start_link, 0}]).

-export([
    start_link/0
]).

%% API
-export([
    get_coverage/1,
    get_blacklist/0,
    get_sms_status/3,
    request_credit/2,

    process_inbox/4,

    %% OneAPI specific
    retrieve_incoming/4,
    subscribe_sms_receipts/6,
    unsubscribe_sms_receipts/4,
    subscribe_incoming_sms/8,
    unsubscribe_incoming_sms/4
]).

-include("application.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").

-type customer_uuid() :: uuid().
-type customer_id() :: binary().
-type user_id()     :: binary().
-type request_id()  :: binary().
-type src_addr()    :: binary().
-type dst_addr()    :: binary().
-type subscription_id() :: binary().

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, QueueName} = application:get_env(?APP, kelly_api_queue),
    rmql_rpc_client:start_link(?MODULE, QueueName).

-spec get_coverage(customer_id()) ->
    {ok, [#coverage_resp_v1{}]} | {error, term()}.
get_coverage(CustomerId) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #coverage_req_v1{
        req_id = ReqId,
        customer_id = CustomerId
    },
    ?log_debug("Sending coverage request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"CoverageReqV1">>, ReqBin, Timeout) of
        {ok, <<"CoverageRespV1">>, RespBin} ->
            case adto:decode(#coverage_resp_v1{}, RespBin) of
                {ok, Resp = #coverage_resp_v1{}} ->
                    ?log_debug("Got coverage response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Coverage response decode error: ~p", [Error])
            end;
        {ok, <<"ErrorRespV1">>, RespBin} ->
            case adto:decode(#error_resp_v1{}, RespBin) of
                {ok, #error_resp_v1{error = Error}} ->
                    ?log_error("Got coverage error: ~p", [Error]),
                    {error, Error};
                {error, Error} ->
                    ?log_error("Coverage error response decode error: ~p, ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_debug("Got coverage response: timeout", []),
            {error, timeout}
    end.

-spec get_blacklist() ->
    {ok, [#blacklist_resp_v1{}]} | {error, term()}.
get_blacklist() ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #blacklist_req_v1{
        req_id = ReqId
    },
    ?log_debug("Sending blacklist request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"BlacklistReqV1">>, ReqBin, Timeout) of
        {ok, <<"BlacklistRespV1">>, RespBin} ->
            case adto:decode(#blacklist_resp_v1{}, RespBin) of
                {ok, Resp = #blacklist_resp_v1{}} ->
                    ?log_debug("Got blacklist response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Coverage blacklist decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_debug("Got blacklist response: timeout", []),
            {error, timeout}
    end.

-spec get_sms_status(customer_uuid(), user_id(), request_id()) ->
    {ok, [#sms_status_resp_v1{}]} | {error, term()}.
get_sms_status(_CustomerUuid, _UserId, undefined) ->
    {error, empty_request_id};
get_sms_status(_CustomerUuid, _UserId, <<"">>) ->
    {error, empty_request_id};
get_sms_status(CustomerUuid, UserId, SmsReqId) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #sms_status_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        sms_req_id = SmsReqId
    },
    ?log_debug("Sending sms status request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"SmsStatusReqV1">>, ReqBin, Timeout) of
        {ok, <<"SmsStatusRespV1">>, RespBin} ->
            case adto:decode(#sms_status_resp_v1{}, RespBin) of
                {ok, Resp = #sms_status_resp_v1{statuses = []}} ->
                    ?log_debug("Got delivery status response: ~p", [Resp]),
                    ?log_error("Delivery status response failed with: ~p", [invalid_request_id]),
                    {error, invalid_request_id};
                {ok, Resp = #sms_status_resp_v1{}} ->
                    ?log_debug("Got delivery status response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Delivery status response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_debug("Got delivery status response: timeout", []),
            {error, timeout}
    end.

-spec retrieve_incoming(customer_uuid(), user_id(), dst_addr(), pos_integer()) ->
    {ok, [#retrieve_incoming_resp_v1{}]} | {error, term()}.
retrieve_incoming(_CustomerUuid, _UserId, _DestAddr, BatchSize)
        when is_integer(BatchSize), BatchSize =< 0 ->
    {error, invalid_bax_match_size};
retrieve_incoming(CustomerUuid, UserId, DestAddr, BatchSize) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #retrieve_incoming_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        dst_addr = DestAddr,
        batch_size = BatchSize
    },
    ?log_debug("Sending retrieve incoming request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"RetrieveIncomingReqV1">>, ReqBin, Timeout) of
        {ok, <<"RetrieveIncomingRespV1">>, RespBin} ->
            case adto:decode(#retrieve_incoming_resp_v1{}, RespBin) of
                {ok, Resp = #retrieve_incoming_resp_v1{}} ->
                    ?log_debug("Got retrieve incoming response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Retrive incoming response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Got retrive incoming response: timeout", []),
            {error, timeout}
    end.

-spec request_credit(customer_id(), float()) ->
    {allowed, float()} | {denied, float()} | {error, term()}.
request_credit(CustomerId, Credit) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #credit_req_v1{
        req_id = ReqId,
        customer_id = CustomerId,
        credit = Credit
    },
    ?log_debug("Sending request credit request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"CreditReqV1">>, ReqBin, Timeout) of
        {ok, <<"CreditRespV1">>, RespBin} ->
            case adto:decode(#credit_resp_v1{}, RespBin) of
                {ok, Resp = #credit_resp_v1{}} ->
                    ?log_debug("Got request credit response: ~p", [Resp]),
                    Result = Resp#credit_resp_v1.result,
                    CreditLeft = Resp#credit_resp_v1.credit_left,
                    {Result, CreditLeft};
                {error, Error} ->
                    ?log_error("Request credit response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Got request credit response: timeout", []),
            {error, timeout}
    end.

-spec subscribe_sms_receipts(
    request_id(), customer_uuid(), user_id(),
    binary(), src_addr(), binary()
) ->
    {#sub_sms_receipts_resp_v1{}} | {error, term()}.
subscribe_sms_receipts(_ReqId, _CustomerUuid, _UserId,
    undefined, _SrcAddr, _CallbackData) ->
    {error, empty_notify_url};
subscribe_sms_receipts(_ReqId, _CustomerUuid, _UserId,
    <<>>, _SrcAddr, _CallbackData) ->
    {error, empty_notify_url};
subscribe_sms_receipts(
    ReqId, CustomerUuid, UserId,
    NotifyUrl, SrcAddr, CallbackData
) ->
    Req = #sub_sms_receipts_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        url = NotifyUrl,
        dest_addr = SrcAddr, %% Must be SrcAddr
        callback_data = CallbackData
    },
    ?log_debug("Sending subscribe sms receipts request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"SubSmsReceiptsReqV1">>, ReqBin, Timeout) of
        {ok, <<"SubSmsReceiptsRespV1">>, RespBin} ->
            case adto:decode(#sub_sms_receipts_resp_v1{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got subscribe sms receipts response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Subscribe sms receipts response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Subscribe sms receipts response: timeout", []),
            {error, timeout}
    end.

-spec unsubscribe_sms_receipts(
    request_id(), customer_uuid(), user_id(), subscription_id()
) ->
    {ok, #unsub_sms_receipts_resp_v1{}} | {error, term()}.
unsubscribe_sms_receipts(ReqId, CustomerUuid, UserId, SubscriptionId) ->
    Req = #unsub_sms_receipts_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        subscription_id = SubscriptionId
    },
    ?log_debug("Sending unsubscribe sms receipts request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"UnsubSmsReceiptsReqV1">>, ReqBin, Timeout) of
        {ok, <<"UnsubSmsReceiptsRespV1">>, RespBin} ->
            case adto:decode(#unsub_sms_receipts_resp_v1{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got unsubscribe sms receipts response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Unsubscribe sms receipts response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Unsubscribe sms receipts response: timeout", []),
            {error, timeout}
    end.

-spec subscribe_incoming_sms(
    request_id(), customer_uuid(), user_id(), dst_addr(),
    binary(), binary(), binary(), binary()
) ->
    {ok, #sub_incoming_sms_resp_v1{}} | {error, term()}.
subscribe_incoming_sms(
    _ReqId, _CustomerUuid, _UserId, undefined,
    _notifyURL, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_dest_addr};
subscribe_incoming_sms(
    _ReqId, _CustomerUuid, _UserId, #addr{addr = <<>>},
    _notifyURL, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_dest_addr};
subscribe_incoming_sms(
    _ReqId, _CustomerUuid, _UserId, _DestAddr,
    undefined, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_notify_url};
subscribe_incoming_sms(
    _ReqId, _CustomerUuid, _UserId, _DestAddr,
    <<>>, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_notify_url};
subscribe_incoming_sms(
    ReqId, CustomerUuid, UserId, DestAddr,
    NotifyUrl, Criteria, Correlator, CallbackData
) ->
    Req = #sub_incoming_sms_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        dest_addr = DestAddr,
        notify_url = NotifyUrl,
        criteria = Criteria,
        correlator = Correlator,
        callback_data = CallbackData
    },
    ?log_debug("Sending subscribe incoming sms request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"SubIncomingSmsReqV1">>, ReqBin, Timeout) of
        {ok, <<"SubIncomingSmsRespV1">>, RespBin} ->
            case adto:decode(#sub_incoming_sms_resp_v1{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got subscribe incoming sms response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Subscribe incoming sms response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Subscribe incoming sms response: timeout", []),
            {error, timeout}
    end.

-spec unsubscribe_incoming_sms(
    request_id(), customer_uuid(), user_id(), subscription_id()
) ->
    {ok, #unsub_incoming_sms_resp_v1{}} | {error, term()}.
unsubscribe_incoming_sms(ReqId, CustomerUuid, UserId, SubscriptionId) ->
    Req = #unsub_incoming_sms_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        subscription_id = SubscriptionId
    },
    ?log_debug("Sending unsubscribe incoming sms request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"UnsubIncomingSmsReqV1">>, ReqBin, Timeout) of
        {ok, <<"UnsubIncomingSmsRespV1">>, RespBin} ->
            case adto:decode(#unsub_incoming_sms_resp_v1{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got unsubscribe incoming sms response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Unsubscribe incoming sms response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Unsubscribe incoming sms response: timeout", []),
            {error, timeout}
    end.

-type inbox_operation() :: get_info
                         | list_all | list_new
                         | fetch_all | fetch_new | fetch_id
                         | delete_all | delete_read | delete_id.
-type message_ids()     :: [binary()].
-spec process_inbox(customer_uuid(), user_id(), inbox_operation(), message_ids()) ->
    {ok, #inbox_resp_v1{}} | {error, term()}.
process_inbox(_CustomerUuid, _UserId, Oper, _MsgIds)
    when Oper =/= get_info,
         Oper =/= list_all, Oper =/= list_new,
         Oper =/= fetch_all, Oper =/= fetch_new, Oper =/= fetch_id,
         Oper =/= delete_all, Oper =/= delete_read, Oper =/= delete_id,
         Oper =/= mark_as_read_id, Oper =/= mark_as_unread_id ->
    {error, bad_operation};
process_inbox(CustomerUuid, UserId, Operation, MsgIds) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #inbox_req_v1{
        req_id = ReqId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        operation = Operation,
        msg_ids = MsgIds
    },
    ?log_debug("Sending inbox request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_api_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"InboxReqV1">>, ReqBin, Timeout) of
        {ok, <<"InboxRespV1">>, RespBin} ->
            case adto:decode(#inbox_resp_v1{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got inbox response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Inbox response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Inbox response: timeout", []),
            {error, timeout}
    end.
