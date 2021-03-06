-ifndef(BGP_HRL).
-define(BGP_HRL, true).

-include_lib("types.hrl").

-define(BGP_PORT, 179).

% Lengths.
-define(BGP_HEADER_LENGTH,    19).
-define(BGP_MAX_MSG_LEN,    4096).

-define(BGP_OPEN_MIN_LENGTH,         29).
-define(BGP_UPDATE_MIN_LENGTH,       23).
-define(BGP_NOTIFICATION_MIN_LENGTH, 21).

% Message types.
-define(BGP_TYPE_OPEN,         1).
-define(BGP_TYPE_UPDATE,       2).
-define(BGP_TYPE_NOTIFICATION, 3).
-define(BGP_TYPE_KEEPALIVE,    4).

% Optional parameters.
-define(BGP_PARAM_AUTH_INFO,   1).

% Path attributes.
-define(BGP_PATH_ATTR_ORIGIN,      1).
-define(BGP_PATH_ATTR_AS_PATH,     2).
-define(BGP_PATH_ATTR_NEXT_HOP,    3).
-define(BGP_PATH_ATTR_MED,         4).
-define(BGP_PATH_ATTR_LOCAL_PREF,  5).
-define(BGP_PATH_ATTR_ATOMIC_AGGR, 6).
-define(BGP_PATH_ATTR_AGGREGATOR,  7).

% Path attribute values.
-define(BGP_ORIGIN_IGP,        0).
-define(BGP_ORIGIN_EGP,        1).
-define(BGP_ORIGIN_INCOMPLETE, 2).

% AS_PATH types.
-define(BGP_AS_PATH_SET,      1).
-define(BGP_AS_PATH_SEQUENCE, 2).

% Error codes
-define(BGP_ERR_HEADER,    1).
-define(BGP_ERR_OPEN,      2).
-define(BGP_ERR_UPDATE,    3).
-define(BGP_ERR_HOLD_TIME, 4).
-define(BGP_ERR_FSM,       5).
-define(BGP_ERR_CEASE,     6).

% Header error subcodes.
-define(BGP_HEADER_ERR_SYNC,   1).
-define(BGP_HEADER_ERR_LENGTH, 2).
-define(BGP_HEADER_ERR_TYPE,   3).

% OPEN error subcodes.
-define(BGP_OPEN_ERR_VERSION,   1).
-define(BGP_OPEN_ERR_PEER_AS,   2).
-define(BGP_OPEN_ERR_BGP_ID,    3).
-define(BGP_OPEN_ERR_OPT_PARAM, 4).
-define(BGP_OPEN_ERR_AUTH_FAIL, 5).
-define(BGP_OPEN_ERR_HOLD_TIME, 6).

% UPDATE error subcodes.
-define(BGP_UPDATE_ERR_ATTR_LIST,    1).
-define(BGP_UPDATE_ERR_ATTR_UNRECOG, 2).
-define(BGP_UPDATE_ERR_ATTR_MISSING, 3).
-define(BGP_UPDATE_ERR_ATTR_FLAGS,   4).
-define(BGP_UPDATE_ERR_ATTR_LENGTH,  5).
-define(BGP_UPDATE_ERR_ORIGIN,       6).
-define(BGP_UPDATE_ERR_LOOP,         7).
-define(BGP_UPDATE_ERR_NEXT_HOP,     8).
-define(BGP_UPDATE_ERR_OPT_ATTR,     9).
-define(BGP_UPDATE_ERR_NETWORK,      10).
-define(BGP_UPDATE_ERR_AS_PATH,      11).

% BGP timers.
-define(BGP_TIMER_CONN_RETRY, 120).
-define(BGP_TIMER_HOLD,        90).
-define(BGP_TIMER_HOLD_MIN,    30).
-define(BGP_TIMER_KEEPALIVE,   30).
-define(BGP_TIMER_IDLE,        60).

-define(BGP_INTERVAL_MIN_AS_ORIG,   15).
-define(BGP_INTERVAL_MIN_ROUTE_ADV, 30).

%
% Messages
%

-record(bgp_header, {
  marker   :: non_neg_integer(),
  msg_len  :: bgp_msg_len(),
  msg_type :: bgp_msg_type()
}).

-record(bgp_opt_param, {
  type    :: byte(),
  length  :: byte(),
  value   :: binary()
}).

-record(bgp_open, {
  version        :: byte(),
  asn            :: uint16(),
  hold_time      :: uint16(),
  bgp_id         :: uint32(),
  opt_params_len :: byte(),
  opt_params     :: [#bgp_opt_param{}]
}).

-record(bgp_update,{
  unfeasible_len   :: uint16(),
  attrs_len        :: uint16(),
  withdrawn_routes :: [prefix()],
  path_attrs       :: bgp_path_attrs(),
  nlri             :: [prefix()]
}).

-record(bgp_path_attr, {
  optional   :: boolean(),
  transitive :: boolean(),
  partial    :: boolean(),
  extended   :: boolean(),
  type_code  :: bgp_path_attr_type_code(),
  length     :: uint16(),
  value      :: any(),
  binary     :: binary()
}).

-record(bgp_notification, {
  error_string
}).

%
% Binary patterns.
%

-define(BGP_HEADER_MARKER, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).

-define(BGP_HEADER_PATTERN,
  << Marker        : 128,
     MessageLength : 16,
     MessageType   : 8 >>).

-define(BGP_OPEN_PATTERN,
  << Version      : 8,
     Asn          : 16,
     HoldTime     : 16,
     BgpId        : 32,
     OptParamsLen : 8,
     OptParams    : OptParamsLen/binary >>).

-define(BGP_UPDATE_PATTERN,
  << UnfeasableLength    : 16,
     WithdrawnRoutes     : UnfeasableLength/binary,
     TotalPathAttrLength : 16,
     PathAttrs           : TotalPathAttrLength/binary,
     NLRI/binary >>).

-define(BGP_NOTIFICATION_PATTERN,
  << ErrorCode    : 8,
     ErrorSubCode : 8,
     ErrorData/binary >>).

-define(BGP_OPT_PARAMS_PATTERN,
  << ParamType   : 8,
     ParamLength : 8,
     ParamValue  : ParamLength/binary,
     OtherParams/binary >>).

-define(BGP_PARAM_AUTH_INFO_PATTERN,
  << AuthCode : 8,
     AuthData/binary >>).

-define(BGP_PATH_ATTRS_PATTERN,
  << AttrOptional   : 1,
     AttrTransitive : 1,
     AttrPartial    : 1,
     AttrExtended   : 1,
     0              : 4,  % unused bits
     % Can't do it all in one match because of the extended bit role in
     % defining the attribute length.
     AttrRest/binary >>).

-define(BGP_PATH_ATTR_AS_PATH_PATTERN,
  << PathType   : 8,
     PathLength : 8,
     PathAsns   : PathLength/binary-unit:16,
     OtherPaths/binary >>).

-define(BGP_PREFIX_PATTERN,
  << PrefixLength : 8,
     Prefix       : PrefixLength,
     OtherPrefixes/binary >>).

%
% Types.
%

-type bgp_msg_type()     :: ?BGP_TYPE_OPEN..?BGP_TIMER_KEEPALIVE.
-type bgp_msg_len()      :: ?BGP_HEADER_LENGTH..?BGP_MAX_MSG_LEN.

-type bgp_path_attrs()   :: dict().
-type bgp_path_attr_type_code() ::
        ?BGP_PATH_ATTR_ORIGIN..?BGP_PATH_ATTR_AGGREGATOR.

-type bgp_origin()       :: ?BGP_ORIGIN_IGP..?BGP_ORIGIN_INCOMPLETE.

-type bgp_error_code()   :: ?BGP_ERR_HEADER..?BGP_ERR_CEASE.
-type bgp_error()        :: {bgp_error_code(), byte(), binary()}
                          | {bgp_error_code(), byte()}
                          | bgp_error_code().

-endif.
