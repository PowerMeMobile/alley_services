-module(alley_services_defer).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    defer/3
]).

%% Service API
-export([
    fetch_all/0
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

-include_lib("stdlib/include/qlc.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-record(st, {}).

-define(TIMEOUT, (1000 * 60 * 1)).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec defer(term(), ac_datetime:timestamp(), term()) -> ok.
defer(Id, Timestamp, Req) ->
    gen_server:call(?MODULE, {defer, Id, Timestamp, Req}).

%% ===================================================================
%% Service API
%% ===================================================================

-spec fetch_all() -> [{term(), ac_datetime:timestamp(), term()}].
fetch_all() ->
    dets:foldl(fun(I, Acc) -> [I | Acc] end, [], ?MODULE).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, ?MODULE} = dets:open_file(?MODULE, [{file, "data/deferred_requests.dets"}]),
    ?log_info("Defer: started", []),
    {ok, #st{}, ?TIMEOUT}.

handle_call({defer, Id, Timestamp, Req}, _From, St) ->
    ok = dets:insert(?MODULE, {Id, Timestamp, Req}),
    {reply, ok, St, ?TIMEOUT};
handle_call(_Request, _From, St) ->
    {stop, unexpected_call, St}.

handle_cast(Req, St) ->
    {stop, {unexpected_cast, Req}, St}.

handle_info(timeout, St) ->
    Ts = ac_datetime:utc_timestamp(),
    DeferedTasks = qlc:e(qlc:q(
        [R || R <- dets:table(?MODULE), element(2, R) < Ts]
    )),
    [send(Task) || Task <- DeferedTasks],
    {noreply, St, ?TIMEOUT};
handle_info({'EXIT', _Pid, Reason}, St) ->
    {stop, Reason, St};
handle_info(_Info, St) ->
    {stop, unexpected_info, St}.

terminate(Reason, _St) ->
    dets:close(?MODULE),
    ?log_info("Defer: terminated (~p)", [Reason]).

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% ===================================================================
%% Internal
%% ===================================================================

send({Id, _Timestamp, Req}) ->
    ok = alley_services_mt:publish(Req),
    ok = dets:delete(?MODULE, Id).
