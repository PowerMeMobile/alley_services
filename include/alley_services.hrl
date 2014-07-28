-ifndef(alley_services_hrl).
-define(alley_services_hrl, defined).

-include_lib("alley_dto/include/adto.hrl").

-type auth_resp()   :: #k1api_auth_response_dto{}.
-type provider_id() :: binary().
-type gateway_id()  :: binary().

-record(send_req, {
    action       :: atom(),
    customer     :: undefined | auth_resp(),
    customer_id  :: undefined | binary(),
    user_name    :: undefined | binary(),
    client_type  :: atom(),
    originator   :: undefined | binary(),
    recipients   :: [#addr{}],
    text         :: undefined | binary(),
    type         :: undefined | binary(),
    def_date     :: undefined | binary(),
    flash        :: undefined | boolean(),
    smpp_params = [] :: [{binary(), binary() | boolean() | integer()}],
    encoding     :: undefined | default | ucs2,
    encoded      :: undefined | binary(),
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
    protocol_id  :: undefined | binary()
}).

-record(send_result, {
    result       :: undefined | atom(),
    req_id       :: undefined | binary(),
    rejected     :: undefined | list()
}).

-define(serverUnreachable, <<"Server cannot be reached">>).
-define(authError, <<"Access denied. Check your account settings">>).
-define(originatorNotAllowedError, <<"Specified originator is not allowed">>).
-define(noAnyDestAddrError, <<"None recipient is specified or available due to your permissions">>).
-define(invalidDefDateFormatError,
        <<"defDate is invalid. defDate format is UTC MM/DD/YYYY HH:MM">>).
-define(postpaidCreditLimitExceeded, <<"Customer's postpaid credit limit is exceeded">>).
-define(prepaidCreditLimitInsufficient, <<"Customer's prepaid credit limit is insufficient">>).
-define(blinkNotSupported, <<"Blink messages are not supported">>).
-define(privateNotSupported, <<"Private messages are not supported">>).
-define(serviceNameAndUrlExpected, <<"Service name and url is expected">>).

-record('DOWN',{
    ref            :: reference(),
    type = process :: process,
    object         :: pid(),
    info           :: term() | noproc | noconnection
}).

-endif. % alley_services.hrl
