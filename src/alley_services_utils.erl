-module(alley_services_utils).

-export([
    addr_to_dto/1,
    get_message_parts/2
]).

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

-spec get_message_parts(pos_integer(), default | ucs) -> pos_integer().
get_message_parts(Size, default) when Size =< 160 ->
    1;
get_message_parts(Size, default) ->
    case (Size rem 153) == 0 of
        true ->  trunc(Size/153);
        false -> trunc(Size/153) + 1
    end;
get_message_parts(Size, ucs2) when Size =< 70 ->
    1;
get_message_parts(Size, ucs2) ->
    case (Size rem 67) == 0 of
        true ->  trunc(Size/67);
        false -> trunc(Size/67) + 1
    end.
