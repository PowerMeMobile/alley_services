-module(alley_services_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/0
]).

%% supervisor callbacks
-export([init/1]).

-include_lib("alley_common/include/supervisor_spec.hrl").

-define(CHILD(I, Timeout, Type), {I, {I, start_link, []}, permanent, Timeout, Type, [I]}).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{one_for_one, 5, 10}, [
        ?CHILD(alley_services_auth_cache, 5000, worker),
        ?CHILD(alley_services_auth, 5000, worker),
        ?CHILD(alley_services_api, 5000, worker),
        ?CHILD(alley_services_blacklist, 5000, worker)
    ]}}.
