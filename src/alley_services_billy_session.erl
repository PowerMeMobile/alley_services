-module(alley_services_billy_session).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_session_id/0]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("alley_common/include/gen_server_spec.hrl").

-type session_id() :: binary().

-record(st, {
    session_id :: session_id()
}).

-define(RECONNECT_TIMEOUT, 10000).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_session_id() -> {ok, session_id()} | {error, term()}.
get_session_id() ->
    gen_server:call(?MODULE, get_session_id, infinity).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, Enabled} = application:get_env(billy_client, enabled),
    case Enabled of
        true ->
            {ok, Host} = application:get_env(billy_client, host),
            {ok, Port} = application:get_env(billy_client, port),
            {ok, Username} = application:get_env(billy_client, username),
            {ok, Password} = application:get_env(billy_client, password),
            case billy_client:start_session(Host, Port, Username, Password) of
                {ok, SessionId} ->
                    {ok, #st{session_id = SessionId}};
                {error, econnrefused} ->
                    {ok, #st{}, ?RECONNECT_TIMEOUT};
                {error, invalid_credentials} ->
                    {error, invalid_credentials}
            end;
        false ->
            gen_server:cast(?MODULE, stop),
            {ok, #st{}}
    end.

handle_call(get_session_id, _From, #st{session_id = undefined} = St) ->
    % return the error and timeout instantly.
    {reply, {error, no_session}, St, 0};

handle_call(get_session_id, _From, #st{session_id = SessionId} = St) ->
    {reply, {ok, SessionId}, St};

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast(stop, St) ->
    {stop, normal, St};

handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

handle_info(timeout, St) ->
    %?log_info("Billy session timeout. Trying to reconnect...", []),
    {stop, no_session, St};

handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

terminate(_Reason, #st{session_id = undefined}) ->
    ok;

terminate(_Reason, #st{session_id = SessionId}) ->
    billy_client:stop_session(SessionId).

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
