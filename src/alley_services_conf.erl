-module(alley_services_conf).

-compile({no_auto_import, [get/1]}).

%-export([init/0, get/1, set/2]).
-export([
    get/1
]).

%% ===================================================================
%% API
%% ===================================================================

-spec get(atom()) -> term().
get(Key) ->
    default(Key).

%% ===================================================================
%% Internal
%% ===================================================================

default(strip_leading_zero)    -> false;
default(country_code)          -> <<"999">>;
default(bulk_threshold)        -> 100.
