-module(alley_services_smtp_logger).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    set_loglevel/1,
    get_loglevel/0,
    log/8
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

-include("application.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-define(fileOpts, [write, raw]).
-define(midnightCheckInterval, 5000).

-type log_level() :: debug | none.
-type datetime() :: calendar:datetime().

-record(st, {
    fd          :: pid(),
    file_name   :: string(),
    date        :: calendar:date(),
    first_entry :: calendar:date(),
    last_entry  :: calendar:date(),
    tref        :: reference(),
    max_size    :: pos_integer(),
    log_level   :: log_level()
}).

-record(log, {
    remote_ip :: inet:ip_address(),
    remote_host :: binary(),
    from :: binary(),
    to :: [binary()],
    req_time :: datetime(),
    req_data :: binary(),
    resp_time :: datetime(),
    resp_data :: binary()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec set_loglevel(log_level()) -> ok.
set_loglevel(LogLevel) when
        LogLevel =:= none orelse
        LogLevel =:= debug ->
    gen_server:cast(?MODULE, {set_loglevel, LogLevel}).

-spec get_loglevel() -> {ok, log_level()} | {error, term()}.
get_loglevel() ->
    gen_server:call(?MODULE, get_loglevel).

-spec log(inet:ip_address(), binary(), binary(), binary(), datetime(), binary(), datetime(), binary()) -> ok.
log(IP, Hostname, From, To, ReqTime, ReqData, RespTime, RespData) ->
    LogTask = #log{
        remote_ip = IP,
        remote_host = Hostname,
        from = From,
        to = To,
        req_time = ReqTime,
        req_data = ReqData,
        resp_time = RespTime,
        resp_data = RespData
    },
    gen_server:cast(?MODULE, LogTask).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, LogLevel} = application:get_env(?APP, smtp_log_level),
    {ok, LogSize} = application:get_env(?APP, smtp_log_size),
    ?MODULE:set_loglevel(LogLevel),
    ?log_info("smtp_logger: started", []),
    {ok, #st{log_level = none, max_size = LogSize}}.

handle_call(get_loglevel, _From, #st{log_level = LogLevel} = St) ->
    {reply, {ok, LogLevel}, St};
handle_call(_Request, _From, State) ->
    {stop, unexpected_call, State}.

%% change loglevel callbacks
%%%% skip set_loglevel event since the same loglevel already set
handle_cast({set_loglevel, LogLevel}, #st{log_level = LogLevel} = St) ->
    {noreply, St};
%%%% stop logging
handle_cast({set_loglevel, none}, St) ->
    close_and_rename_prev_file(St),
    erlang:cancel_timer(St#st.tref),
    ?log_info("smtp_logger: set loglevel to none", []),
    {noreply, St#st{
        log_level = none,
        tref = undefined,
        fd = undefined,
        file_name = undefined,
        date = undefined,
        first_entry = undefined,
        last_entry = undefined
    }};
%%%% start logging
handle_cast({set_loglevel, LogLevel}, #st{log_level = none} = St) ->
    TRef = erlang:start_timer(?midnightCheckInterval, self(), midnight_check),
    St2 = open_log_file(St#st{tref = TRef, log_level = LogLevel}),
    ?log_info("smtp_logger: set loglevel to ~p", [LogLevel]),
    {noreply, St2};
%%% change loglevel
handle_cast({set_loglevel, LogLevel}, St) ->
    {noreply, St#st{log_level = LogLevel}};

%% logging callbacks
handle_cast(#log{}, #st{log_level = none} = St) ->
    {noreply, St};
handle_cast(LogData = #log{}, St) ->
    St1 = write_log_msg(fmt_data(LogData, St#st.log_level), ensure_actual_date(St)),
    {noreply, St1};

handle_cast(_Msg, State) ->
    {stop, unexpected_cast, State}.

%% check midnight callbacks
%%%% skip outdated midnight_check event
handle_info({timeout, _TRef, midnight_check}, #st{log_level = none} = St) ->
    %% May occure when switched to none loglevel,
    %% but timeout msg was alredy presented in process queue.
    %% Skip midnight_check event.
    {noreply, St};
%%%% process midnight_check event
handle_info({timeout, TRef, midnight_check}, #st{tref = TRef} = St) ->
    TRef2 = erlang:start_timer(?midnightCheckInterval, self(), midnight_check),
    {noreply, ensure_actual_date(St#st{tref = TRef2})};

handle_info(_Info, State) ->
    {stop, unexpected_info, State}.

terminate(Reason, St) ->
    case St#st.log_level of
        none -> ok;
        _    -> close_and_rename_prev_file(St)
    end,
    ?log_info("smtp_logger: terminated (~p)", [Reason]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================

open_log_file(St) ->
    {Date, Time} = calendar:local_time(),
    Filename = new_file_name(Date, Time),
    file:make_dir(log_dir(Date)),
    {ok, Fd} = file:open(Filename, ?fileOpts),
    St#st{
        fd = Fd,
        date = Date,
        file_name = Filename,
        first_entry = Time,
        last_entry = Time
    }.

ensure_actual_date(St) ->
    Date = date(),
    case St#st.date of
        Date -> St;
        _ ->
            ?log_info("smtp_logger: date changed", []),
            close_and_rename_prev_file(St),
            open_log_file(St)
    end.

write_log_msg(Data, St1) ->
    file:write(St1#st.fd, Data),
    {_Date, Time} = calendar:local_time(),
    St2 = St1#st{last_entry = Time},
    {ok, FileInfo} = file:read_file_info(St2#st.file_name),
    case FileInfo#file_info.size >= St2#st.max_size of
        true ->
            close_and_rename_prev_file(St2),
            open_log_file(St2);
        false ->
            St2
    end.

close_and_rename_prev_file(St) ->
    file:close(St#st.fd),
    ClosedName = filename:join(log_dir(St#st.date),
                               fmt_time(St#st.first_entry) ++ "_" ++
                               fmt_time(St#st.last_entry)  ++ ".log"),
    file:rename(St#st.file_name, ClosedName),
    St#st{file_name = undefined, fd = undefined}.

new_file_name(Date, Time) ->
    filename:join(log_dir(Date), fmt_time(Time) ++ "_present.log").

log_dir(Date) ->
    filename:join("./log/smtp", fmt_date(Date)).

fmt_date({Y, M, D}) ->
    lists:flatten(io_lib:format("~w-~2..0w-~2..0w", [Y, M, D])).

fmt_time({H, M, S}) ->
    lists:flatten(io_lib:format("~2..0w~2..0w~2..0w", [H, M, S])).

%% ===================================================================
%% Format data
%% ===================================================================

-spec fmt_data(#log{}, log_level()) -> binary().
fmt_data(LD = #log{}, debug) ->
    ReqTime = LD#log.req_time,
    RespTime = LD#log.resp_time,
    Diff = calendar:datetime_to_gregorian_seconds(RespTime) -
           calendar:datetime_to_gregorian_seconds(ReqTime),
    [
    "REQUEST: ", ac_datetime:datetime_to_iso8601(ReqTime), "\r\n",
    "Remote IP: ", inet:ntoa(LD#log.remote_ip), "\r\n",
    "Remote Host: ", LD#log.remote_host, "\r\n",
    "From: ", LD#log.from, "\r\n",
    "To: ", LD#log.to, "\r\n",
    "DATA:\r\n",
    LD#log.req_data,
    "\r\n",
    "RESPONSE: ", ac_datetime:datetime_to_iso8601(RespTime), "\r\n",
    "DATA:\r\n",
    LD#log.resp_data,
    "\r\n",
    "TIME: ", integer_to_list(Diff), " secs", "\r\n\r\n"
    ].
