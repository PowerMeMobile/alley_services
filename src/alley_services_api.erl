-module(alley_services_api).

-ignore_xref([{start_link, 0}]).

-export([
    start_link/0
]).

%% API
-export([
    get_coverage/3,
    get_blacklist/0,
    get_sms_status/3,
    retrieve_sms/4,
    request_credit/2,

    subscribe_sms_receipts/6,
    unsubscribe_sms_receipts/4,
    subscribe_incoming_sms/8,
    unsubscribe_incoming_sms/4,

    process_inbox/4
]).

-include("application.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").

-type customer_id() :: binary().
-type user_id()     :: binary().
-type version()     :: binary().
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

-spec get_coverage(customer_id(), user_id(), version()) ->
    {ok, [#k1api_coverage_response_dto{}]} | {error, term()}.
get_coverage(CustomerId, UserId, Version) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #k1api_coverage_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        version = Version
    },
    ?log_debug("Sending coverage request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"CoverageReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_coverage_response_dto{}, RespBin) of
                {ok, Resp = #k1api_coverage_response_dto{}} ->
                    ?log_debug("Got coverage response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Coverage response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_debug("Got coverage response: timeout", []),
            {error, timeout}
    end.

-spec get_blacklist() ->
    {ok, [#k1api_blacklist_response_dto{}]} | {error, term()}.
get_blacklist() ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #k1api_blacklist_request_dto{
        id = ReqId,
        customer_id = <<>>,
        user_id = <<>>,
        version = <<>>
    },
    ?log_debug("Sending blacklist request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"BlacklistReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_blacklist_response_dto{}, RespBin) of
                {ok, Resp = #k1api_blacklist_response_dto{}} ->
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

-spec get_sms_status(customer_id(), user_id(), request_id()) ->
    {ok, [#sms_status_resp_v1{}]} | {error, term()}.
get_sms_status(_CustomerId, _UserId, undefined) ->
    {error, empty_request_id};
get_sms_status(_CustomerId, _UserId, <<"">>) ->
    {error, empty_request_id};
get_sms_status(CustomerId, UserId, SmsReqId) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #sms_status_req_v1{
        req_id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        sms_req_id = SmsReqId
    },
    ?log_debug("Sending sms status request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"SmsStatusReqV1">>) of
        {ok, RespBin} ->
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

-spec retrieve_sms(customer_id(), user_id(), dst_addr(), pos_integer()) ->
    {ok, [#k1api_retrieve_sms_response_dto{}]} | {error, term()}.
retrieve_sms(_CustomerId, _UserId, _DestAddr, BatchSize)
        when is_integer(BatchSize), BatchSize =< 0 ->
    {error, invalid_bax_match_size};
retrieve_sms(CustomerId, UserId, DestAddr, BatchSize) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #k1api_retrieve_sms_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        dest_addr = DestAddr,
        batch_size = BatchSize
    },
    ?log_debug("Sending retrieve sms request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"RetrieveSmsReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_retrieve_sms_response_dto{}, RespBin) of
                {ok, Resp = #k1api_retrieve_sms_response_dto{}} ->
                    ?log_debug("Got retrieve sms response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Retrive sms response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Got retrive sms response: timeout", []),
            {error, timeout}
    end.

-spec request_credit(customer_id(), float()) ->
    {allowed, float()} | {denied, float()} | {error, term()}.
request_credit(CustomerId, Credit) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #k1api_request_credit_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        credit = Credit
    },
    ?log_debug("Sending request credit request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"RequestCreditReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_request_credit_response_dto{}, RespBin) of
                {ok, Resp = #k1api_request_credit_response_dto{}} ->
                    ?log_debug("Got request credit response: ~p", [Resp]),
                    Result = Resp#k1api_request_credit_response_dto.result,
                    CreditLeft = Resp#k1api_request_credit_response_dto.credit_left,
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
    request_id(), customer_id(), user_id(),
    binary(), src_addr(), binary()
) ->
    {#k1api_subscribe_sms_receipts_response_dto{}} | {error, term()}.
subscribe_sms_receipts(_ReqId, _CustomerId, _UserId,
    undefined, _SrcAddr, _CallbackData) ->
    {error, empty_notify_url};
subscribe_sms_receipts(_ReqId, _CustomerId, _UserId,
    <<>>, _SrcAddr, _CallbackData) ->
    {error, empty_notify_url};
subscribe_sms_receipts(
    ReqId, CustomerId, UserId,
    NotifyUrl, SrcAddr, CallbackData
) ->
    Req = #k1api_subscribe_sms_receipts_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        url = NotifyUrl,
        dest_addr = SrcAddr, %% Must be SrcAddr
        callback_data = CallbackData
    },
    ?log_debug("Sending subscribe sms receipts request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"SubscribeSmsReceiptsReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_subscribe_sms_receipts_response_dto{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got subscribe sms receipts sms response: ~p", [Resp]),
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
    request_id(), customer_id(), user_id(), subscription_id()
) ->
    {ok, #k1api_unsubscribe_sms_receipts_response_dto{}} | {error, term()}.
unsubscribe_sms_receipts(ReqId, CustomerId, UserId, SubscriptionId) ->
    Req = #k1api_unsubscribe_sms_receipts_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        subscription_id = SubscriptionId
    },
    ?log_debug("Sending unsubscribe sms receipts request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"UnsubscribeSmsReceiptsReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_unsubscribe_sms_receipts_response_dto{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got unsubscribe sms receipts sms response: ~p", [Resp]),
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
    request_id(), customer_id(), user_id(), dst_addr(),
    binary(), binary(), binary(), binary()
) ->
    {ok, #k1api_subscribe_incoming_sms_response_dto{}} | {error, term()}.
subscribe_incoming_sms(
    _ReqId, _CustomerId, _UserId, undefined,
    _notifyURL, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_dest_addr};
subscribe_incoming_sms(
    _ReqId, _CustomerId, _UserId, #addr{addr = <<>>},
    _notifyURL, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_dest_addr};
subscribe_incoming_sms(
    _ReqId, _CustomerId, _UserId, _DestAddr,
    undefined, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_notify_url};
subscribe_incoming_sms(
    _ReqId, _CustomerId, _UserId, _DestAddr,
    <<>>, _Criteria, _Correlator, _CallbackData
) ->
    {error, empty_notify_url};
subscribe_incoming_sms(
    ReqId, CustomerId, UserId, DestAddr,
    NotifyUrl, Criteria, Correlator, CallbackData
) ->
    Req = #k1api_subscribe_incoming_sms_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        dest_addr = DestAddr,
        notify_url = NotifyUrl,
        criteria = Criteria,
        correlator = Correlator,
        callback_data = CallbackData
    },
    ?log_debug("Sending subscribe incoming sms request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"SubscribeIncomingSmsReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_subscribe_incoming_sms_response_dto{}, RespBin) of
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
    request_id(), customer_id(), user_id(), subscription_id()
) ->
    {ok, #k1api_unsubscribe_incoming_sms_response_dto{}} | {error, term()}.
unsubscribe_incoming_sms(ReqId, CustomerId, UserId, SubscriptionId) ->
    Req = #k1api_unsubscribe_incoming_sms_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        subscription_id = SubscriptionId
    },
    ?log_debug("Sending unsubscribe incoming sms request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"UnsubscribeIncomingSmsReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_unsubscribe_incoming_sms_response_dto{}, RespBin) of
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

-type inbox_operation() :: list_all | list_new
                         | fetch_all | fetch_new | fetch_id
                         | kill_all | kill_old | kill_id.
-type message_ids()     :: [binary()].
-spec process_inbox(customer_id(), user_id(), inbox_operation(), message_ids()) ->
    {ok, #k1api_process_inbox_response_dto{}} | {error, term()}.
process_inbox(CustomerId, UserId, Operation, MessageIds) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #k1api_process_inbox_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        operation = Operation,
        message_ids = MessageIds
    },
    ?log_debug("Sending process inbox request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    case rmql_rpc_client:call(?MODULE, ReqBin, <<"ProcessInboxReq">>) of
        {ok, RespBin} ->
            case adto:decode(#k1api_process_inbox_response_dto{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got process inbox response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Process inbox response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Process inbox response: timeout", []),
            {error, timeout}
    end.
