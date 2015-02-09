-module(alley_services_utils).

-export([
    addr_to_dto/1,
    calc_parts_number/2
]).

%-define(TEST, 1).
-ifdef(TEST).
    -compile(export_all).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("alley_dto/include/adto.hrl").

-define(TON_UNKNOWN,       0).
-define(TON_INTERNATIONAL, 1).
-define(TON_NATIONAL,      2).
-define(TON_ALPHANUMERIC,  5).
-define(TON_ABBREVIATED,   6).

-define(NPI_UNKNOWN,       0).
-define(NPI_ISDN,          1). % E163/E164

%% ===================================================================
%% API
%% ===================================================================

-spec addr_to_dto(Addr::binary()) -> #addr{}.
addr_to_dto(Addr) when is_binary(Addr) ->
    IsInteger =
        try binary_to_integer(Addr) of
            _ -> true
        catch
            _:_ -> false
        end,
    Length = size(Addr),
    addr_to_dto(Addr, IsInteger, Length).

addr_to_dto(Addr, true, Length) when Length < 7 -> % 1..6
    #addr{
        addr = Addr,
        ton = ?TON_ABBREVIATED,
        npi = ?NPI_UNKNOWN
    };
addr_to_dto(Addr, true, _Length) -> % 7..
    #addr{
        addr = Addr,
        ton = ?TON_INTERNATIONAL,
        npi = ?NPI_ISDN
    };
addr_to_dto(Addr, false, _Length) ->
    #addr{
        addr = Addr,
        ton = ?TON_ALPHANUMERIC,
        npi = ?NPI_UNKNOWN
    }.

-spec calc_parts_number(pos_integer(), default | ucs) -> pos_integer().
calc_parts_number(Size, default) when Size =< 160 ->
    1;
calc_parts_number(Size, default) ->
    case (Size rem 153) == 0 of
        true ->  trunc(Size/153);
        false -> trunc(Size/153) + 1
    end;
calc_parts_number(Size, ucs2) when Size =< 70 ->
    1;
calc_parts_number(Size, ucs2) ->
    case (Size rem 67) == 0 of
        true ->  trunc(Size/67);
        false -> trunc(Size/67) + 1
    end.

%% ===================================================================
%% Begin Tests
%% ===================================================================

-ifdef(TEST).

addr_to_dto_test() ->
    Addr_11 = <<"375296543210">>,
    Addr1_60 = <<"1">>,
    Addr2_60 = <<"123456">>,
    Addr_50 = <<"anything">>,
    ?assertEqual(#addr{addr= <<"375296543210">>,ton=1,npi=1}, addr_to_dto(Addr_11)),
    ?assertEqual(#addr{addr= <<"1">>,ton=6,npi=0}, addr_to_dto(Addr1_60)),
    ?assertEqual(#addr{addr= <<"123456">>,ton=6,npi=0}, addr_to_dto(Addr2_60)),
    ?assertEqual(#addr{addr= <<"anything">>,ton=5,npi=0}, addr_to_dto(Addr_50)).

calc_parts_number_default_test() ->
    ?assertEqual(1, calc_parts_number(160, default)),
    ?assertEqual(2, calc_parts_number(161, default)),
    ?assertEqual(2, calc_parts_number(306, default)),
    ?assertEqual(3, calc_parts_number(307, default)),
    ?assertEqual(3, calc_parts_number(459, default)),
    ?assertEqual(4, calc_parts_number(460, default)).

calc_parts_number_ucs2_test() ->
    ?assertEqual(1, calc_parts_number(70, ucs2)),
    ?assertEqual(2, calc_parts_number(71, ucs2)),
    ?assertEqual(2, calc_parts_number(134, ucs2)),
    ?assertEqual(3, calc_parts_number(135, ucs2)),
    ?assertEqual(3, calc_parts_number(201, ucs2)),
    ?assertEqual(4, calc_parts_number(202, ucs2)).

-endif.

%% ===================================================================
%% End Tests
%% ===================================================================
