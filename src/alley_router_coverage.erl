-module(alley_router_coverage).

-include_lib("alley_dto/include/adto.hrl").

-define(TEST, 1).
-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    fill_coverage_tab/3,
    which_network/2
]).

-define(TON_UNKNOWN,       0).
-define(TON_INTERNATIONAL, 1).
-define(TON_NATIONAL,      2).
-define(TON_ALPHANUMERIC,  5).

-type provider_id() :: uuid_dto().

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec fill_coverage_tab([#network_dto{}], provider_id(), ets:tid()) -> ets:tid().
fill_coverage_tab(Networks, DefaultProviderId, Tab) ->
    FlatNetworks = flatten_networks(Networks, DefaultProviderId),
    lists:foreach(fun(NetworkTuple) ->
        ets:insert(Tab, NetworkTuple)
    end, FlatNetworks),
    PrefixLens = lists:usort([length(P) || {P, _, _, _} <- FlatNetworks]),
    ets:insert(Tab, {prefix_lens, PrefixLens}),
    Tab.

-spec which_network(#addr{}, ets:tid()) -> {string(), string(), string()} | undefined.
which_network(#addr{ton = Ton} = Addr, Tab) ->
    StripZero = alley_router_conf:get(strip_leading_zero),
    CountryCode = alley_router_conf:get(country_code),
    [{prefix_lens, PrefixLens}] = ets:lookup(Tab, prefix_lens),
    Proper = to_international(Addr, StripZero, CountryCode),
    case try_match_network(Proper, prefixes(Proper, PrefixLens), Tab) of
        undefined when Ton =:= ?TON_UNKNOWN ->
            try_match_network(CountryCode ++ Proper,
                              prefixes(CountryCode ++ Proper, PrefixLens),
                              Tab);
        Other ->
            Other
    end.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

prefixes(Digits, PrefixLens) ->
    [lists:sublist(Digits, L) || L <- PrefixLens, L < length(Digits)].

flatten_networks(Networks, DefaultProviderId) ->
    lists:flatmap(fun(Network) ->
        make_coverage_tuple(Network, DefaultProviderId)
    end, Networks).

make_coverage_tuple(Network, undefined) ->
    NetworkId   = Network#network_dto.id,
    CountryCode = Network#network_dto.country_code,
    NumberLen   = Network#network_dto.number_len,
    Prefixes    = Network#network_dto.prefixes,
    ProviderId  = Network#network_dto.provider_id,
    [{CountryCode ++ Prefix, NumberLen, NetworkId, ProviderId} || Prefix <- Prefixes];
make_coverage_tuple(Network, DefaultProviderId) ->
    NetworkId   = Network#network_dto.id,
    CountryCode = Network#network_dto.country_code,
    NumberLen   = Network#network_dto.number_len,
    Prefixes    = Network#network_dto.prefixes,
    [{CountryCode ++ Prefix, NumberLen, NetworkId, DefaultProviderId} || Prefix <- Prefixes].

to_international(#addr{addr = "+" ++ Rest}, _, _) ->
    strip_non_digits(Rest);
to_international(#addr{addr = "00" ++ Rest}, _, _) ->
    strip_non_digits(Rest);
to_international(#addr{addr = "0" ++ Rest}, true, CountryCode) ->
    CountryCode ++ strip_non_digits(Rest);
to_international(#addr{addr = Number, ton = ?TON_INTERNATIONAL}, _, _) ->
    strip_non_digits(Number);
to_international(#addr{addr = Number, ton = ?TON_NATIONAL}, _, CountryCode) ->
    CountryCode ++ strip_non_digits(Number);
to_international(#addr{addr = Number}, _, _) ->
    strip_non_digits(Number).

strip_non_digits(Number) ->
    [D || D <- Number, D >= $0, D =< $9].

try_match_network(_Number, [], _Tab) ->
    undefined;
try_match_network(Number, [Prefix | Prefixes], Tab) ->
    case ets:lookup(Tab, Prefix) of
        [{Prefix, NumLen, NetworkId, ProviderId}] when
                NumLen =:= 0 orelse NumLen =:= length(Number) ->
            {NetworkId, Number, ProviderId};
        _ ->
            try_match_network(Number, Prefixes, Tab)
    end.

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

fill_coverage(DefaultProviderId) ->
    Network1 = #network_dto{
        id = "NID1",
        country_code = "999",
        number_len = 12,
        prefixes = ["01", "02"],
        provider_id = "PID1"
    },
    Network2 = #network_dto{
        id = "NID2",
        country_code = "998",
        number_len = 0,
        prefixes = ["01", "02"],
        provider_id = "PID2"
    },
    Networks = [Network1, Network2],
    Tab = ets:new(coverage, [ordered_set]),
    fill_coverage_tab(Networks, DefaultProviderId, Tab),
    Tab.

fill_coverage_tab_undef_def_prov_id_test() ->
    Tab = fill_coverage(undefined),
    Expected = [
        {prefix_lens, [5]},
        {"99801",  0, "NID2", "PID2"},
        {"99802",  0, "NID2", "PID2"},
        {"99901", 12, "NID1", "PID1"},
        {"99902", 12, "NID1", "PID1"}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual).

fill_coverage_tab_def_def_prov_id_test() ->
    Tab = fill_coverage("PID3"),
    Expected = [
        {prefix_lens, [5]},
        {"99801",  0, "NID2", "PID3"},
        {"99802",  0, "NID2", "PID3"},
        {"99901", 12, "NID1", "PID3"},
        {"99902", 12, "NID1", "PID3"}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual).

which_network_international_number_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = "999010000000", ton = 1, npi = 1},
    Expected = {"NID1", "999010000000", "PID1"},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

which_network_short_number_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = "998010", ton = 0, npi = 0},
    Expected = {"NID2", "998010", "PID2"},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

which_network_failure_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = "997010000000", ton = 1, npi = 1},
    Expected = undefined,
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
