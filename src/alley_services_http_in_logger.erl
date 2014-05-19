-module(alley_services_http_in_logger).

-behaviour(gen_server).

-ignore_xref([{start_link, 0}]).

%% API
-export([
    start_link/0,
    set_loglevel/1
]).

%% Cowboy onresponse hook callback
-export([log/5]).

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

-type log_level() :: debug | info | none.

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
    resp_code :: non_neg_integer(),
    resp_headers :: list(),
    resp_body :: binary(),
    req :: cowboy_req:req(),
    req_body :: binary()
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
                LogLevel =:= info orelse
                LogLevel =:= debug ->
    gen_server:cast(?MODULE, {set_loglevel, LogLevel}).

%% ===================================================================
%% Cowboy onresponse hook callback
%% ===================================================================

-spec log(  non_neg_integer(), list(), binary(),
            cowboy_req:req(), binary()) -> ok.
log(RespCode, RespHeaders, RespBody, Req, ReqBody) ->
    LogTask = #log{
        resp_code = RespCode,
        resp_headers = RespHeaders,
        resp_body = RespBody,
        req = Req,
        req_body = ReqBody
    },
    gen_server:call(?MODULE, LogTask).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, LogLevel} = application:get_env(?APP, http_log_level),
    {ok, LogSize} = application:get_env(?APP, http_log_size),
    ?MODULE:set_loglevel(LogLevel),
    ?log_info("http_in_logger: started", []),
    {ok, #st{log_level = none, max_size = LogSize}}.

%% logging callbacks
handle_call(#log{}, _From, #st{log_level = none} = St) ->
    {reply, ok, St};
handle_call(LogData = #log{}, _From, St) ->
    St1 = write_log_msg(fmt_data(LogData, St#st.log_level), ensure_actual_date(St)),
    {reply, ok, St1};

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
    ?log_info("http_in_logger: set loglevel to none", []),
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
    ?log_info("http_in_logger: set loglevel to ~p", [LogLevel]),
    {noreply, St2};
%%% change loglevel
handle_cast({set_loglevel, LogLevel}, St) ->
    {noreply, St#st{log_level = LogLevel}};

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
    ?log_info("http_in_logger: terminated (~p)", [Reason]).

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
            ?log_info("http_in_logger: date changed", []),
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
    filename:join("./log/http/in", fmt_date(Date)).

fmt_date({Y, M, D}) ->
    lists:flatten(io_lib:format("~w-~2..0w-~2..0w", [Y, M, D])).

fmt_time({H, M, S}) ->
    lists:flatten(io_lib:format("~2..0w~2..0w~2..0w", [H, M, S])).

%% ===================================================================
%% Format data
%% ===================================================================

-spec fmt_data(#log{}, log_level()) -> binary().
fmt_data(LD = #log{req_body = <<>>}, debug) ->
    ApacheFmt = fmt_apache_log(LD),
    io_lib:format("~sResponse body:~n~s~n",
        [ApacheFmt, LD#log.resp_body]);
fmt_data(LD = #log{}, debug) ->
    ApacheFmt = fmt_apache_log(LD),
    io_lib:format("~sRequest body:~n~s~nResponse body:~n~s~n",
        [ApacheFmt, LD#log.req_body, LD#log.resp_body]);
fmt_data(LD = #log{}, info) ->
    fmt_apache_log(LD).

fmt_apache_log(LD = #log{}) ->
    Req = LD#log.req,
    %% compose client ip addr
    {{{IP0,IP1,IP2,IP3}, _Port}, Req} = cowboy_req:peer(Req),
    ClientIP = io_lib:format("~p.~p.~p.~p",[IP0,IP1,IP2,IP3]),

    %% compose log time
    {{Y,M,D},{H,Min,S}} = calendar:universal_time(),
    Month = httpd_util:month(M),
    LogTime = io_lib:format("~2..0w/~s/~w:~2..0w:~2..0w:~2..0w -0000", [D,Month,Y,H,Min,S]),

    %% compose response size
    RespSize = size(LD#log.resp_body),

    %% compose ReqLine
    {Method, Req} = cowboy_req:method(Req),
    {HttpVer, Req} = cowboy_req:version(Req),
    {Path, Req} = cowboy_req:path(Req),
    Query =
        case cowboy_req:qs(Req) of
            {<<>>, Req} -> <<>>;
            {QS, Req} -> "?" ++ QS
        end,
    ReqLine = io_lib:format("~s ~s~s ~s",[Method, Path, Query, HttpVer]),

    %% compose user-agent
    {UserAgent, Req} = cowboy_req:header(<<"user-agent">>, Req, "-"),

    %% final apache like log line
    io_lib:format("~s - - [~s] \"~s\" ~p ~p ~p ~p~n",
        [ClientIP, LogTime, ReqLine, LD#log.resp_code, RespSize, "-", UserAgent]).
