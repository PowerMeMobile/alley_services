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
            ?log_info("MT: started", []),
            {ok, St};
        unavailable ->
            ?log_error("MT: initializing failed (amqp_unavailable). shutdown", []),
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
        {content_type, <<"SmsRequest">>},
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
    ?log_error("MT: amqp channel down (~p)", [Info]),
    {stop, amqp_channel_down, St};

handle_info(Confirm, St) when is_record(Confirm, 'basic.ack');
                              is_record(Confirm, 'basic.nack') ->
    handle_confirm(Confirm),
    {noreply, St};

handle_info(_Info, St) ->
    {stop, unexpected_info, St}.

terminate(Reason, _St) ->
    ?log_info("MT: terminated (~p)", [Reason]),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% ===================================================================
%% Send steps
%% ===================================================================

send(fill_coverage_tab, Req) ->
    Customer = Req#send_req.customer,
    Networks = Customer#auth_customer_v1.networks,
    DefaultProviderId = Customer#auth_customer_v1.default_provider_id,
    CoverageTab = ets:new(coverage_tab, [private]),
    alley_services_coverage:fill_coverage_tab(Networks, DefaultProviderId, CoverageTab),
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
    DestAddrs = Req#send_req.routable,
    Customer = Req#send_req.customer,
    Providers = Customer#auth_customer_v1.providers,
    case alley_services_coverage:route_addrs_to_gateways(DestAddrs, Providers) of
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
        Req#send_req.text =:= undefined andalso
        Req#send_req.action =:= send_sms ->
    {ok, #send_result{result = no_message_body}};

send(process_msg_type, Req) when
        Req#send_req.text =:= undefined andalso
        Req#send_req.action =:= send_service_sms ->
    Name = Req#send_req.s_name,
    Url = Req#send_req.s_url,
    case is_binary(Name) andalso is_binary(Url) of
        true ->
            Text = <<"<%SERVICEMESSAGE:", Name/binary, ";", Url/binary, "%>">>,
            send(process_msg_type, Req#send_req{text = Text});
        false ->
            {ok, #send_result{result = bad_service_name_or_url}}
    end;

%% FIXME: move this logic to clients
send(process_msg_type, Req) when
        Req#send_req.text =:= undefined andalso
        Req#send_req.binary_body =:= undefined andalso
        Req#send_req.action =:= send_binary_sms ->
    {ok, #send_result{result = no_message_body}};

send(process_msg_type, Req) when
        Req#send_req.text =:= undefined andalso
        Req#send_req.action =:= send_binary_sms ->
    Text = ac_hexdump:hexdump_to_binary(Req#send_req.binary_body),
    send(define_smpp_params, Req#send_req{
        text = Text,
        encoding = default,
        encoded = <<" ">>
    });

send(process_msg_type, Req) ->
    Text = convert_numbers(Req#send_req.text, Req#send_req.type),
    send(define_text_encoding, Req#send_req{text = Text});

send(define_text_encoding, Req) ->
    {Encoding, Encoded} =
        case gsm0338:from_utf8(Req#send_req.text) of
            {valid, Binary} -> {default, Binary};
            {invalid, Binary} -> {ucs2, Binary}
        end,
    send(define_smpp_params, Req#send_req{
        encoding = Encoding,
        encoded = Encoded
    });

send(define_smpp_params, Req) when Req#send_req.action =:= send_service_sms ->
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#auth_customer_v1.receipts_allowed,
    NoRetry = Customer#auth_customer_v1.no_retry,
    DefaultValidity = Customer#auth_customer_v1.default_validity,
    Params = Req#send_req.smpp_params ++ [
        {<<"registered_delivery">>, ReceiptsAllowed},
        {<<"service_type">>, <<>>},
        {<<"no_retry">>, NoRetry},
        {<<"validity_period">>, fmt_validity(DefaultValidity)},
        {<<"priority_flag">>, 0},
        {<<"esm_class">>, 64},
        {<<"protocol_id">>, 0},
        {<<"data_coding">>, 245},
        {<<"source_port">>, 9200},
        {<<"destination_port">>, 2948}
    ],
    send(check_billing, Req#send_req{smpp_params = Params});

send(define_smpp_params, Req) when Req#send_req.action =:= send_binary_sms ->
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#auth_customer_v1.receipts_allowed,
    NoRetry = Customer#auth_customer_v1.no_retry,
    DefaultValidity = Customer#auth_customer_v1.default_validity,
    DC = maybe_binary_to_integer(Req#send_req.data_coding),
    ESMClass = maybe_binary_to_integer(Req#send_req.esm_class),
    ProtocolId = maybe_binary_to_integer(Req#send_req.protocol_id),
    Params = Req#send_req.smpp_params ++ [
        {<<"registered_delivery">>, ReceiptsAllowed},
        {<<"service_type">>, <<>>},
        {<<"no_retry">>, NoRetry},
        {<<"validity_period">>, fmt_validity(DefaultValidity)},
        {<<"priority_flag">>, 0},
        {<<"data_coding">>, DC},
        {<<"esm_class">>, ESMClass},
        {<<"protocol_id">>, ProtocolId}
    ],
    send(check_billing, Req#send_req{smpp_params = Params});

send(define_smpp_params, Req) ->
    Encoding = Req#send_req.encoding,
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#auth_customer_v1.receipts_allowed,
    NoRetry = Customer#auth_customer_v1.no_retry,
    DefaultValidity = Customer#auth_customer_v1.default_validity,
    Params = Req#send_req.smpp_params ++ flash(Req#send_req.flash, Encoding) ++ [
        {<<"registered_delivery">>, ReceiptsAllowed},
        {<<"service_type">>, <<>>},
        {<<"no_retry">>, NoRetry},
        {<<"validity_period">>, fmt_validity(DefaultValidity)},
        {<<"priority_flag">>, 0},
        {<<"esm_class">>, 3},
        {<<"protocol_id">>, 0}
    ],
    send(check_billing, Req#send_req{smpp_params = Params});

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
    ReqDTOs = [
        build_req_dto(ReqId, GtwId, DestAddrs, Req) || {GtwId, DestAddrs} <- Destinations
    ],
    send(publish_dto_s, Req#send_req{req_dto_s = ReqDTOs});

send(publish_dto_s, Req) ->
    DefDate = Req#send_req.def_date,
    PublishFun =
        case is_deferred(DefDate) of
            {true, Timestamp} ->
                fun(ReqDTO) ->
                    ?log_info("mt_srv: defDate -> ~p, timestamp -> ~p", [DefDate, Timestamp]),
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#just_sms_request_dto.id,
                    GtwId = ReqDTO#just_sms_request_dto.gateway_id,
                    ok = alley_services_defer:defer({ReqId, GtwId}, Timestamp,
                        {publish_just, Payload, ReqId, GtwId}),
                    ok = publish({publish_kelly, Payload, ReqId, GtwId})
                end;
            false ->
                fun(ReqDTO) ->
                    {ok, Payload} = adto:encode(ReqDTO),
                    ReqId = ReqDTO#just_sms_request_dto.id,
                    GtwId = ReqDTO#just_sms_request_dto.gateway_id,
                    ok = publish({publish, Payload, ReqId, GtwId})
                end
        end,

    ReqDTOs = Req#send_req.req_dto_s,
    ReqId = (hd(ReqDTOs))#just_sms_request_dto.id,

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

flash(false, _) ->
    [];
flash(true, default) ->
    [{<<"data_coding">>, 240}];
flash(true, ucs2) ->
    [{<<"data_coding">>, 248}].

build_req_dto(ReqId, GatewayId, DestAddrs, Req) ->
    CustomerId = Req#send_req.customer_id,
    UserId     = Req#send_req.user_id,
    Encoding   = Req#send_req.encoding,
    Encoded    = Req#send_req.encoded,
    NumberOfSymbols = size(Encoded),
    NumberOfDests = length(DestAddrs),
    NumberOfParts = alley_services_utils:calc_parts_number(NumberOfSymbols, Encoding),
    MessageIds = get_ids(CustomerId, UserId, NumberOfDests, NumberOfParts),
    Params = wrap_params(Req#send_req.smpp_params),

    #just_sms_request_dto{
        id = ReqId,
        gateway_id = GatewayId,
        customer_id = CustomerId,
        user_id = UserId,
        client_type = Req#send_req.client_type,
        type = regular,
        message = Req#send_req.text,
        encoding = Encoding,
        params = Params,
        source_addr = Req#send_req.originator,
        dest_addrs = {regular, DestAddrs},
        message_ids = MessageIds
    }.

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

wrap_params(Params) ->
    Tag = fun
        (Str) when is_binary(Str) ->
            {string, Str};
        (Bool) when is_boolean(Bool) ->
            {boolean, Bool};
        (Int) when is_integer(Int) ->
            {integer, Int}
    end,
    [#just_sms_request_param_dto{name = N, value = Tag(V)} || {N, V} <- Params].

fmt_validity(SecondsTotal) ->
    MinutesTotal = SecondsTotal div 60,
    HoursTotal = MinutesTotal div 60,
    DaysTotal = HoursTotal div 24,
    MonthsTotal = DaysTotal div 30,
    Years = MonthsTotal div 12,
    Seconds = SecondsTotal rem 60,
    Minutes = MinutesTotal rem 60,
    Hours = HoursTotal rem 24,
    Days = DaysTotal rem 30,
    Months = MonthsTotal rem 12,
    StringValidity =
        lists:flatten(io_lib:format("~2..0w~2..0w~2..0w~2..0w~2..0w~2..0w000R",
                  [Years, Months, Days, Hours, Minutes, Seconds])),
    list_to_binary(StringValidity).

convert_numbers(Text, <<"ArabicWithArabicNumbers">>) ->
    case unicode:characters_to_list(Text, utf8) of
        CodePoints when is_list(CodePoints) ->
            ConvCP = [number_to_arabic(CP) || CP <- CodePoints],
            unicode:characters_to_binary(ConvCP, utf8);
        {error, CodePoints, RestData} ->
            ?log_error("mt_srv: Arabic numbers to hindi error. Original: ~w Codepoints: ~w Rest: ~w",
                [Text, CodePoints, RestData]),
            erlang:error("Illegal utf8 symbols");
        {incomplete, CodePoints, IncompleteSeq} ->
            ?log_error("mt_srv: Incomplete utf8 sequence. Original: ~w Codepoints: ~w IncompleteSeq: ~w",
                [Text, CodePoints, IncompleteSeq]),
            erlang:error("Incomplite utf8 sequence")
    end;
convert_numbers(Text, _) ->
    Text.

number_to_arabic(16#0030) -> 16#0660;
number_to_arabic(16#0031) -> 16#0661;
number_to_arabic(16#0032) -> 16#0662;
number_to_arabic(16#0033) -> 16#0663;
number_to_arabic(16#0034) -> 16#0664;
number_to_arabic(16#0035) -> 16#0665;
number_to_arabic(16#0036) -> 16#0666;
number_to_arabic(16#0037) -> 16#0667;
number_to_arabic(16#0038) -> 16#0668;
number_to_arabic(16#0039) -> 16#0669;
number_to_arabic(Any) -> Any.

is_deferred(undefined) ->
    false;
is_deferred(DefDate) ->
    {true, DefDate}.

calc_sending_price(Req) ->
    Customer = Req#send_req.customer,

    CoverageTab = Req#send_req.coverage_tab,
    GtwId2Addrs = Req#send_req.routable,
    DestAddrs = lists:flatten([Addr || {_GtwId, Addr} <- GtwId2Addrs]),
    {NetworkId2Addrs, []} =
        alley_services_coverage:route_addrs_to_networks(DestAddrs, CoverageTab),

    Networks = Customer#auth_customer_v1.networks,
    Providers = Customer#auth_customer_v1.providers,
    DefaultProviderId = Customer#auth_customer_v1.default_provider_id,
    NetworkId2SmsPrice = alley_services_coverage:build_network_to_sms_price_map(
        Networks, Providers, DefaultProviderId),

    Encoding = Req#send_req.encoding,
    Encoded = Req#send_req.encoded,
    NumberOfSymbols = size(Encoded),
    NumberOfParts = alley_services_utils:calc_parts_number(NumberOfSymbols, Encoding),

    alley_services_coverage:calc_sending_price(
        NetworkId2Addrs, NetworkId2SmsPrice, NumberOfParts).

%% FIXME: move this logic to clients
maybe_binary_to_integer(undefined) ->
    0;
maybe_binary_to_integer(<<>>) ->
    0;
maybe_binary_to_integer(Binary) ->
    binary_to_integer(Binary).
