-module(alley_services_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-include("application.hrl").
-include("application_spec.hrl").

-record(state, {}).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    register(?MODULE, self()),
    alley_services_sup:start_link().

stop(_State = #state{}) ->
    ok.
