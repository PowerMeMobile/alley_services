-ifndef(alley_services_hrl).
-define(alley_services_hrl, defined).

-include_lib("alley_dto/include/adto.hrl").

-type customer()    :: #auth_customer_v1{}.
-type provider_id() :: binary().
-type gateway_id()  :: binary().

-record(send_req, {
    action       :: atom(),
    customer     :: undefined | customer(),
    customer_id  :: undefined | binary(),
    user_id      :: undefined | binary(),
    client_type  :: atom(),
    originator   :: undefined | binary(),
    recipients   :: [#addr{}],
    message      :: undefined | binary(),
    messages     :: undefined | [binary()],
    def_date     :: undefined | binary(),
    flash        :: undefined | boolean(),
    smpp_params = [] :: [{binary(), binary() | boolean() | integer()}],
    encoding     :: undefined | default | ucs2,
    encoded_size :: undefined | non_neg_integer(),
    coverage_tab :: undefined | ets:tid(),
    routable     :: undefined | [{provider_id() | gateway_id(), [#addr{}]}],
    rejected     :: undefined | [#addr{}],
    req_dto_s    :: undefiend | [#just_sms_request_dto{}],

    %% send_service_sms extention
    s_name       :: undefined | binary(),
    s_url        :: undefined | binary(),

    %% send_binary_sms extention
    binary_body  :: undefined | binary(),
    data_coding  :: undefined | binary(),
    esm_class    :: undefined | binary(),
    protocol_id  :: undefined | binary(),

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
