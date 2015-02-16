-module(alley_services_mt_many).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    send/1,
    publish/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-include("application.hrl").
-include("alley_services.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-record(unconfirmed, {
    id      :: integer(),
    from    :: term()
}).

-record(st, {
    chan            :: pid(),
    chan_mon_ref    :: reference(),
    next_id = 1     :: integer()
}).

-type payload() :: binary().
-type publish_action() ::
    publish |
    publish_kelly |
    publish_just.
-type req_id() :: binary().

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec send(#send_req{}) -> {ok, [{K::atom(), V::any()}]}.
send(Req) when Req#send_req.action =:= send_sms_many ->
    send(fill_coverage_tab, Req).

-spec publish({publish_action(), payload(), req_id(), gateway_id()}) -> ok.
publish(Req) ->
    gen_server:call(?MODULE, Req, 60000).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    ?MODULE = ets:new(?MODULE, [named_table, ordered_set, {keypos, 2}]),
    case setup_chan(#st{}) of
        {ok, St} ->
            ?log_info("MT Many: started", []),
            {ok, St};
        unavailable ->
            ?log_error("MT Many: initializing failed (amqp_unavailable). shutdown", []),
            {stop, amqp_unavailable}
    end.

handle_call({Action, Payload, ReqId, GtwId}, From, St = #st{}) when
        Action =:= publish orelse
        Action =:= publish_kelly orelse
        Action =:= publish_just ->
    {ok, SmsRequestQueue} = application:get_env(?APP, kelly_sms_request_queue),
    {ok, GtwQueueFmt} = application:get_env(?APP, just_gateway_queue_fmt),
    GtwQueue = binary:replace(GtwQueueFmt, <<"%id%">>, GtwId),

    %% use rabbitMQ 'CC' extention to avoid double publish confirm per 1 request
    {Headers, RoutingKey} =
        case Action of
            publish ->
                CC = {<<"CC">>, array, [{longstr, GtwQueue}]},
                {[CC], SmsRequestQueue};
            publish_kelly ->
                {[], SmsRequestQueue};
            publish_just ->
                {[], GtwQueue}
        end,
    Props = [
        {content_type, <<"SmsReqV1">>},
        {delivery_mode, 2},
        {priority, 1},
        {message_id, ReqId},
        {headers, Headers}
    ],
    Channel = St#st.chan,
    ok = rmql:basic_publish(Channel, RoutingKey, Payload, Props),
    true = ets:insert(?MODULE, #unconfirmed{id = St#st.next_id, from = From}),
    {noreply, St#st{next_id = St#st.next_id + 1}};

handle_call(_Request, _From, St) ->
    {stop, unexpected_call, St}.

handle_cast(Req, St) ->
    {stop, {unexpected_cast, Req}, St}.

handle_info(#'DOWN'{ref = Ref, info = Info}, St = #st{chan_mon_ref = Ref}) ->
    ?log_error("MT Many: amqp channel down (~p)", [Info]),
    {stop, amqp_channel_down, St};

handle_info(Confirm, St) when is_record(Confirm, 'basic.ack');
                              is_record(Confirm, 'basic.nack') ->
    handle_confirm(Confirm),
    {noreply, St};

handle_info(_Info, St) ->
    {stop, unexpected_info, St}.

terminate(Reason, _St) ->
    ?log_info("MT Many: terminated (~p)", [Reason]),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% ===================================================================
%% Send steps
%% ===================================================================

send(fill_coverage_tab, Req) ->
    Customer = Req#send_req.customer,
    Networks = Customer#auth_customer_v1.networks,
    Providers = Customer#auth_customer_v1.providers,
    DefProvId = Customer#auth_customer_v1.default_provider_id,
    CoverageTab = ets:new(coverage_tab, [private]),
    alley_services_coverage:fill_coverage_tab(
        Networks, Providers, DefProvId, CoverageTab),
    send(check_originator, Req#send_req{coverage_tab = CoverageTab});

send(check_originator, Req) ->
    Customer = Req#send_req.customer,
    Originator = Req#send_req.originator,
    AllowedSources = Customer#auth_customer_v1.allowed_sources,
    case lists:member(Originator, AllowedSources) of
        true ->
            send(check_recipients, Req);
        false ->
            {ok, #send_result{result = originator_not_found}}
    end;

send(check_recipients, Req) ->
    case Req#send_req.recipients of
        [] ->
            {ok, #send_result{result = no_recipients}};
        [_|_] ->
            send(check_blacklist, Req)
    end;

send(check_blacklist, Req) ->
    DestAddrs  = Req#send_req.recipients,
    Originator = Req#send_req.originator,
    case alley_services_blacklist:filter(DestAddrs, Originator) of
        {[], _} ->
            {ok, #send_result{result = no_dest_addrs}};
        {Allowed, Blacklisted} ->
            send(route_to_providers, Req#send_req{
                recipients = Allowed,
                rejected = Blacklisted
            })
    end;

send(route_to_providers, Req) ->
    DestAddrs   = Req#send_req.recipients,
    CoverageTab = Req#send_req.coverage_tab,
    case alley_services_coverage:route_addrs_to_providers(DestAddrs, CoverageTab) of
        {[], _} ->
            {ok, #send_result{result = no_dest_addrs}};
        {ProvId2Addrs, UnroutableToProviders} ->
            send(route_to_gateways, Req#send_req{
                routable = ProvId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToProviders
            })
    end;

send(route_to_gateways, Req) ->
    ProvId2Addrs = Req#send_req.routable,
    Customer = Req#send_req.customer,
    Providers = Customer#auth_customer_v1.providers,
    case alley_services_coverage:route_addrs_to_gateways(ProvId2Addrs, Providers) of
        {[], _} ->
            {ok, #send_result{result = no_dest_addrs}};
        {GtwId2Addrs, UnroutableToGateways} ->
            send(process_msg_type, Req#send_req{
                routable = GtwId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToGateways
            })
    end;

%% FIXME: move this logic to clients
send(process_msg_type, Req) when
        Req#send_req.messages =:= undefined orelse
        Req#send_req.messages =:= [] ->
    {ok, #send_result{result = no_message_body}};

send(process_msg_type, Req) ->
    Messages = Req#send_req.messages,
    Type = Req#send_req.type,
    Messages2 = [{A, alley_services_utils:convert_arabic_numbers(M, Type)} || {A, M} <- Messages],
    send(define_message_encoding, Req#send_req{messages = Messages2});

send(define_message_encoding, Req) ->
    Messages = Req#send_req.messages,
    EncodeFun = fun(Msg) ->
        case gsm0338:from_utf8(Msg) of
            {valid, Binary} -> {default, Binary};
            {invalid, Binary} -> {ucs2, Binary}
        end
    end,
    {Encoding, EncodedSize} =
        lists:foldl(
            fun({A, M}, {EingAcc, EedAcc}) ->
                {Eing, Eed} = EncodeFun(M),
                {[{A, Eing} | EingAcc], [{A, size(Eed)} | EedAcc]}
            end,
            {[], []},
            Messages
        ),
    send(define_smpp_params, Req#send_req{
        encoding = Encoding,
        encoded_size = EncodedSize
    });

send(define_smpp_params, Req) ->
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#auth_customer_v1.receipts_allowed,
    NoRetry = Customer#auth_customer_v1.no_retry,
    Validity = alley_services_utils:fmt_validity(Customer#auth_customer_v1.default_validity),
    Params = Req#send_req.smpp_params ++ [
        {registered_delivery, ReceiptsAllowed},
        {service_type, <<>>},
        {no_retry, NoRetry},
        {validity_period, Validity},
        {priority_flag, 0},
        {esm_class, 3},
        {protocol_id, 0}
    ],
    ParamsFun = fun(E) ->
        [flash(Req#send_req.flash, E) | Params]
    end,
    Encoding = Req#send_req.encoding,
    Params2 = [{A, ParamsFun(E)} || {A, E} <- Encoding],
    send(check_billing, Req#send_req{smpp_params = Params2});

send(check_billing, Req) ->
    CustomerId = Req#send_req.customer_id,
    Price = calc_sending_price(Req),
    ?log_debug("Check billing (customer_id: ~p, sending price: ~p)",
        [CustomerId, Price]),
    case alley_services_api:request_credit(CustomerId, Price) of
        {allowed, CreditLeft} ->
            ?log_debug("Sending allowed. CustomerId: ~p, credit left: ~p",
                [CustomerId, CreditLeft]),
             send(build_req_dto_s, Req#send_req{credit_left = CreditLeft});
        {denied, CreditLeft} ->
            ?log_error("Sending denied. CustomerId: ~p, credit left: ~p",
                [CustomerId, CreditLeft]),
            {ok, #send_result{
                result = credit_limit_exceeded,
                credit_left = CreditLeft
            }};
        {error, timeout} ->
            {ok, #send_result{result = timeout}}
    end;

send(build_req_dto_s, Req) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Destinations = Req#send_req.routable,
    ReqDTOs = lists:flatten([
        build_req_dto(ReqId, GtwId, AddrNetIdPrices, Req) ||
        {GtwId, AddrNetIdPrices} <- Destinations
    ]),
    send(publish_dto_s, Req#send_req{req_dto_s = ReqDTOs});

send(publish_dto_s, Req) ->
    DefDate = Req#send_req.def_date,
    PublishFun =
        case alley_services_defer:is_deferred(DefDate) of
            {true, Timestamp} ->
                fun(ReqDTO) ->
                    ?log_info("mt_srv: defDate -> ~p, timestamp -> ~p", [DefDate, Timestamp]),
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#sms_req_v1.req_id,
                    GtwId = ReqDTO#sms_req_v1.gateway_id,
                    ok = alley_services_defer:defer({ReqId, GtwId}, Timestamp,
                        {publish_just, Payload, ReqId, GtwId}),
                    ok = publish({publish_kelly, Payload, ReqId, GtwId})
                end;
            false ->
                fun(ReqDTO) ->
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#sms_req_v1.req_id,
                    GtwId = ReqDTO#sms_req_v1.gateway_id,
                    ok = publish({publish, Payload, ReqId, GtwId})
                end
        end,

    ReqDTOs = Req#send_req.req_dto_s,
    ReqId = (hd(ReqDTOs))#sms_req_v1.req_id,

    lists:foreach(
        fun(ReqDTO) ->
            ?log_debug("Sending submit request: ~p", [ReqDTO]),
            PublishFun(ReqDTO)%,
            %alley_services_pdu_logger:log(ReqDTO)
        end,
        ReqDTOs
    ),

    {ok, #send_result{
        result = ok,
        req_id = ReqId,
        rejected = Req#send_req.rejected,
        customer = Req#send_req.customer,
        credit_left = Req#send_req.credit_left
    }}.

%% ===================================================================
%% Public Confirms
%% ===================================================================

handle_confirm(#'basic.ack'{delivery_tag = DTag, multiple = false}) ->
    reply_to(DTag, ok);
handle_confirm(#'basic.ack'{delivery_tag = DTag, multiple = true}) ->
    reply_up_to(DTag, ok);
handle_confirm(#'basic.nack'{delivery_tag = DTag, multiple = false}) ->
    reply_to(DTag, {error, nack});
handle_confirm(#'basic.nack'{delivery_tag = DTag, multiple = true}) ->
    reply_up_to(DTag, {error, nack}).

reply_up_to(DTag, Reply) ->
    Ids = unconfirmed_ids_up_to(DTag),
    [reply_to(Id, Reply) || Id <- Ids].

reply_to(DTag, Reply) when is_integer(DTag) ->
    [Unconf] = ets:lookup(?MODULE, DTag),
    gen_server:reply(Unconf#unconfirmed.from, Reply),
    true = ets:delete(?MODULE, Unconf#unconfirmed.id).

unconfirmed_ids_up_to(UpToId) ->
    case ets:first(?MODULE) of
        '$end_of_table' -> [];
        FirstId ->
            unconfirmed_ids_up_to(UpToId, [], FirstId)
    end.

unconfirmed_ids_up_to(UpToId, Acc, LastId) when LastId =< UpToId ->
    case ets:next(?MODULE, LastId) of
        '$end_of_table' -> [LastId | Acc];
        NextId ->
            unconfirmed_ids_up_to(UpToId, [LastId | Acc], NextId)
    end;
unconfirmed_ids_up_to(_Uuid, Acc, _LastId) ->
    Acc.

%% ===================================================================
%% Internal
%% ===================================================================

setup_chan(St = #st{}) ->
    {ok, SmsRequestQueue} = application:get_env(?APP, kelly_sms_request_queue),
    case rmql:channel_open() of
        {ok, Channel} ->
            ChanMonRef = erlang:monitor(process, Channel),
            amqp_channel:register_confirm_handler(Channel, self()),
            #'confirm.select_ok'{} = amqp_channel:call(Channel, #'confirm.select'{}),
            ok = rmql:queue_declare(Channel, SmsRequestQueue, []),
            {ok, St#st{chan = Channel, chan_mon_ref = ChanMonRef}};
        unavailable -> unavailable
    end.

flash(false, _) ->
    [];
flash(true, default) ->
    [{data_coding, 240}];
flash(true, ucs2) ->
    [{data_coding, 248}].

build_req_dto(ReqId, GatewayId, AddrNetIdPrices, Req) ->
    Encodings = dict:from_list(Req#send_req.encoding),
    Sizes = dict:from_list(Req#send_req.encoded_size),
    Messages = dict:from_list(Req#send_req.messages),
    Params = dict:from_list(Req#send_req.smpp_params),
    build_sms_req_v1(ReqId, GatewayId, Req, AddrNetIdPrices, Messages, Encodings, Sizes, Params).

build_sms_req_v1(
        ReqId, GatewayId, Req,
        AddrNetIdPrices, Messages, Encodings, Sizes, Params) ->

    {DestAddrs, NetIds, Prices} = lists:unzip3(AddrNetIdPrices),

    CustomerId = Req#send_req.customer_id,
    UserId = Req#send_req.user_id,
    Encodings2 = [dict:fetch(A, Encodings) || A <- DestAddrs],
    MsgIdFun = fun(A) ->
        Size = dict:fetch(A, Sizes),
        Encoding = dict:fetch(A, Encodings),
        NumOfSymbols = Size,
        NumOfParts = alley_services_utils:calc_parts_number(NumOfSymbols, Encoding),
        get_id(CustomerId, UserId, NumOfParts)
    end,
    InMsgIds = [MsgIdFun(A) || A <- DestAddrs],
    Params2 = [dict:fetch(A, Params) || A <- DestAddrs],
    Messages2 = [dict:fetch(A, Messages) || A <- DestAddrs],

    #sms_req_v1{
        req_id = ReqId,
        gateway_id = GatewayId,
        customer_id = CustomerId,
        user_id = UserId,
        interface = Req#send_req.client_type,
        type = regular,
        src_addr = Req#send_req.originator,
        dst_addrs = DestAddrs,
        in_msg_ids = InMsgIds,
        encodings = Encodings2,
        messages = Messages2,
        params_s = Params2,
        net_ids = NetIds,
        prices = Prices
    }.

get_id(CustomerId, UserId, Parts) ->
    {ok, Ids} = alley_services_db:next_id(CustomerId, UserId, Parts),
    Ids2 = [integer_to_list(Id) || Id <- Ids],
    list_to_binary(string:join(Ids2, ":")).

calc_sending_price(Req) ->
    GtwId2Addrs = Req#send_req.routable,
    AddrNetIdPrices = lists:flatten(
        [Addrs || {_GtwId, Addrs} <- GtwId2Addrs]),

    Encoding = Req#send_req.encoding,
    Size = Req#send_req.encoded_size,
    Price = sum(Encoding, Size, AddrNetIdPrices, 0),
    Price.

sum([{A, E} | Encs], [{A, S} | Sizes], Addr2Prices, Acc) ->
    Encoding = E,
    NumOfSymbols = S,
    NumOfParts = alley_services_utils:calc_parts_number(
        NumOfSymbols, Encoding),
    {A, _NetId, OneMsgPrice} = lists:keyfind(A, 1, Addr2Prices),
    sum(Encs, Sizes, Addr2Prices, OneMsgPrice * NumOfParts + Acc);
sum([], [], _Addr2Prices, Acc) ->
    Acc.
