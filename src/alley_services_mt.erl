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
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-define(just_sms_request_param(Name, Param),
    apply(fun
        (undefined) ->
            [];
        (Str) when is_binary(Str) ; is_list(Str) ->
            {just_sms_request_param_dto, Name, {string, Str}};
        (Bool) when Bool =:= true ; Bool =:= false ->
            {just_sms_request_param_dto, Name, {boolean, Bool}};
        (Int) when is_integer(Int) ->
            {just_sms_request_param_dto, Name, {integer, Int}}
    end, [Param])).

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
    send(authenticate, Req).

-spec publish({publish_action(), payload(), req_id(), gateway_id()}) -> ok.
publish(Req) ->
    gen_server:call(?MODULE, Req).

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
        {content_type, <<"OneAPISmsRequest">>},
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

send(authenticate, Req) ->
    CustomerId = Req#send_req.customer_id,
    UserName = Req#send_req.user_name,
    ClientType = Req#send_req.client_type,
    Password = Req#send_req.password,
    case alley_services_auth:authenticate(CustomerId, UserName, ClientType, Password) of
        {ok, #k1api_auth_response_dto{result = {customer, Customer}}} ->
            Req2 = Req#send_req{customer = Customer},
            send(fill_coverage_tab, Req2);
        {ok, #k1api_auth_response_dto{result = {error, Error}}} ->
            {ok, [{result, Error}]};
        {error, timeout} ->
            {ok, [{result, ?authError}]}
    end;

send(fill_coverage_tab, Req) ->
    Customer = Req#send_req.customer,
    Networks = Customer#k1api_auth_response_customer_dto.networks,
    DefaultProviderId = Customer#k1api_auth_response_customer_dto.default_provider_id,
    CoverageTab = ets:new(coverage_tab, [private]),
    alley_services_coverage:fill_coverage_tab(Networks, DefaultProviderId, CoverageTab),
    send(parse_recipients, Req#send_req{coverage_tab = CoverageTab});

send(parse_recipients, Req) ->
    BlobRecipients = Req#send_req.recipients,
    RawRecipients = binary:split(BlobRecipients, <<",">>, [trim, global]),
    DestAddrs = [alley_services_utils:addr_to_dto(Addr) || Addr <- RawRecipients],
    send(parse_def_date, Req#send_req{recipients = DestAddrs});

send(parse_def_date, Req) ->
    DefDate = Req#send_req.def_date,
    case parse_def_date(DefDate) of
        {error, invalid} ->
            {ok, [{result, ?invalidDefDateFormatError}]};
        {ok, ParsedDefDate} ->
            send(check_originator, Req#send_req{def_date = ParsedDefDate})
    end;

send(check_originator, Req) ->
    Customer = Req#send_req.customer,
    Originator = alley_services_utils:addr_to_dto(Req#send_req.originator),
    AllowedSources = Customer#k1api_auth_response_customer_dto.allowed_sources,
    case lists:member(Originator, AllowedSources) of
        true ->
            send(check_blacklist, Req#send_req{originator = Originator});
        false ->
            {ok, [{result, ?originatorNotAllowedError}]}
    end;

send(check_blacklist, Req) ->
    DestAddrs  = Req#send_req.recipients,
    Originator = Req#send_req.originator,
    case alley_services_blacklist:filter(DestAddrs, Originator) of
        {[], _} ->
            {ok, [{result, ?noAnyDestAddrError}]};
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
            {ok, [{result, ?noAnyDestAddrError}]};
        {ProvId2Addrs, UnroutableToProviders} ->
            send(route_to_gateways, Req#send_req{
                routable = ProvId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToProviders
            })
    end;

send(route_to_gateways, Req) ->
    DestAddrs = Req#send_req.routable,
    Customer = Req#send_req.customer,
    Providers = Customer#k1api_auth_response_customer_dto.providers,
    case alley_services_coverage:route_addrs_to_gateways(DestAddrs, Providers) of
        {[], _} ->
            {ok, [{result, ?noAnyDestAddrError}]};
        {GtwId2Addrs, UnroutableToGateways} ->
            send(process_msg_type, Req#send_req{
                routable = GtwId2Addrs,
                rejected = Req#send_req.rejected ++ UnroutableToGateways
            })
    end;

send(process_msg_type, Req) when
        Req#send_req.text =:= undefined andalso
        Req#send_req.action =:= send_service_sms ->
    Text =
        <<"<%SERVICEMESSAGE:",
        (Req#send_req.s_name)/binary, ";",
        (Req#send_req.s_url)/binary, "%>">>,
    send(process_msg_type, Req#send_req{text = Text});

send(process_msg_type, Req) when
        Req#send_req.text =:= undefined andalso
        Req#send_req.action =:= send_binary_sms ->
    Text = ac_hexdump:hexdump_to_binary(Req#send_req.binary_body),
    send(define_smpp_params, Req#send_req{text = Text, encoding = default, encoded = <<" ">>});

send(process_msg_type, Req) ->
    Text = convert_numbers(Req#send_req.text, Req#send_req.type),
    send(define_text_encoding, Req#send_req{text = Text});

send(define_text_encoding, Req) ->
    {Encoding, Encoded} =
        case gsm0338:from_utf8(Req#send_req.text) of
            {valid, Binary} -> {default, Binary};
            {invalid, Binary} -> {ucs2, Binary}
        end,
    send(define_smpp_params, Req#send_req{encoding = Encoding, encoded = Encoded});

send(define_smpp_params, Req) when Req#send_req.action =:= send_service_sms ->
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#k1api_auth_response_customer_dto.receipts_allowed,
    NoRetry = Customer#k1api_auth_response_customer_dto.no_retry,
    DefaultValidity = Customer#k1api_auth_response_customer_dto.default_validity,
    Params = lists:flatten([
        ?just_sms_request_param(<<"registered_delivery">>, ReceiptsAllowed),
        ?just_sms_request_param(<<"service_type">>, <<>>),
        ?just_sms_request_param(<<"no_retry">>, NoRetry),
        ?just_sms_request_param(<<"validity_period">>, fmt_validity(DefaultValidity)),
        ?just_sms_request_param(<<"priority_flag">>, 0),
        ?just_sms_request_param(<<"esm_class">>, 64),
        ?just_sms_request_param(<<"protocol_id">>, 0),
        ?just_sms_request_param(<<"data_coding">>, 245),
        ?just_sms_request_param(<<"source_port">>, 9200),
        ?just_sms_request_param(<<"destination_port">>, 2948)
    ]),
    send(check_billing, Req#send_req{smpp_params = Params});

send(define_smpp_params, Req) when Req#send_req.action =:= send_binary_sms ->
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#k1api_auth_response_customer_dto.receipts_allowed,
    NoRetry = Customer#k1api_auth_response_customer_dto.no_retry,
    DefaultValidity = Customer#k1api_auth_response_customer_dto.default_validity,
    DC = maybe_binary_to_integer(Req#send_req.data_coding),
    ESMClass = maybe_binary_to_integer(Req#send_req.esm_class),
    ProtocolId = maybe_binary_to_integer(Req#send_req.protocol_id),
    Params = lists:flatten([
        ?just_sms_request_param(<<"registered_delivery">>, ReceiptsAllowed),
        ?just_sms_request_param(<<"service_type">>, <<>>),
        ?just_sms_request_param(<<"no_retry">>, NoRetry),
        ?just_sms_request_param(<<"validity_period">>, fmt_validity(DefaultValidity)),
        ?just_sms_request_param(<<"priority_flag">>, 0),
        ?just_sms_request_param(<<"data_coding">>, DC),
        ?just_sms_request_param(<<"esm_class">>, ESMClass),
        ?just_sms_request_param(<<"protocol_id">>, ProtocolId)
     ]),
    send(check_billing, Req#send_req{smpp_params = Params});

send(define_smpp_params, Req) ->
    Encoding = Req#send_req.encoding,
    Customer = Req#send_req.customer,
    ReceiptsAllowed = Customer#k1api_auth_response_customer_dto.receipts_allowed,
    NoRetry = Customer#k1api_auth_response_customer_dto.no_retry,
    DefaultValidity = Customer#k1api_auth_response_customer_dto.default_validity,
    Params = lists:flatten([
        ?just_sms_request_param(<<"registered_delivery">>, ReceiptsAllowed),
        ?just_sms_request_param(<<"service_type">>, <<>>),
        ?just_sms_request_param(<<"no_retry">>, NoRetry),
        ?just_sms_request_param(<<"validity_period">>, fmt_validity(DefaultValidity)),
        ?just_sms_request_param(<<"priority_flag">>, 0),
        ?just_sms_request_param(<<"esm_class">>, 3),
        ?just_sms_request_param(<<"protocol_id">>, 0)
    ]) ++ flash(Req#send_req.flash, Encoding),
    send(check_billing, Req#send_req{smpp_params = Params});

send(check_billing, Req) ->
    Price = calc_sending_price(Req),
    ?log_debug("Sending price: ~p", [Price]),

    CustomerId = Req#send_req.customer_id,
    Customer = Req#send_req.customer,

    PayType = Customer#k1api_auth_response_customer_dto.pay_type,
    case PayType of
        postpaid ->
            ?log_debug("Postpaid customer: request credit", []),
            case alley_services_api:request_credit(CustomerId, Price) of
                {allowed, CreditLeft} ->
                    ?log_debug("Sending allowed. CustomerId: ~p, credit left: ~p",
                        [CustomerId, CreditLeft]),
                    send(build_req_dto_s, Req);
                {denied, CreditLeft} ->
                    ?log_error("Sending denied. CustomerId: ~p, credit left: ~p",
                        [CustomerId, CreditLeft]),
                    {ok, [{result, ?postpaidCreditLimitExceeded}]};
                {error, timeout} ->
                    {ok, [{result, ?serverUnreachable}]}
            end;
        prepaid ->
            ?log_debug("Prepaid customer: check billing", []),
            {ok, [{result, ?prepaidCreditLimitInsufficient}]}
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

    {ok, [{id, ReqId}, {rejected, Req#send_req.rejected}]}.

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
    [?just_sms_request_param(<<"data_coding">>, 240)];
flash(true, ucs2) ->
    [?just_sms_request_param(<<"data_coding">>, 248)].

build_req_dto(ReqId, GatewayId, DestAddrs, Req) ->
    Customer   = Req#send_req.customer,
    CustomerId = Customer#k1api_auth_response_customer_dto.uuid,
    UserId     = Req#send_req.user_name,
    Encoding   = Req#send_req.encoding,
    Encoded    = Req#send_req.encoded,
    NumberOfSymbols = size(Encoded),
    NumberOfDests = length(DestAddrs),
    NumberOfParts = alley_services_utils:calc_parts_number(NumberOfSymbols, Encoding),
    MessageIds = get_ids(CustomerId, UserId, NumberOfDests, NumberOfParts),

    #just_sms_request_dto{
        id = ReqId,
        gateway_id = GatewayId,
        customer_id = CustomerId,
        user_id = Req#send_req.user_name,
        client_type = Req#send_req.client_type,
        type = regular,
        message = Req#send_req.text,
        encoding = Encoding,
        params = Req#send_req.smpp_params,
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

parse_def_date(<<>>) ->
    {ok, undefined};
parse_def_date(undefined) ->
    {ok, undefined};
parse_def_date(DefDateList) when is_list(DefDateList) ->
    try [binary_to_integer(D) || D <- DefDateList] of
        [Month, Day, Year, Hour, Min] ->
            DateTime = {{Year, Month, Day}, {Hour, Min, 0}},
            RefDate = ac_datetime:datetime_to_timestamp(DateTime),
            case RefDate > ac_datetime:utc_timestamp() of
                true ->
                    {ok, RefDate};
                false ->
                    {error, invalid}
            end
    catch
        _:_ ->
            {error, invalid}
    end;
parse_def_date(DefDate) when is_binary(DefDate) ->
    case binary:split(DefDate, [<<"/">>, <<" ">>, <<":">>], [global]) of
        [_M, _D, _Y, _H, _Min] = DefDateList ->
            parse_def_date(DefDateList);
        _ ->
            {error, invalid}
    end.

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

    Networks = Customer#k1api_auth_response_customer_dto.networks,
    Providers = Customer#k1api_auth_response_customer_dto.providers,
    DefaultProviderId = Customer#k1api_auth_response_customer_dto.default_provider_id,
    NetworkId2SmsPrice = alley_services_coverage:build_network_to_sms_price_map(
        Networks, Providers, DefaultProviderId),

    Encoding = Req#send_req.encoding,
    Encoded = Req#send_req.encoded,
    NumberOfSymbols = size(Encoded),
    NumberOfParts = alley_services_utils:calc_parts_number(NumberOfSymbols, Encoding),

    alley_services_coverage:calc_sending_price(
        NetworkId2Addrs, NetworkId2SmsPrice, NumberOfParts).

maybe_binary_to_integer(undefined) ->
    0;
maybe_binary_to_integer(Binary) ->
    binary_to_integer(Binary).
