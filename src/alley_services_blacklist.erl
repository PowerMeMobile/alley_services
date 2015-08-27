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

%-define(TEST, 1).
-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

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
        {ok, #blacklist_resp_v1{entries = Entries}} ->
            true = ets:delete_all_objects(Tab),
            ok = fill_entries_to_tab(Entries, Tab),
            ets:tab2file(Tab, ?BLACKLIST_FILE, [{extended_info, [object_count]}]);
        Error ->
            Error
    end.

fill_entries_to_tab([E | Es], Tab) ->
    DstAddr = E#blacklist_entry_v1.dst_addr,
    SrcAddr = E#blacklist_entry_v1.src_addr,
    true = ets:insert(Tab, {DstAddr, SrcAddr}),
    fill_entries_to_tab(Es, Tab);
fill_entries_to_tab([], _Tab) ->
    ok.

check(DstAddr, SrcAddr, Tab) ->
    case ets:lookup(Tab, DstAddr) of
        [] ->
            allowed;
        Entries ->
            case lists:member({DstAddr, undefined}, Entries) of
                true ->
                    denied;
                false ->
                    case lists:member({DstAddr, SrcAddr}, Entries) of
                        true ->
                            denied;
                        false ->
                            allowed
                    end
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

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

get_blacklist() ->
    {ok, #blacklist_resp_v1{
        req_id = <<"b8312504-4cc8-11e5-9139-ae3a4af2dd4b">>,
        entries = [
            %% entry 1
            #blacklist_entry_v1{
                id = <<"0118e9da-be64-11e4-bdd1-ae3a4af2dd4b">>,
                dst_addr = #addr{addr = <<"375295555555">>, ton = 1, npi = 1},
                src_addr = #addr{addr = <<"491111111111">>, ton = 1, npi = 1}
            },
            %% entry 2
            #blacklist_entry_v1{
                id = <<"24a8a0a2-4ca8-11e5-ae57-ae3a4af2dd4b">>,
                dst_addr = #addr{addr = <<"375296666666">>, ton = 1, npi = 1},
                src_addr = #addr{addr = <<"or125">>, ton = 5, npi = 0}
            },
            %% entry 3
            #blacklist_entry_v1{
                id = <<"71d02610-4cc2-11e5-bf89-ae3a4af2dd4b">>,
                dst_addr = #addr{addr = <<"375296666666">>, ton = 1, npi = 1},
                src_addr = undefined
            }
        ]}}.

blacklist_test_() ->
    {setup,
        fun test_start/0,
        fun test_stop/1,
        fun(Pid) ->
            [
                test_update(Pid),
                test_check(Pid),
                test_filter(Pid)
            ]
        end
    }.

test_start() ->
    ok = application:start(meck),
    ok = meck:new(alley_services_api, [non_strict]),
    ok = meck:expect(alley_services_api, get_blacklist, fun get_blacklist/0),
    {ok, Pid} = alley_services_blacklist:start_link(),
    Pid.

test_stop(Pid) ->
    meck:unload(alley_services_api),
    ok = application:stop(meck),
    exit(Pid, normal).

test_update(_Pid) ->
    Res = alley_services_blacklist:update(),
    [?_assertEqual(ok, Res)].

test_check(_Pid) ->
    Orig1 = #addr{addr = <<"491111111111">>, ton = 1, npi = 1},
    Orig2 = #addr{addr = <<"or125">>, ton = 5, npi = 0},

    Dest1 = #addr{addr = <<"375295555555">>, ton = 1, npi = 1},
    Dest2 = #addr{addr = <<"375296666666">>, ton = 1, npi = 1},
    Dest3 = #addr{addr = <<"375297777777">>, ton = 1, npi = 1},

    [
    ?_assertEqual(denied, alley_services_blacklist:check(Dest1, Orig1)),  % entry 1
    ?_assertEqual(allowed, alley_services_blacklist:check(Dest1, Orig2)),

    ?_assertEqual(denied, alley_services_blacklist:check(Dest2, Orig1)),  % entry 3
    ?_assertEqual(denied, alley_services_blacklist:check(Dest2, Orig2)),  % entry 2

    ?_assertEqual(allowed, alley_services_blacklist:check(Dest3, Orig1)),
    ?_assertEqual(allowed, alley_services_blacklist:check(Dest3, Orig2))
    ].

test_filter(_Pid) ->
    Orig1 = #addr{addr = <<"491111111111">>, ton = 1, npi = 1},
    Orig2 = #addr{addr = <<"or125">>, ton = 5, npi = 0},

    Dest1 = #addr{addr = <<"375295555555">>, ton = 1, npi = 1},
    Dest2 = #addr{addr = <<"375296666666">>, ton = 1, npi = 1},
    Dest3 = #addr{addr = <<"375297777777">>, ton = 1, npi = 1},

    Dests = [Dest1, Dest2, Dest3],

    [
    ?_assertEqual({[Dest3], [Dest2, Dest1]}, alley_services_blacklist:filter(Dests, Orig1)),
    ?_assertEqual({[Dest3, Dest1], [Dest2]}, alley_services_blacklist:filter(Dests, Orig2))
    ].

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
