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
-type publish_action() :: publish | publish_deferred.
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

handle_call({Action, Payload, ReqId, GtwId}, From, St = #st{}) ->
    {Headers, RoutingKey} = headers_and_routing_key(Action, GtwId),
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
            send(remove_rejected_for_multiple_type, Req#send_req{
                routable = GtwId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToGateways
            })
    end;

send(remove_rejected_for_multiple_type, Req)
        when Req#send_req.req_type =:= multiple ->
    Rejected = Req#send_req.rejected,
    SizeDict = dict_from_list(Req#send_req.size_map),
    MsgDict = dict_from_list(Req#send_req.message_map),
    SizeDict2 = dict_erase_keys(SizeDict, Rejected),
    MsgDict2 = dict_erase_keys(MsgDict, Rejected),
    send(check_billing, Req#send_req{
        size_map = SizeDict2,
        message_map = MsgDict2
    });
send(remove_rejected_for_multiple_type, Req) ->
    send(check_billing, Req);

send(check_billing, Req) ->
    CustomerUuid = Req#send_req.customer_uuid,
    Price = calc_sending_price(Req),
    ?log_debug("Check billing (customer_uuid: ~p, sending price: ~p)",
        [CustomerUuid, Price]),
    case alley_services_api:request_credit(CustomerUuid, Price) of
        {allowed, CreditLeft} ->
            ?log_debug("Sending allowed. CustomerUuid: ~p, credit left: ~p",
                [CustomerUuid, CreditLeft]),
             send(build_req_dto_s, Req#send_req{credit_left = CreditLeft});
        {denied, CreditLeft} ->
            ?log_error("Sending denied. CustomerUuid: ~p, credit left: ~p",
                [CustomerUuid, CreditLeft]),
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
    ReqTime = ac_datetime:utc_timestamp(),
    Req2 = Req#send_req{req_time = ReqTime},
    ok = alley_services_id_generator:init(ReqId),
    ReqDTOs = lists:flatten([
        build_req_dto(ReqId, GtwId, AddrNetIdPrices, Req2) ||
        {GtwId, AddrNetIdPrices} <- Destinations
    ]),
    ok = alley_services_id_generator:deinit(ReqId),
    send(publish_dto_s, Req#send_req{req_dto_s = ReqDTOs});

send(publish_dto_s, Req) ->
    DefTime = Req#send_req.def_time,
    PublishFun =
        case DefTime of
            undefined ->
                fun(ReqDTO) ->
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#sms_req_v1.req_id,
                    GtwId = ReqDTO#sms_req_v1.gateway_id,
                    ok = publish({publish, Payload, ReqId, GtwId})
                end;
            DefTime ->
                fun(ReqDTO) ->
                    ?log_info("DefTime: ~p", [DefTime]),
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#sms_req_v1.req_id,
                    GtwId = ReqDTO#sms_req_v1.gateway_id,
                    ok = publish({publish_deferred, Payload, ReqId, GtwId})
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

headers_and_routing_key(publish, GtwId) ->
    {ok, SmsReqQueue} = application:get_env(?APP, kelly_sms_request_queue),
    {ok, GtwQueueFmt} = application:get_env(?APP, just_gateway_queue_fmt),
    GtwQueue = binary:replace(GtwQueueFmt, <<"%id%">>, GtwId),
    %% use rabbitMQ 'CC' extention to avoid
    %% doubling publish confirm per 1 request
    CC = {<<"CC">>, array, [{longstr, GtwQueue}]},
    {[CC], SmsReqQueue};
headers_and_routing_key(publish_deferred, _GtwId) ->
    {ok, SmsReqDefQueue} = application:get_env(?APP, kelly_sms_request_deferred_queue),
    {[], SmsReqDefQueue}.

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
        when Req#send_req.req_type =:= single ->
    CustomerUuid = Req#send_req.customer_uuid,
    UserId = Req#send_req.user_id,
    ReqTime = Req#send_req.req_time,
    DefTime = Req#send_req.def_time,

    {DestAddrs, NetIds, Prices} = lists:unzip3(AddrNetIdPrices),

    Encoding = Req#send_req.encoding,
    NumOfSymbols = Req#send_req.size,
    NumOfDests = length(DestAddrs),
    NumOfParts = alley_services_utils:calc_parts_number(NumOfSymbols, Encoding),
    MsgIds = get_next_msg_ids(ReqId, NumOfDests, NumOfParts),
    Params = Req#send_req.params,

    #sms_req_v1{
        req_id = ReqId,
        gateway_id = GatewayId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        interface = Req#send_req.interface,
        req_time = ReqTime,
        def_time = DefTime,
        src_addr = Req#send_req.originator,
        type = regular,
        message = Req#send_req.message,
        encoding = Encoding,
        params = Params,
        dst_addrs = DestAddrs,
        msg_ids = MsgIds,
        net_ids = NetIds,
        prices = Prices
    };
build_req_dto(ReqId, GatewayId, AddrNetIdPrices, Req)
        when Req#send_req.req_type =:= multiple ->
    Encoding = Req#send_req.encoding,
    Params = Req#send_req.params,
    SizeDict = Req#send_req.size_map,
    MsgDict = Req#send_req.message_map,
    build_sms_req_v1(ReqId, GatewayId, Req, AddrNetIdPrices, Encoding, Params, MsgDict, SizeDict).

build_sms_req_v1(ReqId, GatewayId, Req, AddrNetIdPrices,
        Encoding, Params, MsgDict, SizeDict) ->
    CustomerUuid = Req#send_req.customer_uuid,
    UserId = Req#send_req.user_id,
    ReqTime = Req#send_req.req_time,
    DefTime = Req#send_req.def_time,

    {DestAddrs, NetIds, Prices} = lists:unzip3(AddrNetIdPrices),

    MsgIdFun2 = fun(Enc, Size) ->
        NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
        get_next_msg_id(ReqId, NumOfParts)
    end,
    {MsgIds, Msgs} = lists:unzip(
        fetch_all(DestAddrs, MsgIdFun2, Encoding, MsgDict, SizeDict)),

    #sms_req_v1{
        req_id = ReqId,
        gateway_id = GatewayId,
        customer_uuid = CustomerUuid,
        user_id = UserId,
        interface = Req#send_req.interface,
        req_time = ReqTime,
        def_time = DefTime,
        src_addr = Req#send_req.originator,
        type = regular,
        message = Req#send_req.message,
        encoding = Encoding,
        params = Params,
        dst_addrs = DestAddrs,
        msg_ids = MsgIds,
        messages = Msgs,
        net_ids = NetIds,
        prices = Prices
    }.

get_next_msg_id(ReqId, Parts) ->
    Ids = alley_services_id_generator:next_ids(ReqId, Parts),
    Ids2 = [integer_to_list(Id) || Id <- Ids],
    list_to_binary(string:join(Ids2, ":")).

get_next_msg_ids(ReqId, NumberOfDests, Parts) ->
    Ids = alley_services_id_generator:next_ids(ReqId, NumberOfDests * Parts),
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

calc_sending_price(Req) when Req#send_req.req_type =:= single ->
    GtwId2Addrs = Req#send_req.routable,
    AddrNetIdPrices = lists:flatten(
        [Addrs || {_GtwId, Addrs} <- GtwId2Addrs]),

    Size = Req#send_req.size,
    Enc = Req#send_req.encoding,
    NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
    alley_services_coverage:calc_sending_price(
        AddrNetIdPrices, NumOfParts);
calc_sending_price(Req) when Req#send_req.req_type =:= multiple ->
    GtwId2Addrs = Req#send_req.routable,
    AddrNetIdPrices = lists:flatten(
        [Addrs || {_GtwId, Addrs} <- GtwId2Addrs]),

    ASizes = dict:to_list(Req#send_req.size_map),
    Enc = Req#send_req.encoding,
    sum(ASizes, Enc, AddrNetIdPrices, 0).

sum([{A, Sizes} | ASizes], Enc, Addr2Prices, Acc) ->
    case lists:keyfind(A, 1, Addr2Prices) of
        {A, _NetId, OneMsgPrice} ->
            Price = lists:sum(lists:map(
                fun(Size) ->
                    NumOfParts = alley_services_utils:calc_parts_number(Size, Enc),
                    OneMsgPrice * NumOfParts
                end,
                Sizes
            )),
            sum(ASizes, Enc, Addr2Prices, Price + Acc);
        false ->
            ?log_error("Addr NOT FOUND in Addr2Prices: ~p", [A]),
            sum(ASizes, Enc, Addr2Prices, Acc)
    end;
sum([], _Enc, _Addr2Prices, Acc) ->
    Acc.

%% build like [{Key, [V1,...]}} structure
%% to allow duplicate keys.
dict_from_list(KVs) ->
    dict_from_list(KVs, dict:new()).

dict_from_list([], Dict) ->
    Dict;
dict_from_list([{K, V}| KVs], Dict) ->
    Dict2 = ac_dict:prepend(K, V, Dict),
    dict_from_list(KVs, Dict2).

dict_erase_keys(Dict, []) ->
    Dict;
dict_erase_keys(Dict, [Key | Keys]) ->
    dict_erase_keys(dict:erase(Key, Dict), Keys).

fetch_one(Addr, MsgIdFun2, Enc, MsgDict, SizeDict) ->
    case dict:fetch(Addr, MsgDict) of
        [Msg] ->
            [Size] = dict:fetch(Addr, SizeDict),
            MsgId = MsgIdFun2(Enc, Size),
            {MsgId, Msg, MsgDict, SizeDict};
        [Msg|_] ->
            [Size|_] = dict:fetch(Addr, SizeDict),
            MsgId = MsgIdFun2(Enc, Size),
            RemoveFun = fun([_|Acc]) -> Acc end,
            {MsgId, Msg,
             dict:update(Addr, RemoveFun, MsgDict),
             dict:update(Addr, RemoveFun, SizeDict)}
    end.

fetch_all(Addrs, MsgIdFun2, Enc, MsgDict, SizeDict) ->
    fetch_all(Addrs, MsgIdFun2, Enc, MsgDict, SizeDict, []).

fetch_all([], _MsgIdFun2, _Enc, _MsgDict, _SizeDict, Acc) ->
    lists:reverse(Acc);
fetch_all([Addr|Addrs], MsgIdFun2, Enc, MsgDict, SizeDict, Acc) ->
   {MsgId, Msg, MsgDict2, SizeDict2} =
        fetch_one(Addr, MsgIdFun2, Enc, MsgDict, SizeDict),
   Acc2 = [{MsgId, Msg} | Acc],
   fetch_all(Addrs, MsgIdFun2, Enc, MsgDict2, SizeDict2, Acc2).
