-module(alley_services_auth).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    authenticate/4,
    authenticate_by_email/2,
    authenticate_by_msisdn/2
]).

-include("application.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, QueueName} = application:get_env(?APP, kelly_auth_queue),
    rmql_rpc_client:start_link(?MODULE, QueueName).

-spec authenticate(binary(), binary(), binary(), atom()) ->
    {ok, #auth_resp_v2{}} | {error, timeout}.
authenticate(CustomerId, UserId, Password, Interface) ->
    AuthData = #auth_credentials{
        customer_id = CustomerId,
        user_id = UserId,
        password = Password
    },
    case request_backend(AuthData, Interface) of
        {ok, AuthResp = #auth_resp_v2{}} ->
            {ok, AuthResp};
        {error, timeout} ->
            {error, timeout}
    end.

-spec authenticate_by_email(binary(), atom()) ->
    {ok, #auth_resp_v2{}} | {error, timeout}.
authenticate_by_email(Email, Interface) ->
    AuthData = #auth_email{
        email = Email
    },
    case request_backend(AuthData, Interface) of
        {ok, AuthResp = #auth_resp_v2{}} ->
            {ok, AuthResp};
        {error, timeout} ->
            {error, timeout}
    end.

-spec authenticate_by_msisdn(#addr{}, atom()) ->
    {ok, #auth_resp_v2{}} | {error, timeout}.
authenticate_by_msisdn(Msisdn, Interface) ->
    AuthData = #auth_msisdn{
        msisdn = Msisdn
    },
    case request_backend(AuthData, Interface) of
        {ok, AuthResp = #auth_resp_v2{}} ->
            {ok, AuthResp};
        {error, timeout} ->
            {error, timeout}
    end.

%% ===================================================================
%% Internal
%% ===================================================================

request_backend(AuthData, Interface) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    Req = #auth_req_v2{
        req_id = ReqId,
        auth_data = AuthData,
        interface = Interface
    },
    ?log_debug("Sending auth request: ~p", [Req]),
    {ok, ReqBin} = adto:encode(Req),
    {ok, Timeout} = application:get_env(?APP, kelly_auth_rpc_timeout),
    case rmql_rpc_client:call(?MODULE, <<"AuthReqV2">>, ReqBin, Timeout) of
        {ok, <<"AuthRespV2">>, RespBin} ->
            case adto:decode(#auth_resp_v2{}, RespBin) of
                {ok, Resp} ->
                    ?log_debug("Got auth response: ~p", [Resp]),
                    {ok, Resp};
                {error, Error} ->
                    ?log_error("Auth response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Got auth response: timeout", []),
            {error, timeout}
    end.
