-ifndef(alley_services_hrl).
-define(alley_services_hrl, defined).

-include_lib("alley_dto/include/adto.hrl").

-type customer()    :: #auth_customer_v1{}.
-type provider_id() :: binary().
-type gateway_id()  :: binary().

-record(send_req, {
    customer     :: customer(),
    customer_id  :: binary(),
    user_id      :: binary(),
    interface    :: atom(),
    originator   :: #addr{},
    recipients   :: [#addr{}],

    req_type     :: single | multiple,

    %% batch message or custom tags message
    message      :: binary(),

    encoding     :: default | ucs2,
    size         :: non_neg_integer(),
    params       :: [{binary(), binary() | boolean() | integer()}],

    %% multiple (custom tags)
    message_map  :: undefined | [{#addr{}, binary()}],
    size_map     :: undefined | [{#addr{}, non_neg_integer()}],

    def_time     :: undefined | utc_timestamp(),

    coverage_tab :: ets:tid(),
    routable     :: [{provider_id() | gateway_id(), [#addr{}]}],
    rejected     :: [#addr{}],
    req_dto_s    :: [#sms_req_v1{}],

    credit_left  :: float()
}).

-record(send_result, {
    result       :: atom(),
    req_id       :: binary(),
    rejected     :: [#addr{}],
    customer     :: customer(),
    credit_left  :: float()
}).

-record('DOWN',{
    ref            :: reference(),
    type = process :: process,
    object         :: pid(),
    info           :: term() | noproc | noconnection
}).

-endif. % alley_services.hrl
