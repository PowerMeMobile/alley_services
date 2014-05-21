-module(alley_services_blacklist).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    check/2,
    filter/2,
    update/0
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

-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-record(st, {
    timer_ref :: reference()
}).

-define(BLACKLIST_FILE, "data/blacklist.ets").
-define(TIMEOUT, (1000 * 5)).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec check(addr(), addr()) -> allowed | denied.
check(DstAddr, SrcAddr) ->
    check(DstAddr, SrcAddr, ?MODULE).

-spec filter([addr()], addr()) -> {[addr()], [addr()]}.
filter(DstAddrs, SrcAddr) ->
    filter(DstAddrs, SrcAddr, [], []).

-spec update() -> ok.
update() ->
    gen_server:call(?MODULE, update).

%% ===================================================================
%% Service API
%% ===================================================================

-spec fetch_all() -> [{addr(), addr() | undefined}].
fetch_all() ->
    ets:tab2list(?MODULE).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    case ets:file2tab(?BLACKLIST_FILE, [{verify, true}]) of
        {ok, ?MODULE} ->
            nop;
        {error, _Whatever} ->
            ?MODULE = ets:new(?MODULE, [bag, named_table, {read_concurrency, true}])
    end,
    TimerRef = erlang:start_timer(0, self(), fill_blacklist),
    ?log_info("Blacklist: started", []),
    {ok, #st{timer_ref = TimerRef}}.

handle_call(update, _From, St = #st{timer_ref = undefined}) ->
    %% force update and return result.
    Res = fill_blacklist(?MODULE),
    {reply, Res, St};
handle_call(update, _From, St) ->
    %% simply return ok, as we know that we need to update.
    {reply, ok, St};
handle_call(_Request, _From, St) ->
    {stop, unexpected_call, St}.

handle_cast(fill, St) ->
    {noreply, St};
handle_cast(Req, St) ->
    {stop, {unexpected_cast, Req}, St}.

handle_info({timeout, TimerRef, fill_blacklist}, St = #st{timer_ref = TimerRef}) ->
    case fill_blacklist(?MODULE) of
        ok ->
            {noreply, St#st{timer_ref = undefined}};
        {error, Reason} ->
            ?log_error("Fill blacklist failed with: ~p", [Reason]),
            ?log_debug("Try to fill blacklist in ~p ms", [?TIMEOUT]),
            TimerRef2 = erlang:start_timer(?TIMEOUT, self(), fill_blacklist),
            {noreply, St#st{timer_ref = TimerRef2}}
    end;
handle_info({'EXIT', _Pid, Reason}, St) ->
    {stop, Reason, St};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(Reason, _St) ->
    ?log_info("Blacklist: terminated (~p)", [Reason]),
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% ===================================================================
%% Internal
%% ===================================================================

fill_blacklist(Tab) ->
    case alley_services_api:get_blacklist() of
        {ok, #k1api_blacklist_response_dto{entries = Entries}} ->
            true = ets:delete_all_objects(Tab),
            ok = fill_entries_to_tab(Entries, Tab),
            ets:tab2file(Tab, ?BLACKLIST_FILE, [{extended_info, [object_count]}]);
        Error ->
            Error
    end.

fill_entries_to_tab([E | Es], Tab) ->
    DstAddr = E#blacklist_entry_dto.dst_addr,
    SrcAddr = E#blacklist_entry_dto.src_addr,
    true = ets:insert(Tab, {DstAddr, SrcAddr}),
    fill_entries_to_tab(Es, Tab);
fill_entries_to_tab([], _Tab) ->
    ok.

check(DstAddr, SrcAddr, Tab) ->
    case ets:lookup(Tab, DstAddr) of
        [] ->
            allowed;
        [{DstAddr, undefined}] ->
            denied;
        Entries ->
            case lists:member({DstAddr, SrcAddr}, Entries) of
                true ->
                    denied;
                false ->
                    allowed
            end
    end.

filter([DstAddr | DstAddrs], SrcAddr, Allowed, Denied) ->
    case check(DstAddr, SrcAddr) of
        allowed ->
            filter(DstAddrs, SrcAddr, [DstAddr | Allowed], Denied);
        denied ->
            filter(DstAddrs, SrcAddr, Allowed, [DstAddr | Denied])
    end;
filter([], _SrcAddr, Allowed, Denied) ->
    {Allowed, Denied}.
