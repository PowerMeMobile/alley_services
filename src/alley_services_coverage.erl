-module(alley_services_coverage).

-include("application.hrl").
-include_lib("alley_dto/include/adto.hrl").

%-define(TEST, 1).
-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    fill_coverage_tab/3,
    fill_network_type_tab/2,
    which_network/2,
    which_network_type/2,
    route_addrs_to_providers/2,
    route_addrs_to_gateways/2,
    route_addrs_to_networks/2,
    build_network_to_sms_price_map/3,
    calc_sending_price/3
]).

-define(TON_UNKNOWN,       0).
-define(TON_INTERNATIONAL, 1).
-define(TON_NATIONAL,      2).
-define(TON_ALPHANUMERIC,  5).
-define(TON_ABBREVIATED,   6).

-define(NPI_UNKNOWN,       0).
-define(NPI_ISDN,          1). % E163/E164

-type provider_id() :: uuid_dto().
-type gateway_id()  :: uuid_dto().
-type network_id()  :: uuid_dto().

%% ===================================================================
%% API
%% ===================================================================

-spec fill_coverage_tab([#network_dto{}], provider_id(), ets:tid()) -> ets:tid().
fill_coverage_tab(Networks, DefaultProviderId, Tab) ->
    FlatNetworks = flatten_networks(Networks, DefaultProviderId),
    lists:foreach(fun(NetworkTuple) ->
        ets:insert(Tab, NetworkTuple)
    end, FlatNetworks),
    PrefixLens = lists:usort([size(P) || {P, _, _, _} <- FlatNetworks]),
    ets:insert(Tab, {prefix_lens, PrefixLens}),
    Tab.

-spec fill_network_type_tab([#network_dto{}], ets:tid()) -> ets:tid().
fill_network_type_tab(Networks, Tab) ->
    OnNetNs = [N || N <- Networks, N#network_dto.is_home],

    OnNetCCs =
        case OnNetNs of
            [] ->
                %% the misconfiguration issue. there's no a home network.
                %% add the country code from settings to treat, at least,
                %% local network as off_net.
                {ok, CC} = application:get_env(?APP, country_code),
                [CC];
            _  ->
                lists:usort([N#network_dto.country_code || N <- OnNetNs])
        end,

    OnNetNIDs = [N#network_dto.id || N <- OnNetNs],
    OffNetNIDs = [N#network_dto.id || N <- Networks,
        N#network_dto.is_home =:= false,
        lists:member(N#network_dto.country_code, OnNetCCs)],

    lists:foreach(
        fun(NID) -> ets:insert(Tab, {NID, on_net}) end, OnNetNIDs),
    lists:foreach(
        fun(NID) -> ets:insert(Tab, {NID, off_net}) end, OffNetNIDs),
    Tab.

-spec which_network(#addr{}, ets:tid()) -> {network_id(), #addr{}, provider_id()} | undefined.
which_network(Addr = #addr{}, Tab) ->
    {ok, StripZero} = application:get_env(?APP, strip_leading_zero),
    {ok, CountryCode} = application:get_env(?APP, country_code),
    [{prefix_lens, PrefixLens}] = ets:lookup(Tab, prefix_lens),
    AddrInt = to_international(Addr, StripZero, CountryCode),
    Number = AddrInt#addr.addr,
    case try_match_network(Number, prefixes(Number, PrefixLens), Tab) of
        undefined ->
            undefined;
        {NetworkId, ProviderId} ->
            {NetworkId, AddrInt, ProviderId}
    end.

-spec which_network_type(network_id(), ets:tid()) -> on_net | off_net | int_net.
which_network_type(NetworkId, Tab) ->
    case ets:lookup(Tab, NetworkId) of
        [{NetworkId, NetType}] ->
            NetType;
        [] ->
            int_net
    end.

-spec route_addrs_to_providers([#addr{}], ets:tab()) ->
    {[{provider_id(), [#addr{}]}], [#addr{}]}.
route_addrs_to_providers(Addrs, CoverageTab) ->
    route_addrs_to_providers(Addrs, CoverageTab, dict:new(), []).

-spec route_addrs_to_gateways([{provider_id(), [#addr{}]}], [#provider_dto{}]) ->
    {[{gateway_id(), [#addr{}]}], [#addr{}]}.
route_addrs_to_gateways(ProvIdAddrs, Providers) ->
    route_addrs_to_gateways(ProvIdAddrs, Providers, [], []).

-spec route_addrs_to_networks([#addr{}], ets:tab()) ->
    {[{network_id(), [#addr{}]}], [#addr{}]}.
route_addrs_to_networks(Addrs, CoverageTab) ->
    route_addrs_to_networks(Addrs, CoverageTab, dict:new(), []).

-spec build_network_to_sms_price_map([#network_dto{}], [#provider_dto{}], provider_id()) ->
    [{network_id(), float()}].
build_network_to_sms_price_map(Networks, Providers, DefaultProviderId) ->
    network_id_to_sms_price(Networks, Providers, DefaultProviderId).

-spec calc_sending_price(
    [{network_id(), [#addr{}]}],
    [{network_id(), float()}],
    pos_integer()
) -> float().
calc_sending_price(NetworkId2Addrs, NetworkId2SmsPrice, NumOfMsgs) ->
    OneMsgPrice = lists:foldl(
        fun({NetworkId, Addrs}, Sum) ->
            SmsPrice = proplists:get_value(NetworkId, NetworkId2SmsPrice),
            SmsPrice * length(Addrs) + Sum
        end,
        0,
        NetworkId2Addrs
    ),
    OneMsgPrice * NumOfMsgs.

%% ===================================================================
%% Internal
%% ===================================================================

prefixes(Number, PrefixLens) ->
    [binary:part(Number, {0, L}) || L <- PrefixLens, L < size(Number)].

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
    Addr#addr{
        addr = strip_non_digits(Rest),
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
to_international(Addr = #addr{addr = <<"00", Rest/binary>>}, _StripZero, _CountryCode) ->
    Addr#addr{
        addr = strip_non_digits(Rest),
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
to_international(Addr = #addr{addr = <<"0", Rest/binary>>}, true, CountryCode) ->
    Addr#addr{
        addr = <<CountryCode/binary, (strip_non_digits(Rest))/binary>>,
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
to_international(Addr = #addr{addr = Number, ton = ?TON_INTERNATIONAL}, _StripZero, _CountryCode) ->
    Addr#addr{
        addr = strip_non_digits(Number),
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
to_international(Addr = #addr{addr = Number, ton = ?TON_NATIONAL}, _StripZero, CountryCode) ->
    Addr#addr{
        addr = <<CountryCode/binary, (strip_non_digits(Number))/binary>>,
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
to_international(Addr = #addr{addr = Number}, _StripZero, _CountryCode) ->
    Addr#addr{addr = strip_non_digits(Number)}.

strip_non_digits(Number) ->
    << <<D>> || <<D>> <= Number, D >= $0, D =< $9>>.

try_match_network(_Number, [], _Tab) ->
    undefined;
try_match_network(Number, [Prefix | Prefixes], Tab) ->
    case ets:lookup(Tab, Prefix) of
        [{Prefix, NumberLen, NetworkId, ProviderId}] when
                NumberLen =:= 0 orelse NumberLen =:= size(Number) ->
            {NetworkId, ProviderId};
        _ ->
            try_match_network(Number, Prefixes, Tab)
    end.

route_addrs_to_providers([], _CoverageTab, Routable, Unroutable) ->
    {dict:to_list(Routable), Unroutable};
route_addrs_to_providers([Addr | Rest], CoverageTab, Routable, Unroutable) ->
    case alley_services_coverage:which_network(Addr, CoverageTab) of
        {_NetworkId, MaybeFixedAddr, ProviderId} ->
            UpdateFun = fun(Addrs) -> [MaybeFixedAddr | Addrs] end,
            Routable2 = dict:update(ProviderId, UpdateFun, [MaybeFixedAddr], Routable),
            route_addrs_to_providers(Rest, CoverageTab, Routable2, Unroutable);
        undefined ->
            route_addrs_to_providers(Rest, CoverageTab, Routable, [Addr | Unroutable])
    end.

route_addrs_to_gateways([], _Providers, Routable, Unroutable) ->
    {Routable, Unroutable};
route_addrs_to_gateways([{ProvId, Addrs} | Rest], Providers, Routable, Unroutable) ->
    case lists:keyfind(ProvId, #provider_dto.id, Providers) of
        false ->
            %% the misconfiguration issue. nowhere to route.
            route_addrs_to_gateways(Rest, Providers, Routable, Addrs ++ Unroutable);
        Provider ->
            {ok, BulkThreshold} = application:get_env(?APP, bulk_threshold),
            UseBulkGtw = length(Addrs) >= BulkThreshold,
            %% try to workaround possible misconfiguration issues.
            case {Provider#provider_dto.gateway_id, Provider#provider_dto.bulk_gateway_id, UseBulkGtw} of
                {undefined, undefined, _} ->
                    %% the misconfiguration issue. nowhere to route.
                    route_addrs_to_gateways(Rest, Providers, Routable, Addrs ++ Unroutable);
                {GtwId, undefined, _} ->
                    %% route all via regular gateway.
                    route_addrs_to_gateways(Rest, Providers, [{GtwId, Addrs} | Routable], Unroutable);
                {undefined, BulkGtwId, _} ->
                    %% route all via bulk gateway.
                    route_addrs_to_gateways(Rest, Providers, [{BulkGtwId, Addrs} | Routable], Unroutable);
                {GtwId, _BulkGtwId, false} ->
                    route_addrs_to_gateways(Rest, Providers, [{GtwId, Addrs} | Routable], Unroutable);
                {_GtwId, BulkGtwId, true} ->
                    route_addrs_to_gateways(Rest, Providers, [{BulkGtwId, Addrs} | Routable], Unroutable)
            end
    end.

route_addrs_to_networks([], _CoverageTab, Routable, Unroutable) ->
    {dict:to_list(Routable), Unroutable};
route_addrs_to_networks([Addr | Rest], CoverageTab, Routable, Unroutable) ->
    case alley_services_coverage:which_network(Addr, CoverageTab) of
        {NetworkId, _MaybeFixedAddr, _ProviderId} ->
            UpdateFun = fun(Addrs) -> [Addr | Addrs] end,
            Routable2 = dict:update(NetworkId, UpdateFun, [Addr], Routable),
            route_addrs_to_networks(Rest, CoverageTab, Routable2, Unroutable);
        undefined ->
            route_addrs_to_networks(Rest, CoverageTab, Routable, [Addr | Unroutable])
    end.

network_id_to_sms_price(Networks, Providers, DefaultProviderId) ->
    {Networks2, Providers2} =
        case DefaultProviderId of
            undefined ->
                {Networks, Providers};
            DefaultProviderId ->
                {[N#network_dto{provider_id = DefaultProviderId} || N <- Networks],
                 [P || P <- Providers, P#provider_dto.id =:= DefaultProviderId]}
        end,
    network_id_to_sms_price(Networks2, Providers2).

network_id_to_sms_price(Networks, Providers) ->
    ProviderId2SmsAddPoints =
        [{P#provider_dto.id, P#provider_dto.sms_add_points} || P <- Providers],
    [{N#network_dto.id, calc_sms_price(N, ProviderId2SmsAddPoints)} || N <- Networks].

calc_sms_price(Network, ProviderId2SmsAddPoints) ->
    SmsPoints = Network#network_dto.sms_points,
    SmsMultPoints = Network#network_dto.sms_mult_points,
    ProviderId = Network#network_dto.provider_id,
    SmsAddPoints = proplists:get_value(ProviderId, ProviderId2SmsAddPoints),
    (SmsPoints + SmsAddPoints) * SmsMultPoints.

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

networks() ->
    Network1 = #network_dto{
        id = <<"NID1">>,
        country_code = <<"999">>,
        number_len = 12,
        prefixes = [<<"01">>, <<"02">>],
        provider_id = <<"PID1">>,
        is_home = false
    },
    Network2 = #network_dto{
        id = <<"NID2">>,
        country_code = <<"999">>,
        number_len = 0,
        prefixes = [<<"03">>, <<"04">>],
        provider_id = <<"PID2">>,
        is_home = false
    },
    Network3 = #network_dto{
        id = <<"NID3">>,
        country_code = <<"998">>,
        number_len = 0,
        prefixes = [<<"0">>, <<"1">>, <<"2">>],
        provider_id = <<"PID3">>,
        is_home = false
    },
    [Network1, Network2, Network3].

fill_coverage(DefaultProviderId) ->
    ok = application:set_env(?APP, country_code, <<"999">>),
    ok = application:set_env(?APP, strip_leading_zero, false),
    Networks = networks(),
    Tab = ets:new(coverage, [ordered_set]),
    fill_coverage_tab(Networks, DefaultProviderId, Tab),
    Tab.

fill_coverage_tab_empty_tab_test() ->
    Tab = ets:new(coverage_tab, []),
    fill_coverage_tab([], undefined, Tab),
    ?assertEqual(1, ets:info(Tab, size)),
    ?assertEqual([{prefix_lens, []}], ets:lookup(Tab, prefix_lens)),
    ets:delete(Tab).

fill_coverage_tab_undef_def_prov_id_test() ->
    Tab = fill_coverage(undefined),
    Expected = [
        {prefix_lens, [4, 5]},
        {<<"9980">>, 0, <<"NID3">>, <<"PID3">>},
        {<<"9981">>, 0, <<"NID3">>, <<"PID3">>},
        {<<"9982">>, 0, <<"NID3">>, <<"PID3">>},
        {<<"99901">>, 12, <<"NID1">>, <<"PID1">>},
        {<<"99902">>, 12, <<"NID1">>, <<"PID1">>},
        {<<"99903">>,  0, <<"NID2">>, <<"PID2">>},
        {<<"99904">>,  0, <<"NID2">>, <<"PID2">>}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

fill_coverage_tab_def_def_prov_id_test() ->
    Tab = fill_coverage(<<"PID4">>),
    Expected = [
        {prefix_lens, [4, 5]},
        {<<"9980">>, 0, <<"NID3">>, <<"PID4">>},
        {<<"9981">>, 0, <<"NID3">>, <<"PID4">>},
        {<<"9982">>, 0, <<"NID3">>, <<"PID4">>},
        {<<"99901">>, 12, <<"NID1">>, <<"PID4">>},
        {<<"99902">>, 12, <<"NID1">>, <<"PID4">>},
        {<<"99903">>,  0, <<"NID2">>, <<"PID4">>},
        {<<"99904">>,  0, <<"NID2">>, <<"PID4">>}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

fill_coverage_tab_test() ->
    Networks = [
        #network_dto{
            id = <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
            country_code = <<"444">>,
            number_len = 12,
            prefixes = [<<"296">>, <<"293">>],
            provider_id = <<"123">>
        },
        #network_dto{
            id = <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>,
            country_code = <<"555">>,
            number_len = 13,
            prefixes = [<<"2311">>, <<"3320">>],
            provider_id = <<"456">>
        }
    ],
    Tab = ets:new(coverage_tab, []),
    fill_coverage_tab(Networks, undefined, Tab),
    ?assertEqual(5, ets:info(Tab, size)),
    ?assertEqual([{<<"444296">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"123">>}],
                 ets:lookup(Tab, <<"444296">>)),
    ?assertEqual([{<<"444293">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"123">>}],
                 ets:lookup(Tab, <<"444293">>)),
    ?assertEqual([{<<"5552311">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"456">>}],
                 ets:lookup(Tab, <<"5552311">>)),
    ?assertEqual([{<<"5553320">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"456">>}],
                 ets:lookup(Tab, <<"5553320">>)),
    ?assertEqual([{prefix_lens, [6,7]}], ets:lookup(Tab, prefix_lens)),
    ets:delete(Tab).

which_network_international_number_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"999020000000">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Addr2 = #addr{addr = <<"999020000000">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Expected = {<<"NID1">>, Addr2, <<"PID1">>},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

which_network_with_zero_number_len_success_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"9990300000">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Addr2 = #addr{addr = <<"9990300000">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Expected = {<<"NID2">>, Addr2, <<"PID2">>},
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

which_network_failure_test() ->
    Tab = fill_coverage(undefined),
    Addr = #addr{addr = <<"997010000000">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Expected = undefined,
    Actual = which_network(Addr, Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

which_network_test() ->
    ok = application:set_env(?APP, country_code, <<"999">>),
    ok = application:set_env(?APP, strip_leading_zero, false),
    Networks = [
        #network_dto{
            id = <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
            country_code = <<"444">>,
            number_len = 12,
            prefixes = [<<"296">>, <<"293">>],
            provider_id = <<"123">>
        },
        #network_dto{
            id = <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>,
            country_code = <<"555">>,
            number_len = 13,
            prefixes = [<<"2311">>, <<"3320">>],
            provider_id = <<"456">>
        },
        #network_dto{
            id = <<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
            country_code = <<"999">>,
            number_len = 12,
            prefixes = [<<"011">>, <<"083">>],
            provider_id = <<"123">>
        }
    ],
    Tab = ets:new(coverage_tab, []),
    fill_coverage_tab(Networks, undefined, Tab),
    ?assertEqual(undefined,
                 which_network(#addr{addr = <<"44429611347">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual({<<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
                  #addr{addr = <<"444296113477">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"444296113477">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual({<<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
                  #addr{addr = <<"444293113477">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"444293113477">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual({<<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>,
                  #addr{addr = <<"5553320123456">>, ton = 1, npi = 1}, <<"456">>},
                  which_network(#addr{addr = <<"5553320123456">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual(undefined,
                 which_network(#addr{addr = <<"011333333">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
                  #addr{addr = <<"999083333333">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"083333333">>, ton = 2, npi = 0}, Tab)),
    ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
                  #addr{addr = <<"999083333333">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"+999083333333">>, ton = 0, npi = 0}, Tab)),
    ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
                  #addr{addr = <<"999083333333">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"00999083333333">>, ton = 0, npi = 0}, Tab)),
    ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
                  #addr{addr = <<"999083333333">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"+999083333333">>, ton = 1, npi = 0}, Tab)),
    ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
                  #addr{addr = <<"999083333333">>, ton = 1, npi = 1}, <<"123">>},
                  which_network(#addr{addr = <<"00999083333333">>, ton = 1, npi = 0}, Tab)),
    %% MAYBE should be a new case
    %% ?assertEqual({<<"06561b4c-d7b2-4cab-b031-af2a90c31491">>,
    %%               #addr{addr = <<"999011333333">>, ton = 1, npi = 1}, <<"123">>},
    %%               which_network(#addr{addr = <<"011333333">>, ton = 0, npi = 0}, Tab)),
    ets:delete(Tab).

fill_network_type_tab_1_test() ->
    Networks = networks(),
    Tab = ets:new(map, [ordered_set]),
    fill_network_type_tab(Networks, Tab),
    Expected = [
        {<<"NID1">>, off_net},
        {<<"NID2">>, off_net}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

fill_network_type_tab_2_test() ->
    [N | Ns] = networks(),
    Networks = [N#network_dto{is_home = true} | Ns],
    Tab = ets:new(map, [ordered_set]),
    fill_network_type_tab(Networks, Tab),
    Expected = [
        {<<"NID1">>, on_net},
        {<<"NID2">>, off_net}
    ],
    Actual = ets:tab2list(Tab),
    ?assertEqual(Expected, Actual),
    ets:delete(Tab).

which_network_type_1_test() ->
    Networks = networks(),
    Tab = ets:new(map, [ordered_set]),
    fill_network_type_tab(Networks, Tab),
    ?assertEqual(off_net, which_network_type(<<"NID1">>, Tab)),
    ?assertEqual(off_net, which_network_type(<<"NID2">>, Tab)),
    ?assertEqual(int_net, which_network_type(<<"NID3">>, Tab)),
    ets:delete(Tab).

which_network_type_2_test() ->
    [N | Ns] = networks(),
    Networks = [N#network_dto{is_home = true} | Ns],
    Tab = ets:new(map, [ordered_set]),
    fill_network_type_tab(Networks, Tab),
    ?assertEqual(on_net, which_network_type(<<"NID1">>, Tab)),
    ?assertEqual(off_net, which_network_type(<<"NID2">>, Tab)),
    ?assertEqual(int_net, which_network_type(<<"NID3">>, Tab)),
    ets:delete(Tab).

to_international_1_test() ->
    Addr = #addr{addr = <<"+999111111111">>},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_2_test() ->
    Addr = #addr{addr = <<"00999111111111">>},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_3_test() ->
    Addr = #addr{addr = <<"0111111111">>},
    StripZero = true,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_4_test() ->
    Addr = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_5_test() ->
    Addr = #addr{addr = <<"111111111">>, ton = ?TON_NATIONAL},
    StripZero = false,
    CountryCode = <<"999">>,
    Exp = #addr{addr = <<"999111111111">>, ton = ?TON_INTERNATIONAL, npi = ?NPI_ISDN},
    Act = to_international(Addr, StripZero, CountryCode),
    ?assertEqual(Exp, Act).

to_international_international_test() ->
    Addr1 = #addr{addr = <<"+44 29 675643">>, ton = 1, npi = 1},
    Exp1 = #addr{addr = <<"4429675643">>, ton = 1, npi = 1},
    ?assertEqual(Exp1, to_international(Addr1, false, <<"999">>)),
    Addr2 = #addr{addr = <<"00 44 29 675643">>, ton = 1, npi = 1},
    Exp2 = #addr{addr = <<"4429675643">>, ton = 1, npi = 1},
    ?assertEqual(Exp2, to_international(Addr2, false, <<"999">>)),
    Addr3 = #addr{addr = <<"00 259 675643">>, ton = 0, npi = 1},
    Exp3 = #addr{addr = <<"259675643">>, ton = 1, npi = 1},
    ?assertEqual(Exp3, to_international(Addr3, false, <<"222">>)),
    Addr4 = #addr{addr = <<"+ 344 067 5643">>, ton = 0, npi = 1},
    Exp4 = #addr{addr = <<"3440675643">>, ton = 1, npi = 1},
    ?assertEqual(Exp4, to_international(Addr4, false, <<"333">>)).

to_international_other_test() ->
    Addr1 = #addr{addr = <<"067 5643">>, ton = 0, npi = 1},
    Exp1 = #addr{addr = <<"0675643">>, ton = 0, npi = 1},
    ?assertEqual(Exp1, to_international(Addr1, false, <<"999">>)),
    Addr2 = #addr{addr = <<"067 5643">>, ton = 2, npi = 1},
    Exp2 = #addr{addr = <<"777675643">>, ton = 1, npi = 1},
    ?assertEqual(Exp2, to_international(Addr2, true, <<"777">>)).

strip_non_digits_test() ->
    ?assertEqual(<<"4031888111">>, strip_non_digits(<<"(+40) 31 888-111">>)),
    ?assertEqual(<<"375296761221">>, strip_non_digits(<<"+375 29 676 1221">>)),
    ?assertEqual(<<"12345678910">>, strip_non_digits(<<"12345678910">>)).

flatten_networks_wo_default_provider_id_test() ->
    Networks = [
        #network_dto{
            id = <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
            country_code = <<"444">>,
            number_len = 12,
            prefixes = [<<"296">>, <<"293">>],
            provider_id = <<"123">>
        },
        #network_dto{
            id = <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>,
            country_code = <<"555">>,
            number_len = 13,
            prefixes = [<<"2311">>, <<"3320">>],
            provider_id = <<"456">>
        }
    ],
    ?assertEqual([
        {<<"444293">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"123">>},
        {<<"444296">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"123">>},
        {<<"5552311">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"456">>},
        {<<"5553320">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"456">>}
    ], lists:sort(flatten_networks(Networks, undefined))).

flatten_networks_with_default_provider_id_test() ->
    Networks = [
        #network_dto{
            id = <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>,
            country_code = <<"444">>,
            number_len = 12,
            prefixes = [<<"296">>, <<"293">>],
            provider_id = <<"123">>
        },
        #network_dto{
            id = <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>,
            country_code = <<"555">>,
            number_len = 13,
            prefixes = [<<"2311">>, <<"3320">>],
            provider_id = <<"456">>
        }
    ],
    ?assertEqual([
        {<<"444293">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"999">>},
        {<<"444296">>, 12, <<"b8a55c6d-9ea6-43a8-bf70-b1c34eb4a8fe">>, <<"999">>},
        {<<"5552311">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"999">>},
        {<<"5553320">>, 13, <<"d9f043d7-8cb6-4a53-94a8-4789da444f18">>, <<"999">>}
    ], lists:sort(flatten_networks(Networks, <<"999">>))).

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
