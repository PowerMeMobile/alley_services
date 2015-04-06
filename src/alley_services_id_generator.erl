-module(alley_services_id_generator).

%-define(TEST, 1).
-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    init/1,
    next_ids/2,
    deinit/1
]).

-type key() :: any().
-type count() :: pos_integer().

%% ===================================================================
%% API
%% ===================================================================

-spec init(key()) -> ok.
init(Key) ->
    case erlang:get(Key) of
        undefined ->
            erlang:put(Key, 1),
            ok;
        _ ->
            error({existing_key, Key})
    end.

-spec next_ids(key(), count()) -> [pos_integer()].
next_ids(Key, Count) when is_integer(Count), Count >= 0 ->
    [next_id(Key) || _ <- lists:seq(1, Count)].

-spec deinit(key()) -> ok.
deinit(Key) ->
    case erlang:get(Key) of
        undefined ->
            error({unknown_key, Key});
        _ ->
            erlang:put(Key, undefined),
            ok
    end.

%% ===================================================================
%% Internal
%% ===================================================================

next_id(Key) ->
    case erlang:get(Key) of
        undefined ->
            error({unknown_key, Key});
        Id ->
            erlang:put(Key, Id+1),
            Id
    end.

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

init_existing_key_test() ->
    Key = <<"KEY">>,
    ok = init(Key),
    ?assertError({existing_key, Key}, init(Key)),
    ok = deinit(Key).

next_id_unknown_key_test() ->
    Key = <<"UNKNOWN_KEY">>,
    ?assertError({unknown_key, Key}, next_id(Key)).

next_id_test() ->
    Key = <<"KEY">>,
    ok = init(Key),
    ?assertEqual(1, next_id(Key)),
    ?assertEqual(2, next_id(Key)),
    ?assertEqual(3, next_id(Key)),
    ok = deinit(Key).

next_ids_unknown_key_test() ->
    Key = <<"UNKNOWN_KEY">>,
    ?assertError({unknown_key, Key}, next_ids(Key, 1)).

next_ids_bad_count_test() ->
    Key = <<"">>,
    ?assertError(function_clause, next_ids(Key, -1)),
    ?assertError(function_clause, next_ids(Key, 1.0)).

next_ids_test() ->
    Key = <<"KEY">>,
    ok = init(Key),
    ?assertEqual([1], next_ids(Key, 1)),
    ?assertEqual([2], next_ids(Key, 1)),
    ?assertEqual([3,4,5], next_ids(Key, 3)),
    ok = deinit(Key).

deinit_unknown_key_test() ->
    Key = <<"UNKNOWN_KEY">>,
    ?assertError({unknown_key, Key}, deinit(Key)).

%% ===================================================================
%% End Tests
%% ===================================================================

-endif.
