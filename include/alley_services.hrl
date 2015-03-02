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

    req_type     :: one_to_many | one_to_one,

    %% batch message or custom tags message
    message      :: binary(),

    %% one_to_many
    encoding     :: undefined | default | ucs2,
    size         :: undefined | non_neg_integer(),
    params       :: undefined | [{binary(), binary() | boolean() | integer()}],

    %% one_to_one (custom tags)
    message_map  :: undefined | [{#addr{}, binary()}],
    encoding_map :: undefined | [{#addr{}, default | ucs2}],
    size_map     :: undefined | [{#addr{}, non_neg_integer()}],
    params_map   :: undefined | [{#addr{}, [{binary(), binary() | boolean() | integer()}]}],

    def_date     :: undefined | binary(),

    coverage_tab :: undefined | ets:tid(),
    routable     :: undefined | [{provider_id() | gateway_id(), [#addr{}]}],
    rejected     :: undefined | [#addr{}],
    req_dto_s    :: undefiend | [#sms_req_v1{}],

    credit_left  :: undefined | float()
}).

-record(send_result, {
    result       :: undefined | atom(),
    req_id       :: undefined | binary(),
    rejected     :: undefined | list(),
    customer     :: undefined | customer(),
    credit_left  :: undefined | float()
}).

-record('DOWN',{
    ref            :: reference(),
    type = process :: process,
    object         :: pid(),
    info           :: term() | noproc | noconnection
}).

-endif. % alley_services.hrl
