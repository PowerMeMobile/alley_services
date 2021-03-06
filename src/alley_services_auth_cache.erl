-module(alley_services_auth_cache).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API exports
-export([
    start_link/0,

    store/5,

    fetch/4,

    delete/1,
    delete/2,
    delete/3,
    delete/4
]).

%% Service API
-export([
    fetch_all/0
]).

%% gen_server exports
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-type customer_id() :: string() | binary().
-type user_id()     :: string() | binary().
-type password()    :: string() | binary().
-type type()        :: atom().

-record(st, {}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec store(customer_id(), user_id(), type(), password(), tuple()) -> ok.
store(CustomerId, UserId, Type, Password, AuthResp) ->
    Key = {CustomerId, UserId, Type, Password},
    gen_server:cast(?MODULE, {store, Key, AuthResp}).

-spec fetch(customer_id(), user_id(), type(), password()) ->
    {ok, tuple()} | not_found.
fetch(CustomerId, UserId, Type, Password) ->
    Key = {CustomerId, UserId, Type, Password},
    case dets:lookup(?MODULE, Key) of
        [] ->
            not_found;
        [{Key, Value}] ->
            {ok, Value}
    end.

-spec delete(customer_id()) -> ok.
delete(CustomerId) ->
    delete(CustomerId, '_').

-spec delete(customer_id(), user_id() | '_') -> ok.
delete(CustomerId, UserId) ->
    delete(CustomerId, UserId, '_').

-spec delete(customer_id(), user_id() | '_', type() | '_') -> ok.
delete(CustomerId, UserId, Type) ->
    delete(CustomerId, UserId, Type, '_').

-spec delete(customer_id(), user_id() | '_', type() | '_', password() | '_') -> ok.
delete(CustomerId, UserId, Type, Password) ->
    gen_server:cast(?MODULE, {delete, {{CustomerId, UserId, Type, Password}, '_'}}).

%% ===================================================================
%% Service API
%% ===================================================================

-spec fetch_all() -> [{{customer_id(), user_id(), type()}, tuple()}].
fetch_all() ->
    dets:foldl(fun(I, Acc) -> [I | Acc] end, [], ?MODULE).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    DetsOpts = [{ram_file, true}, {file, "data/auth_cache.dets"}],
    {ok, ?MODULE} = dets:open_file(?MODULE, DetsOpts),
    ok = dets:sync(?MODULE),
    ?log_info("Auth cache: started", []),
    {ok, #st{}}.

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

handle_cast({store, Key, Value}, St) ->
    ok = dets:insert(?MODULE, {Key, Value}),
    ok = dets:sync(?MODULE),
    {noreply, St};

handle_cast({delete, Pattern}, St) ->
    ok = dets:match_delete(?MODULE, Pattern),
    ok = dets:sync(?MODULE),
    {noreply, St};

handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

handle_info({'EXIT', _Pid, Reason}, St) ->
    {stop, Reason, St};
handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

terminate(Reason, _St) ->
    dets:close(?MODULE),
    ?log_info("Auth cache: terminated (~p)", [Reason]).
