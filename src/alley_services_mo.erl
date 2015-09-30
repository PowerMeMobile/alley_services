-module(alley_services_mo).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0
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

-record(state, {
    chan            :: pid(),
    chan_mon_ref    :: reference()
}).

-record(req, {
    chan :: pid(),
    payload :: binary(),
    reply_to :: binary(),
    message_id :: binary(),
    ct :: binary(),
    dto :: #incoming_sms_notification_v1{}
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, IncomingQueue} = application:get_env(?APP, incoming_sms_queue),
    case rmql:channel_open() of
        {ok, Chan} ->
            MonRef = erlang:monitor(process, Chan),
            ok = rmql:queue_declare(Chan, IncomingQueue, []),
            NoAck = true,
            {ok, _ConsumerTag} = rmql:basic_consume(Chan, IncomingQueue, NoAck),
            ?log_info("MO: started", []),
            {ok, #state{chan = Chan, chan_mon_ref = MonRef}};
        unavailable ->
            ?log_info("Mo: initializing failed (amqp_unavailable). shutdown", []),
            {stop, amqp_unavailable}
    end.

handle_call(_Request, _From, State) ->
    {stop, unexpected_call, State}.

handle_cast(_Msg, State) ->
    {stop, unexpected_cast, State}.

handle_info(#'DOWN'{ref = Ref, info = Info}, St = #state{chan_mon_ref = Ref}) ->
    ?log_error("MO: amqp channel down (~p)", [Info]),
    {stop, amqp_channel_down, St};

handle_info({#'basic.deliver'{}, AMQPMsg = #amqp_msg{}}, St = #state{}) ->
    #'P_basic'{
        reply_to = ReplyTo,
        message_id = MsgID,
        content_type = ContentType
    } = AMQPMsg#amqp_msg.props,
    Req = #req{
        reply_to = ReplyTo,
        message_id = MsgID,
        ct = ContentType,
        payload = AMQPMsg#amqp_msg.payload,
        chan = St#state.chan
    },
    process(decode, Req),
    {noreply, St};

handle_info(_Info, State) ->
    {stop, unexpected_info, State}.

terminate(Reason, _St) ->
    ?log_info("MO: terminated (~p)", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================

process(decode, Req = #req{ct = <<"OutgoingBatch">>}) ->
    case adto:decode(#incoming_sms_notification_v1{}, Req#req.payload) of
        {ok, DTO} ->
            process(deliver, Req#req{dto = DTO});
        Error ->
            ?log_error("payload ~p unpack error ~p", [Req#req.payload, Error])
    end;
process(decode, Req) ->
    ?log_error("Got unexpected ct: ~p", [Req#req.ct]);

process(deliver, Req) ->
    DTO = Req#req.dto,
    ?log_info("Got InboundSms: ~p", [DTO]),
    #incoming_sms_notification_v1{
        dest_addr = DestAddr,
        message = Message,
        sender_addr = SenderAddr,
        notify_url  = Url
    } = DTO,

    Queries = [
        {'Sender', SenderAddr#addr.addr},
        {'Destination', DestAddr#addr.addr},
        {'MessageType', 1},
        {'MessageText', Message},
        {'MessageTextRaw', bin_to_hex(Message)},
        {'CurrentPart', 0},
        {'NumberOfParts', 0}
    ],
    FullUrl = binary_to_list(Url) ++  query_string(Queries),
    FlatReqURL = lists:flatten(FullUrl),
    case httpc:request(get, {FullUrl, []}, [{timeout, 10000}], []) of
        {ok, {{HTTPVer, 200, ReasonPhrase}, RespHeaders, RespBody}} ->
            ?log_debug("Delivered: ~p", [FlatReqURL]),
            alley_services_http_out_logger:log(FlatReqURL, HTTPVer, 200, ReasonPhrase, RespHeaders, RespBody),
            process(ack, Req);
        {ok, {{HTTPVer, RespCode, ReasonPhrase}, RespHeaders, RespBody}} ->
            ?log_debug("Srv respond ~p ~p", [RespCode, ReasonPhrase]),
            alley_services_http_out_logger:log(FlatReqURL, HTTPVer, RespCode, ReasonPhrase, RespHeaders, RespBody),
            ok;
        {error, {connect_failed, Reason}} ->
            ?log_debug("Connect failed:~nReq: ~p ->~n~p", [FlatReqURL, Reason]),
            alley_services_http_out_logger:log(FlatReqURL, connect_failed, Reason),
            ok;
        {error, {send_failed, Reason}} ->
            ?log_debug("Send failed:~nReq: ~p ->~n~p", [FlatReqURL, Reason]),
            alley_services_http_out_logger:log(FlatReqURL, send_failed, Reason),
            ok;
        {error, Reason} ->
            ?log_debug("Unexpected error:~nReq: ~p ->~n~p", [FlatReqURL, Reason]),
            alley_services_http_out_logger:log(FlatReqURL, unexpected, Reason)
    end;

process(ack, Req) ->
    ?log_info("ack", []),
    ReqDTO = Req#req.dto,
    ReqMsgID = ReqDTO#incoming_sms_notification_v1.message_id,
    DTO = #funnel_ack_dto{id = ReqMsgID},
    {ok, Encoded} = adto:encode(DTO),
    Props = [
        {content_type, <<"BatchAck">>},
        {correlation_id, Req#req.message_id},
        {message_id, uuid:unparse(uuid:generate_time())}
    ],
    rmql:basic_publish(Req#req.chan, Req#req.reply_to, Encoded, Props).

query_string([Head|Tail]) ->
    "?" ++ [make_query(Head) | [["&", make_query(Elem)] || Elem <- Tail]];
query_string([]) -> [].

make_query({Key, Value}) ->
    [url_encode(Key), "=", url_encode(Value)].

url_encode(Value) when is_atom(Value) ->
    url_encode(atom_to_list(Value));
url_encode(Value) when is_list(Value) ->
    http_uri:encode(Value);
url_encode(Value) when is_binary(Value) ->
    url_encode(binary_to_list(Value));
url_encode(Value) when is_integer(Value) ->
    integer_to_list(Value).

%% ===================================================================
%% BinToHex
%% ===================================================================

bin_to_hex(B) when is_binary(B) ->
  bin_to_hex(B, <<>>).

-define(H(X), (hex(X)):16).

bin_to_hex(<<>>, Acc) -> Acc;
bin_to_hex(Bin, Acc) when byte_size(Bin) band 7 =:= 0 ->
  bin_to_hex_(Bin, Acc);
bin_to_hex(<<X:8, Rest/binary>>, Acc) ->
  bin_to_hex(Rest, <<Acc/binary, ?H(X)>>).

bin_to_hex_(<<>>, Acc) -> Acc;
bin_to_hex_(<<A:8, B:8, C:8, D:8, E:8, F:8, G:8, H:8, Rest/binary>>, Acc) ->
  bin_to_hex_(
    Rest,
    <<Acc/binary,
      ?H(A), ?H(B), ?H(C), ?H(D), ?H(E), ?H(F), ?H(G), ?H(H)>>).

hex(X) ->
  element(
    X+1, {16#3030, 16#3031, 16#3032, 16#3033, 16#3034, 16#3035, 16#3036,
          16#3037, 16#3038, 16#3039, 16#3041, 16#3042, 16#3043, 16#3044,
          16#3045, 16#3046, 16#3130, 16#3131, 16#3132, 16#3133, 16#3134,
          16#3135, 16#3136, 16#3137, 16#3138, 16#3139, 16#3141, 16#3142,
          16#3143, 16#3144, 16#3145, 16#3146, 16#3230, 16#3231, 16#3232,
          16#3233, 16#3234, 16#3235, 16#3236, 16#3237, 16#3238, 16#3239,
          16#3241, 16#3242, 16#3243, 16#3244, 16#3245, 16#3246, 16#3330,
          16#3331, 16#3332, 16#3333, 16#3334, 16#3335, 16#3336, 16#3337,
          16#3338, 16#3339, 16#3341, 16#3342, 16#3343, 16#3344, 16#3345,
          16#3346, 16#3430, 16#3431, 16#3432, 16#3433, 16#3434, 16#3435,
          16#3436, 16#3437, 16#3438, 16#3439, 16#3441, 16#3442, 16#3443,
          16#3444, 16#3445, 16#3446, 16#3530, 16#3531, 16#3532, 16#3533,
          16#3534, 16#3535, 16#3536, 16#3537, 16#3538, 16#3539, 16#3541,
          16#3542, 16#3543, 16#3544, 16#3545, 16#3546, 16#3630, 16#3631,
          16#3632, 16#3633, 16#3634, 16#3635, 16#3636, 16#3637, 16#3638,
          16#3639, 16#3641, 16#3642, 16#3643, 16#3644, 16#3645, 16#3646,
          16#3730, 16#3731, 16#3732, 16#3733, 16#3734, 16#3735, 16#3736,
          16#3737, 16#3738, 16#3739, 16#3741, 16#3742, 16#3743, 16#3744,
          16#3745, 16#3746, 16#3830, 16#3831, 16#3832, 16#3833, 16#3834,
          16#3835, 16#3836, 16#3837, 16#3838, 16#3839, 16#3841, 16#3842,
          16#3843, 16#3844, 16#3845, 16#3846, 16#3930, 16#3931, 16#3932,
          16#3933, 16#3934, 16#3935, 16#3936, 16#3937, 16#3938, 16#3939,
          16#3941, 16#3942, 16#3943, 16#3944, 16#3945, 16#3946, 16#4130,
          16#4131, 16#4132, 16#4133, 16#4134, 16#4135, 16#4136, 16#4137,
          16#4138, 16#4139, 16#4141, 16#4142, 16#4143, 16#4144, 16#4145,
          16#4146, 16#4230, 16#4231, 16#4232, 16#4233, 16#4234, 16#4235,
          16#4236, 16#4237, 16#4238, 16#4239, 16#4241, 16#4242, 16#4243,
          16#4244, 16#4245, 16#4246, 16#4330, 16#4331, 16#4332, 16#4333,
          16#4334, 16#4335, 16#4336, 16#4337, 16#4338, 16#4339, 16#4341,
          16#4342, 16#4343, 16#4344, 16#4345, 16#4346, 16#4430, 16#4431,
          16#4432, 16#4433, 16#4434, 16#4435, 16#4436, 16#4437, 16#4438,
          16#4439, 16#4441, 16#4442, 16#4443, 16#4444, 16#4445, 16#4446,
          16#4530, 16#4531, 16#4532, 16#4533, 16#4534, 16#4535, 16#4536,
          16#4537, 16#4538, 16#4539, 16#4541, 16#4542, 16#4543, 16#4544,
          16#4545, 16#4546, 16#4630, 16#4631, 16#4632, 16#4633, 16#4634,
          16#4635, 16#4636, 16#4637, 16#4638, 16#4639, 16#4641, 16#4642,
          16#4643, 16#4644, 16#4645, 16#4646}).
