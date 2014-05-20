-module(alley_services_events).

%% API
-export([
    start_link/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("application.hrl").
-include_lib("alley_common/include/logging.hrl").
-include_lib("alley_common/include/gen_server_spec.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {
    connection,
    channel,
    consumer_tag
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, Exchange} = application:get_env(?APP, kelly_events_exchange),
    {ok, Queue} = application:get_env(?APP, kelly_events_listener_queue),

    {ok, Connection} = rmql:connection_start(),
    {ok, Channel} = rmql:channel_open(Connection),
    ok = rmql:exchange_declare(Channel, Exchange, fanout, true),
    ok = rmql:queue_declare(Channel, Queue, true, false, false),
    ok = rmql:queue_bind(Channel, Queue, Exchange),
    {ok, CTag} = rmql:basic_consume(Channel, Queue, true),
    {ok, #state{
        connection = Connection,
        channel = Channel,
        consumer_tag = CTag
    }}.

handle_call(Request, _From, State = #state{}) ->
    {stop, {bad_arg, Request}, State}.

handle_cast(Request, State = #state{}) ->
    {stop, {bad_arg, Request}, State}.

handle_info({#'basic.deliver'{consumer_tag = CTag}, Msg}, State = #state{consumer_tag = CTag}) ->
    ContentType = (Msg#amqp_msg.props)#'P_basic'.content_type,
    Payload = Msg#amqp_msg.payload,
    {ok, Handler} = application:get_env(?APP, kelly_events_handler),
    Handler:handle_event(ContentType, Payload),
    {noreply, State};
handle_info(Message, State) ->
    ?log_warn("Unexpected message:~p", [Message]),
    {noreply, State}.

terminate(_Reason, #state{connection = Connection, channel = Channel}) ->
    rmql:channel_close(Channel),
    rmql:connection_close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================
