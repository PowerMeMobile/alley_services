-module(alley_services_auth).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    authenticate/4
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

-spec authenticate(binary(), binary(), atom(), binary()) ->
    {ok, #k1api_auth_response_dto{}} |
    {error, timeout}.
authenticate(CustomerId, UserId, Type, Password) ->
    case request_backend(CustomerId, UserId, Type, Password) of
        {ok, AuthResp = #k1api_auth_response_dto{result = Result}} ->
            case Result of
                {customer, _} ->
                    ok = alley_services_auth_cache:store(
                        CustomerId, UserId, Type, Password, AuthResp);
                {error, _} ->
                    ok
            end,
            {ok, AuthResp};
        {error, timeout} ->
            ?log_debug("Trying auth cache...", []),
            case alley_services_auth_cache:fetch(
                    CustomerId, UserId, Type, Password) of
                {ok, AuthResp} ->
                    ?log_debug("Found auth response: ~p", [AuthResp]),
                    {ok, AuthResp};
                not_found ->
                    ?log_error("Not found auth response. "
                               "Return backend_unavailable", []),
                    {error, timeout}
            end
    end.

%% ===================================================================
%% Internal
%% ===================================================================

request_backend(CustomerId, UserId, Type, Password) ->
    ReqId = uuid:unparse(uuid:generate_time()),
    AuthReq = #k1api_auth_request_dto{
        id = ReqId,
        customer_id = CustomerId,
        user_id = UserId,
        password = Password,
        connection_type = Type
    },
    ?log_debug("Sending auth request: ~p", [AuthReq]),
    {ok, Payload} = adto:encode(AuthReq),
    case rmql_rpc_client:call(?MODULE, Payload, <<"OneAPIAuthReq">>) of
        {ok, Bin} ->
            case adto:decode(#k1api_auth_response_dto{}, Bin) of
                {ok, AuthResp} ->
                    ?log_debug("Got auth response: ~p", [AuthResp]),
                    {ok, AuthResp};
                {error, Error} ->
                    ?log_error("Auth response decode error: ~p", [Error]),
                    {error, Error}
            end;
        {error, timeout} ->
            ?log_error("Got auth response: timeout", []),
            {error, timeout}
    end.
