-module(ar_coverage).

-include_lib("alley_dto/include/adto.hrl").

-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-export([fill_coverage_tab/2, which_network/2]).

-define(TON_UNKNOWN,       0).
-define(TON_INTERNATIONAL, 1).
-define(TON_NATIONAL,      2).
-define(TON_ALPHANUMERIC,  5).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

-spec fill_coverage_tab([#network_dto{}], ets:tid()) -> ets:tid().
fill_coverage_tab(Networks, Tab) ->
    FlatNetworks = flatten_networks(Networks),
    lists:foreach(fun(NetworkTuple) ->
        ets:insert(Tab, NetworkTuple)
    end, FlatNetworks),
    PrefixLens = lists:usort([length(P) || {P, _, _, _} <- FlatNetworks]),
    ets:insert(Tab, {prefix_lens, PrefixLens}),
    Tab.

-spec which_network(#addr{}, ets:tid()) -> {string(), string(), string()} | undefined.
which_network(#addr{ton = Ton} = Addr, Tab) ->
    StripZero = ar_conf:get(strip_leading_zero),
    CountryCode = ar_conf:get(country_code),
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

flatten_networks(Networks) ->
    lists:flatmap(fun network_to_tuple/1, Networks).

network_to_tuple(#network_dto{
    id = NetworkId,
    country_code = CountryCode,
    number_len = NumLen,
    prefixes = Prefixes,
    provider_id = ProviderId
}) ->
    [{CountryCode ++ Prefix, NumLen, NetworkId, ProviderId} || Prefix <- Prefixes].

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
        [{Prefix, NumLen, NetworkId, ProviderId}] when NumLen =:= 0 orelse NumLen =:= length(Number) ->
            {NetworkId, Number, ProviderId};
        _ ->
            try_match_network(Number, Prefixes, Tab)
    end.

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

fill_coverage_tab_test() ->
    ok.

which_network_test() ->
    ok.

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
