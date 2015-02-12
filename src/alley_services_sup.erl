-module(alley_services_sup).

-behaviour(supervisor).

%% API
-export([
    start_link/0
]).

%% supervisor callbacks
-export([init/1]).

-include_lib("alley_common/include/supervisor_spec.hrl").

-define(CHILD(I, Restart, Timeout, Type), {I, {I, start_link, []}, Restart, Timeout, Type, [I]}).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{one_for_one, 5, 10}, [
        ?CHILD(alley_services_pdu_logger_sup, permanent, infinity, supervisor),
        ?CHILD(alley_services_http_in_logger, permanent, 5000, worker),
        ?CHILD(alley_services_http_out_logger, permanent, 5000, worker),
        ?CHILD(alley_services_auth_cache, permanent, 5000, worker),
        ?CHILD(alley_services_auth, permanent, 5000, worker),
        ?CHILD(alley_services_api, permanent, 5000, worker),
        ?CHILD(alley_services_blacklist, permanent, 5000, worker),
        ?CHILD(alley_services_events, permanent, 5000, worker),
        ?CHILD(alley_services_defer, permanent, 5000, worker),
        %%?CHILD(alley_services_mo, permanent, 5000, worker),
        ?CHILD(alley_services_mt, permanent, 5000, worker),
        ?CHILD(alley_services_mt_many, permanent, 5000, worker)
    ]}}.
