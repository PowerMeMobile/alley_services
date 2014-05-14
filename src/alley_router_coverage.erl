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
    PrefixLens = lists:usort([size(P) || {P, _, _, _} <- FlatNetworks]),
    ets:insert(Tab, {prefix_lens, PrefixLens}),
    Tab.

-spec which_network(#addr{}, ets:tid()) -> {binary(), binary(), binary()} | undefined.
which_network(#addr{ton = Ton} = Addr, Tab) ->
    StripZero = alley_router_conf:get(strip_leading_zero),
    CountryCode = alley_router_conf:get(country_code),
    [{prefix_lens, PrefixLens}] = ets:lookup(Tab, prefix_lens),
    AddrInt = to_international(Addr, StripZero, CountryCode),
    ProperDigits = AddrInt#addr.addr,
    case try_match_network(ProperDigits, prefixes(ProperDigits, PrefixLens), Tab) of
        undefined when Ton =:= ?TON_UNKNOWN ->
            GuessDigits = <<CountryCode/binary, ProperDigits/binary>>,
            try_match_network(GuessDigits, prefixes(GuessDigits, PrefixLens), Tab);
        Other ->
            Other
    end.

%% -------------------------------------------------------------------------
%% private functions
%% -------------------------------------------------------------------------

prefixes(Digits, PrefixLens) ->
    [binary:part(Digits, {0, L}) || L <- PrefixLens, L < size(Digits)].

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
    [{<<CountryCode/binary, Prefix/binary>>, NumberLen, NetworkId, ProviderId} || Prefix <- Prefixes];
make_coverage_tuple(Network, DefaultProviderId) ->
    NetworkId   = Network#network_dto.id,
    CountryCode = Network#network_dto.country_code,
    NumberLen   = Network#network_dto.number_len,
    Prefixes    = Network#network_dto.prefixes,
    [{<<CountryCode/binary, Prefix/binary>>, NumberLen, NetworkId, DefaultProviderId} || Prefix <- Prefixes].

to_international(Addr = #addr{addr = <<"+", Rest/binary>>}, _StripZero, _CountryCode) ->
    Addr#addr{addr = strip_non_digits(Rest)};
to_international(Addr = #addr{addr = <<"00", Rest/binary>>}, _StripZero, _CountryCode) ->
    Addr#addr{addr = strip_non_digits(Rest)};
to_international(Addr = #addr{addr = <<"0", Rest/binary>>}, true, CountryCode) ->
    Addr#addr{addr = <<CountryCode/binary, (strip_non_digits(Rest))/binary>>, ton = ?TON_INTERNATIONAL};
to_international(Addr = #addr{addr = Number, ton = ?TON_INTERNATIONAL}, _StripZero, _CountryCode) ->
    Addr#addr{addr = strip_non_digits(Number)};
to_international(Addr = #addr{addr = Number, ton = ?TON_NATIONAL}, _StripZero, CountryCode) ->
    Addr#addr{addr = <<CountryCode/binary, (strip_non_digits(Number))/binary>>, ton = ?TON_INTERNATIONAL};
to_international(Addr = #addr{addr = Number}, _StripZero, _CountryCode) ->
    Addr#addr{addr = strip_non_digits(Number)}.

strip_non_digits(Number) ->
    << <<D>> || <<D>> <= Number, D >= $0, D =< $9>>.

try_match_network(_Number, [], _Tab) ->
    undefined;
try_match_network(Number, [Prefix | Prefixes], Tab) ->
    case ets:lookup(Tab, Prefix) of
        [{Prefix, NumLen, NetworkId, ProviderId}] when
                NumLen =:= 0 orelse NumLen =:= size(Number) ->
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
        id = <<"NID1">>,
        country_code = <<"999">>,
        number_len = 12,
        prefixes = [<<"01">>, <<"02">>],
        provider_id = <<"PID1">>
    },
    Network2 = #network_dto{
        id = <<"NID2">>,
        country_code = <<"998">>,
        number_len = 0,
        prefixes = [<<"01">>, <<"02">>],
        provider_id = <<"PID2">>
    },
    Networks = [Network1, Network2],
    Tab = ets:new(coverage, [ordered_set]),
    fill_coverage_tab(Networks, DefaultProviderId, Tab),
    Tab.

fill_coverage_tab_undef_def_prov_id_test() ->
    Tab = fill_coverage(undefined),
    Expected = [
        {prefix_lens, [5]},
        {<<"99801">>,  0, <<"NID2">>, <<"PID2">>},
        {<<"99802">>,  0, <<"NID2">>, <<"PID2">>},
        {<<"99901">>, 12, <<"NID1">>, <<"PID1">>},
        {<<"99902">>, 12, <<"NID1">>, <<"PID1">>}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual).

fill_coverage_tab_def_def_prov_id_test() ->
    Tab = fill_coverage(<<"PID3">>),
    Expected = [
        {prefix_lens, [5]},
        {<<"99801">>,  0, <<"NID2">>, <<"PID3">>},
        {<<"99802">>,  0, <<"NID2">>, <<"PID3">>},
        {<<"99901">>, 12, <<"NID1">>, <<"PID3">>},
        {<<"99902">>, 12, <<"NID1">>, <<"PID3">>}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual).

which_network_international_number_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"999010000000">>, ton = ?TON_INTERNATIONAL},
    Expected = {<<"NID1">>, <<"999010000000">>, <<"PID1">>},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

which_network_short_number_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"998010">>, ton = ?TON_UNKNOWN},
    Expected = {<<"NID2">>, <<"998010">>, <<"PID2">>},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

which_network_failure_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"997010000000">>, ton = ?TON_INTERNATIONAL},
    Expected = undefined,
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual).

to_international_1_test() ->
    Addr = #addr{addr = <<"+999111111111">>},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_2_test() ->
    Addr = #addr{addr = <<"00999111111111">>},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_3_test() ->
    Addr = #addr{addr = <<"0111111111">>},
    StripZero = true,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_4_test() ->
    Addr = #addr{addr = <<"999111111111">>},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_5_test() ->
    Addr = #addr{addr = <<"111111111">>, ton = ?TON_NATIONAL},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
