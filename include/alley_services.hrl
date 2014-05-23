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
    password     :: undefined | binary(),
    originator   :: undefined | binary(),
    recipients   :: undefined | binary(),
    text         :: undefined | binary(),
    type         :: undefined | binary(),
    def_date     :: undefined | binary(),
    flash        :: undefined | binary(),
    smpp_params  :: undefined | term(),
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

-define(authError, <<"Access denied. Check your account settings">>).
-define(originatorNotAllowedError, <<"Specified originator is not allowed">>).
-define(noAnyDestAddrError, <<"None recipient is specified or available due to your permissions">>).
-define(invalidDefDateFormatError,
        <<"defDate is invalid. defDate format is MM/DD/YYYY HH:MM">>).
-define(blinkNotSupported,
        <<"Blink messages are not supported">>).
-define(privateNotSupported,
        <<"Private messages are not supported">>).

-record('DOWN',{
    ref            :: reference(),
    type = process :: process,
    object         :: pid(),
    info           :: term() | noproc | noconnection
}).

-endif. % alley_services.hrl