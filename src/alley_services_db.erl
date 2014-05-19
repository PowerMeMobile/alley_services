-module(alley_services_db).

%% API
-export([
    init_mnesia/0,
    next_id/3
]).

-include_lib("alley_common/include/logging.hrl").

-type customer_id() :: binary().
-type user_id()     :: binary().
-type key()         :: {customer_id(), user_id()}.

-record(customer_next_message_id, {
    cust_user_id    :: key(),
    next_seq_id     :: integer()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec next_id(customer_id(), user_id(), integer()) -> {ok, [integer()]}.
next_id(CustomerId, UserId, NumberOfIds) ->
    Key = {CustomerId, UserId},
    {atomic, Ids} = mnesia:transaction(fun() ->
        case mnesia:read(customer_next_message_id, Key, write) of
            [] ->
                update_counter(1, NumberOfIds, Key);
            [#customer_next_message_id{next_seq_id = NextId}] ->
                update_counter(NextId, NumberOfIds, Key)
        end
    end),
    {ok, Ids}.

-spec init_mnesia() -> ok.
init_mnesia() ->
    Nodes = [node()],
    mnesia:stop(),
    ?log_info("db: creating mnesia schema on: ~p...", [Nodes]),
    ok = case mnesia:create_schema(Nodes) of
        ok ->
            ?log_info("db: schema was created", []),
            ok;
        {error, {MnesiaNode, {already_exists, MnesiaNode}}} ->
            MnesiaNodes = mnesia:system_info(db_nodes),
            case lists:member(MnesiaNode, MnesiaNodes) of
                true ->
                    ?log_info("db: mnesia schema already exists on: ~p", [MnesiaNode]),
                    ok;
                false ->
                    ?log_error("Mnesia schema already exists on: ~p, but it's not in existing list: ~p"
                        " Did you rename the node?",
                        [MnesiaNode, MnesiaNodes]),
                    erlang:error(schema_already_exists_created_on_different_node)
            end
    end,
    ok = mnesia:start(),

    ok = ensure_table(
        customer_next_message_id,
        record_info(fields, customer_next_message_id)).

%% ===================================================================
%% Internal
%% ===================================================================

update_counter(NextId, NumberOfIds, Key) ->
    Max = 999999999,
    {From, To, NewNextId} =
    case (NextId + NumberOfIds - 1) > Max of
        true -> {1, NumberOfIds, NumberOfIds + 1};
        false -> {NextId, NextId + NumberOfIds - 1, NextId + NumberOfIds}
    end,
    Ids = lists:seq(From, To),
    mnesia:write(#customer_next_message_id{cust_user_id = Key, next_seq_id = NewNextId}),
    Ids.

ensure_table(TableName, RecordInfo) ->
    ok = case mnesia:create_table(TableName, [
                    {disc_copies, [node()]},
                    {attributes, RecordInfo}]) of
            {atomic, ok} ->
                ok;
            {aborted, {already_exists, TableName}} ->
                ok
         end,
    ok = mnesia:wait_for_tables([TableName], infinity).
