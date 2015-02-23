-module(alley_services_mt).

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
send(Req) ->
    send(check_interface, Req).

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
        {content_type, <<"SmsReqV1z">>},
        {delivery_mode, 2},
        {priority, 1},
        {message_id, ReqId},
        {headers, Headers}
    ],
    Channel = St#st.chan,
    PayloadZ = zlib:compress(Payload),
    ok = rmql:basic_publish(Channel, RoutingKey, PayloadZ, Props),
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

send(check_interface, Req) ->
    case Req#send_req.interface of
        undefined ->
            {ok, #send_result{result = no_interface}};
        _ ->
            send(fill_coverage_tab, Req)
    end;

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
            send(check_billing, Req#send_req{
                routable = GtwId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToGateways
            })
    end;

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
            PublishFun(ReqDTO),
            alley_services_pdu_logger:log(ReqDTO)
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

build_req_dto(ReqId, GatewayId, AddrNetIdPrices, Req)
        when Req#send_req.req_type =:= one_to_many ->
    CustomerId = Req#send_req.customer_id,
    UserId = Req#send_req.user_id,

    {DestAddrs, NetIds, Prices} = lists:unzip3(AddrNetIdPrices),

    Encoding = Req#send_req.encoding,
    NumOfSymbols = Req#send_req.size,
    NumOfDests = length(DestAddrs),
    NumOfParts = alley_services_utils:calc_parts_number(NumOfSymbols, Encoding),
    MsgIds = get_ids(CustomerId, UserId, NumOfDests, NumOfParts),
    Params = Req#send_req.params,

    Dup = length(DestAddrs),

    #sms_req_v1{
        req_id = ReqId,
        gateway_id = GatewayId,
        customer_id = CustomerId,
        user_id = UserId,
        interface = Req#send_req.interface,
        type = regular,
        src_addr = Req#send_req.originator,
        dst_addrs = DestAddrs,
        msg_ids = MsgIds,
        message = Req#send_req.message,
        messages = lists:duplicate(Dup, Req#send_req.message),
        encodings = lists:duplicate(Dup, Encoding),
        params_s = lists:duplicate(Dup, Params),
        net_ids = NetIds,
        prices = Prices
    };
build_req_dto(ReqId, GatewayId, AddrNetIdPrices, Req)
        when Req#send_req.req_type =:= many_to_many ->
    EncDict = dict_from_list(Req#send_req.encoding_map),
    SizeDict = dict_from_list(Req#send_req.size_map),
    MsgDict = dict_from_list(Req#send_req.message_map),
    ParamsDict = dict_from_list(Req#send_req.params_map),
    build_sms_req_v1(ReqId, GatewayId, Req, AddrNetIdPrices, MsgDict, EncDict, SizeDict, ParamsDict).

dict_from_list(KVs) ->
    dict_from_list(KVs, dict:new()).

dict_from_list([], Dict) ->
    Dict;
dict_from_list([{K, V}| KVs], Dict) ->
    InsertFun = fun(Acc) -> [V | Acc] end,
    dict_from_list(KVs, dict:update(K, InsertFun, [V], Dict)).

fetch_one(Addr, MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict) ->
    case dict:fetch(Addr, MsgDict) of
        [Msg] ->
            [Enc] = dict:fetch(Addr, EncDict),
            [Size] = dict:fetch(Addr, SizeDict),
            [Params] = dict:fetch(Addr, ParamsDict),
            MsgId = MsgIdFun(Enc, Size),
            {MsgId, Msg, Enc, Params,
             MsgDict, EncDict, SizeDict, ParamsDict};
        [Msg|_] ->
            [Enc|_] = dict:fetch(Addr, EncDict),
            [Size|_] = dict:fetch(Addr, SizeDict),
            [Params|_] = dict:fetch(Addr, ParamsDict),
            MsgId = MsgIdFun(Enc, Size),
            RemoveFun = fun([_|Acc]) -> Acc end,
            {MsgId, Msg, Enc, Params,
             dict:update(Addr, RemoveFun, MsgDict),
             dict:update(Addr, RemoveFun, EncDict),
             dict:update(Addr, RemoveFun, SizeDict),
             dict:update(Addr, RemoveFun, ParamsDict)}
    end.

fetch_all(Addrs, MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict) ->
    fetch_all(Addrs, MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict, []).

fetch_all([], _MsgIdFun, _MsgDict, _EncDict, _SizeDict, _ParamsDict, Acc) ->
    lists:reverse(Acc);
fetch_all([Addr|Addrs], MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict, Acc) ->
    {MsgId, Msg, Enc, Params,
     MsgDict2, EncDict2, SizeDict2, ParamsDict2} =
        fetch_one(Addr, MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict),
    Acc2 = [{MsgId, Msg, Enc, Params} | Acc],
    fetch_all(Addrs, MsgIdFun, MsgDict2, EncDict2, SizeDict2, ParamsDict2, Acc2).

build_sms_req_v1(ReqId, GatewayId, Req, AddrNetIdPrices,
        MsgDict, EncDict, SizeDict, ParamsDict) ->
    CustomerId = Req#send_req.customer_id,
    UserId = Req#send_req.user_id,

    {DestAddrs, NetIds, Prices} = lists:unzip3(AddrNetIdPrices),

    MsgIdFun = fun(Enc, Size) ->
        NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
        get_id(CustomerId, UserId, NumOfParts)
    end,
    {MsgIds, Msgs, Encs, Params} = ac_lists:unzip4(
        fetch_all(DestAddrs, MsgIdFun, MsgDict, EncDict, SizeDict, ParamsDict)),

    #sms_req_v1{
        req_id = ReqId,
        gateway_id = GatewayId,
        customer_id = CustomerId,
        user_id = UserId,
        interface = Req#send_req.interface,
        type = regular,
        src_addr = Req#send_req.originator,
        dst_addrs = DestAddrs,
        msg_ids = MsgIds,
        message = Req#send_req.message,
        messages = Msgs,
        encodings = Encs,
        params_s = Params,
        net_ids = NetIds,
        prices = Prices
    }.

get_id(CustomerId, UserId, Parts) ->
    {ok, Ids} = alley_services_db:next_id(CustomerId, UserId, Parts),
    Ids2 = [integer_to_list(Id) || Id <- Ids],
    list_to_binary(string:join(Ids2, ":")).

get_ids(CustomerId, UserId, NumberOfDests, Parts) ->
    {ok, Ids} = alley_services_db:next_id(CustomerId, UserId, NumberOfDests * Parts),
    {DTOIds, []} =
        lists:foldl(
          fun(Id, {Acc, Group}) when (length(Group) + 1) =:= Parts ->
                  StrId = integer_to_list(Id),
                  GroupIds = list_to_binary(string:join(lists:reverse([StrId | Group]), ":")),
                  {[GroupIds | Acc], []};
             (Id, {Acc, Group}) ->
                  {Acc, [integer_to_list(Id) | Group]}
          end, {[], []}, Ids),
    DTOIds.

calc_sending_price(Req) when Req#send_req.req_type =:= one_to_many ->
    GtwId2Addrs = Req#send_req.routable,
    AddrNetIdPrices = lists:flatten(
        [Addrs || {_GtwId, Addrs} <- GtwId2Addrs]),

    Enc = Req#send_req.encoding,
    Size = Req#send_req.size,
    NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
    Price = alley_services_coverage:calc_sending_price(
        AddrNetIdPrices, NumOfParts),
    Price;
calc_sending_price(Req) when Req#send_req.req_type =:= many_to_many ->
    GtwId2Addrs = Req#send_req.routable,
    AddrNetIdPrices = lists:flatten(
        [Addrs || {_GtwId, Addrs} <- GtwId2Addrs]),

    EncMap = Req#send_req.encoding_map,
    SizeMap = Req#send_req.size_map,
    Price = sum(EncMap, SizeMap, AddrNetIdPrices, 0),
    Price.

sum([{A, E} | Encs], [{A, S} | Sizes], Addr2Prices, Acc) ->
    Enc = E,
    Size = S,
    NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
    {A, _NetId, OneMsgPrice} = lists:keyfind(A, 1, Addr2Prices),
    sum(Encs, Sizes, Addr2Prices, OneMsgPrice * NumOfParts + Acc);
sum([], [], _Addr2Prices, Acc) ->
    Acc.
