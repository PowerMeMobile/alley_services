-module(alley_services_pdu_logger).

-behaviour(gen_server).

-ignore_xref([
    {start_link, 2},
    {set_loglevel,3}
]).

%% API
-export([
    start_link/2,
    set_loglevel/2,
    set_loglevel/3,
    log/1
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
-include_lib("alley_dto/include/adto.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").

-define(fileOpts, [write, raw]).
-define(midnightCheckInterval, 5000).

-type log_level() :: debug | none.

-record(st, {
    customer_id :: binary(),
    user_id     :: binary(),
    fd          :: tuple(),
    file_name   :: string(),
    date        :: calendar:date(),
    first_entry :: calendar:date(),
    last_entry  :: calendar:date(),
    tref        :: reference(),
    max_size    :: pos_integer(),
    log_level   :: log_level()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(binary(), binary()) -> {ok, pid()}.
start_link(CustomerID, UserID) ->
    gen_server:start_link(?MODULE, {CustomerID, UserID}, []).

-spec set_loglevel(pid(), log_level()) -> ok.
set_loglevel(Pid, LogLevel) when
                LogLevel =:= none orelse
                LogLevel =:= debug ->
    gen_server:cast(Pid, {set_loglevel, LogLevel}).

-spec set_loglevel(binary(), binary(), log_level()) ->
    ok | logger_not_running.
set_loglevel(CustomerID, UserID, LogLevel) when
                LogLevel =:= none orelse
                LogLevel =:= debug ->
    case gproc:lookup_local_name({CustomerID, UserID}) of
        undefined ->
            {error, logger_not_running};
        Pid ->
            set_loglevel(Pid, LogLevel)
    end.

-spec log(#just_sms_request_dto{}) -> ok.
log(SmsReq) ->
    CustomerID = SmsReq#just_sms_request_dto.customer_id,
    UserID = SmsReq#just_sms_request_dto.user_id,
    {ok, LoggerPid} =
    case gproc:lookup_local_name({CustomerID, UserID}) of
        undefined ->
            catch(supervisor:start_child(alley_services_pdu_logger_sup, [CustomerID, UserID])),
            {Pid, _} = gproc:await({n,l,{CustomerID, UserID}}, 5000),
            {ok, Pid};
        Pid ->
            {ok, Pid}
    end,
    gen_server:call(LoggerPid, SmsReq).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init({CustomerID, UserID}) ->
    process_flag(trap_exit, true),
    {ok, LogLevel} = application:get_env(?APP, pdu_log_level),
    {ok, LogSize} = application:get_env(?APP, pdu_log_size),
    ?MODULE:set_loglevel(self(), LogLevel),
    %% To ingore gproc exceptions and CRASH reports in log files
    %% on concurent gproc:add_local_name call
    try gproc:add_local_name({CustomerID, UserID}) of
        true ->
            ?log_info("pdu_logger: started (~s:~s)", [CustomerID, UserID]),
            {ok, #st{customer_id = CustomerID,
                    user_id = UserID,
                    log_level = none,
                    max_size = LogSize}}
    catch
        _:_ ->
            ignore
    end.

%% logging callbacks
handle_call(#just_sms_request_dto{}, _From, #st{log_level = none} = St) ->
    {reply, ok, St};
handle_call(SmsReq = #just_sms_request_dto{}, _From, St) ->
    St1 = write_log_msg(fmt_data(SmsReq), ensure_actual_date(St)),
    {reply, ok, St1};
handle_call(_Request, _From, St) ->
    {stop, unexpected_call, St}.

%% change loglevel callbacks
%%%% skip set_loglevel event since the same loglevel already set
handle_cast({set_loglevel, LogLevel}, #st{log_level = LogLevel} = St) ->
    {noreply, St};
%%%% stop logging
handle_cast({set_loglevel, none}, St = #st{}) ->
    close_and_rename_prev_file(St),
    erlang:cancel_timer(St#st.tref),
    ?log_info("pdu_logger: set loglevel to none (~s:~s)",
        [St#st.customer_id, St#st.user_id]),
    {noreply, St#st{log_level = none,
                    tref = undefined,
                    fd = undefined,
                    file_name = undefined,
                    date = undefined,
                    first_entry = undefined,
                    last_entry = undefined }};
%%%% start logging
handle_cast({set_loglevel, LogLevel}, #st{log_level = none} = St) ->
    TRef = erlang:start_timer(?midnightCheckInterval, self(), midnight_check),
    St2 = open_log_file(St#st{tref = TRef, log_level = LogLevel}),
    ?log_info("pdu_logger: set loglevel to ~p (~s:~s)",
        [LogLevel, St#st.customer_id, St#st.user_id]),
    {noreply, St2};
%%% change loglevel
handle_cast({set_loglevel, LogLevel}, St) ->
    {noreply, St#st{log_level = LogLevel}};

handle_cast(_Msg, St) ->
    {stop, unexpected_cast, St}.

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

handle_info(_Info, St) ->
    {stop, unexpected_info, St}.

terminate(Reason, St = #st{}) ->
    case St#st.log_level of
        none -> ok;
        _    -> close_and_rename_prev_file(St)
    end,
    catch(gproc:goodbye()),
    ?log_info("pdu_logger: terminated (~s:~s) (~p)",
        [St#st.customer_id, St#st.user_id, Reason]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================

open_log_file(St) ->
    {Date, Time} = calendar:local_time(),
    Filename = new_file_name(Date, Time, St),
    file:make_dir(log_dir(Date)),
    {ok, Fd} = file:open(Filename, ?fileOpts),
    St#st{  fd = Fd,
            date = Date,
            file_name = Filename,
            first_entry = Time,
            last_entry = Time}.

ensure_actual_date(St) ->
    Date = date(),
    case St#st.date of
        Date -> St;
        _ ->
            ?log_info("pdu_logger: date changed (~s:~s)",
                [St#st.customer_id, St#st.user_id]),
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
                               fmt_time(St#st.last_entry)  ++ "_" ++
                               binary_to_list(St#st.customer_id) ++ "_" ++
                               binary_to_list(St#st.user_id) ++ ".log"),
    file:rename(St#st.file_name, ClosedName),
    St#st{file_name = undefined, fd = undefined}.

new_file_name(Date, Time, St) ->
    filename:join(  log_dir(Date),
                    fmt_time(Time) ++ "_present_" ++
                    binary_to_list(St#st.customer_id) ++ "_" ++
                    binary_to_list(St#st.user_id) ++ ".log").

log_dir(Date) ->
    filename:join("./log/pdu", fmt_date(Date)).

fmt_date({Y, M, D}) ->
    lists:flatten(io_lib:format("~w-~2..0w-~2..0w", [Y, M, D])).

fmt_time({H, M, S}) ->
    lists:flatten(io_lib:format("~2..0w~2..0w~2..0w", [H, M, S])).

%% ===================================================================
%% Format data
%% ===================================================================

-spec fmt_data(#just_sms_request_dto{}) -> binary().
fmt_data(SmsReq = #just_sms_request_dto{}) ->
    Fields = record_info(fields, just_sms_request_dto),
    PrettyParams = prettify_params(SmsReq),
    [_ | Values] =
        tuple_to_list(SmsReq#just_sms_request_dto{params = PrettyParams}),
    KV = lists:zip(Fields, Values),

    TimeStamp = {_, _, MilSec} = os:timestamp(),
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:now_to_local_time(TimeStamp),
    TimeFmt =
        io_lib:format("~w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~3..0w > ",
            [Year, Month, Day, Hour, Min, Sec, (MilSec rem 1000)]),

    [[io_lib:format("~s~w: ~p~n", [TimeFmt, K, V]) || {K, V} <- KV] | "\n"].

prettify_params(SmsReq) ->
    [{Key, Value} || #just_sms_request_param_dto{
                name = Key,
                value = {_Type, Value}
                } <- SmsReq#just_sms_request_dto.params].

