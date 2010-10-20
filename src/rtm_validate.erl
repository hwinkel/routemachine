-module(rtm_validate).

-include_lib("bgp.hrl").

-export([header/1, open/4, update/3]).

-spec header(bgp_header()) -> ok | {error, bgp_error()}.
header(Hdr) ->
  validate(Hdr, ?BGP_ERR_HEADER,
           [fun validate_marker/1,
            fun validate_msg_len/1,
            fun validate_type/1]).

-spec open(bgp_open(), non_neg_integer(), uint16(), ipv4_address()) ->
               ok | {error, bgp_error()}.
open(Msg, Marker, ConfigASN, ConfigID) ->
  validate(Msg, ?BGP_ERR_OPEN,
           [fun validate_version/1,
            fun(M) -> validate_asn(M, ConfigASN) end,
            fun validate_hold_time/1,
            fun(M) -> validate_bgp_id(M, ConfigID) end,
            fun(M) -> validate_opt_params(M, Marker) end]).

-spec update(bgp_update(), bgp_msg_len(), uint16()) -> ok | {error,bgp_error()}.
update(Msg, MsgLen, LocalASN) ->
  validate(Msg, ?BGP_ERR_UPDATE,
           [fun(M) -> validate_update_length(M, MsgLen) end,
            fun(M) -> validate_path_attrs(M, LocalASN) end,
            fun validate_missing_well_known_attrs/1]).

%
% Internal functions.
%

% Header validation.

validate_marker(#bgp_header{msg_type = ?BGP_TYPE_OPEN,
                            marker = ?BGP_HEADER_MARKER}) ->
  ok;
validate_marker(#bgp_header{msg_type = ?BGP_TYPE_OPEN}) ->
  {error, ?BGP_HEADER_ERR_SYNC};
validate_marker(#bgp_header{}) ->
  ok.

validate_msg_len(#bgp_header{msg_type = ?BGP_TYPE_OPEN, msg_len = Len})
                 when Len >= ?BGP_OPEN_MIN_LENGTH andalso
                      Len =< ?BGP_MAX_MSG_LEN ->
  ok;
validate_msg_len(#bgp_header{msg_type = ?BGP_TYPE_UPDATE, msg_len = Len})
                 when Len >= ?BGP_UPDATE_MIN_LENGTH andalso
                      Len =< ?BGP_MAX_MSG_LEN ->
  ok;
validate_msg_len(#bgp_header{msg_type = ?BGP_TYPE_NOTIFICATION, msg_len = Len})
                 when Len >= ?BGP_NOTIFICATION_MIN_LENGTH andalso
                      Len =< ?BGP_MAX_MSG_LEN ->
  ok;
validate_msg_len(#bgp_header{msg_type = ?BGP_TYPE_KEEPALIVE, msg_len = Len})
                 when Len =:= ?BGP_HEADER_LENGTH ->
  ok;
validate_msg_len(#bgp_header{msg_len = Len}) ->
  {error, {?BGP_HEADER_ERR_LENGTH, <<Len:8>>}}.

validate_type(#bgp_header{msg_type = ?BGP_TYPE_OPEN})         -> ok;
validate_type(#bgp_header{msg_type = ?BGP_TYPE_UPDATE})       -> ok;
validate_type(#bgp_header{msg_type = ?BGP_TYPE_NOTIFICATION}) -> ok;
validate_type(#bgp_header{msg_type = ?BGP_TYPE_KEEPALIVE})    -> ok;
validate_type(#bgp_header{msg_type = Type}) ->
  {error, {?BGP_HEADER_ERR_TYPE, <<Type:8>>}}.

% OPEN message validation.

validate_version(#bgp_open{version = 4}) ->
  ok;
validate_version(#bgp_open{}) ->
  {error, {?BGP_OPEN_ERR_VERSION, <<4:16>>}}.

validate_asn(#bgp_open{asn = ASN}, ConfigASN) ->
  case ASN =:= ConfigASN of
    true  -> ok;
    false -> {error, ?BGP_OPEN_ERR_PEER_AS}
  end.

validate_hold_time(#bgp_open{hold_time = HoldTime}) when HoldTime < 3 ->
  {error, ?BGP_OPEN_ERR_PEER_AS};
validate_hold_time(#bgp_open{}) ->
  ok.

validate_bgp_id(#bgp_open{bgp_id = Id}, ConfigID) ->
  case Id =:= ConfigID of
    true  -> ok;
    false -> {error, ?BGP_OPEN_ERR_BGP_ID}
  end.

validate_opt_params(#bgp_open{opt_params = OptParams}, Marker) ->
  validate_params(OptParams, Marker).

validate_params([], _Marker) ->
  ok;
validate_params([#bgp_opt_param{type = Type, length = Len, value = Val} | Rest],
                Marker) ->
  validate_param(Type, Val, Len, Marker),
  validate_params(Rest, Marker).

validate_param(?BGP_PARAM_AUTH_INFO, ?BGP_PARAM_AUTH_INFO_PATTERN,
               Len, Marker) ->
  % TODO validate authentication info.
  {_,_,_,_} = {AuthCode, AuthData, Len, Marker},
  ok;
validate_param(_, _, _, _) ->
  {error, ?BGP_OPEN_ERR_OPT_PARAM}.


% UPDATE message validation.
% TODO optional attributes; NLRI.

validate_update_length(#bgp_update{unfeasible_len = ULen, attrs_len = ALen},
                       MsgLen) ->
  case ?BGP_UPDATE_MIN_LENGTH + ULen + ALen > MsgLen + ?BGP_HEADER_LENGTH of
    true  -> {error, ?BGP_UPDATE_ERR_ATTR_LIST};
    false -> ok
  end.

validate_path_attrs(#bgp_update{path_attrs = PathAttrs}, LocalASN) ->
  try
    dict:fold(fun(_Type, Attr, ok) ->
      validate_attr(Attr, LocalASN)
    end, ok, PathAttrs)
  catch
    throw:Error -> Error
  end.

validate_attr([Attr], LocalASN) ->
  Vs = [fun validate_flags/1,
        fun validate_attr_len/1,
        fun(A) -> validate_value(A, LocalASN) end],
  case validate(Attr, ?BGP_ERR_UPDATE, Vs) of
    ok -> ok;
    {error, {_, SubCode, Data}} -> throw({error, {SubCode, Data}})
  end;

validate_attr([_Attr | _More], _LocalASN) ->
  % Duplicate attribute.
  throw({error, ?BGP_UPDATE_ERR_ATTR_LIST}).


validate_flags(Attr) ->
  case Attr of
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_ORIGIN,
                   optional   = false,
                   transitive = true} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_AS_PATH,
                   optional   = false,
                   transitive = true} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_NEXT_HOP,
                   optional   = false,
                   transitive = true} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_MED,
                   optional   = true,
                   transitive = false} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_LOCAL_PREF,
                   optional   = false,
                   transitive = true} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_ATOMIC_AGGR,
                   optional   = false,
                   transitive = true} ->
      ok;
    #bgp_path_attr{type_code  = ?BGP_PATH_ATTR_AGGREGATOR,
                   optional   = true,
                   transitive = true} ->
      ok;
    #bgp_path_attr{optional = false} ->
      {error, {?BGP_UPDATE_ERR_ATTR_UNRECOG, rtm_attr:to_binary(Attr)}};
    _ ->
      {error, {?BGP_UPDATE_ERR_ATTR_FLAGS, rtm_attr:to_binary(Attr)}}
  end.

validate_attr_len(#bgp_path_attr{type_code = Type, length = Len} = Attr) ->
  case {Type, Len} of
    {?BGP_PATH_ATTR_ORIGIN,      1} -> ok;
    {?BGP_PATH_ATTR_AS_PATH,     _} -> ok;
    {?BGP_PATH_ATTR_NEXT_HOP,    4} -> ok;
    {?BGP_PATH_ATTR_MED,         4} -> ok;
    {?BGP_PATH_ATTR_LOCAL_PREF,  4} -> ok;
    {?BGP_PATH_ATTR_ATOMIC_AGGR, 0} -> ok;
    {?BGP_PATH_ATTR_AGGREGATOR,  6} -> ok;
    _ ->
      {error, {?BGP_UPDATE_ERR_ATTR_LENGTH, rtm_attr:to_binary(Attr)}}
  end.

validate_value(#bgp_path_attr{type_code = ?BGP_PATH_ATTR_ORIGIN,
                              value     = Val} = Attr, _)
               when Val > ?BGP_ORIGIN_INCOMPLETE ->
  {error, {?BGP_UPDATE_ERR_ORIGIN, rtm_attr:to_binary(Attr)}};

validate_value(#bgp_path_attr{type_code = ?BGP_PATH_ATTR_NEXT_HOP,
                              value     = Val} = Attr, _)
               when Val =:= 0 ->
  % XXX can any other syntatic validation be done?
  % TODO semantic validation for eBGP as in section 6.3.
  {error, {?BGP_UPDATE_ERR_NEXT_HOP, rtm_attr:to_binary(Attr)}};

validate_value(#bgp_path_attr{type_code = ?BGP_PATH_ATTR_AS_PATH,
                              value     = Val}, LocalASN) ->
  validate_as_path(Val, LocalASN);

validate_value(#bgp_path_attr{}, _) ->
  ok.

validate_as_path([], _LocalASN) ->
  ok;
validate_as_path([{Type, _ASN} | _Rest], _LocalASN)
                 when Type =/= ?BGP_AS_PATH_SET
                 andalso Type =/= ?BGP_AS_PATH_SEQUENCE ->
  {error, ?BGP_UPDATE_ERR_AS_PATH};
validate_as_path([{_Type, LocalASN} | _Rest], LocalASN) ->
  {error, ?BGP_UPDATE_ERR_LOOP};
validate_as_path([{_Type, _ASN} | Rest], LocalASN) ->
  validate_as_path(Rest, LocalASN).

validate_missing_well_known_attrs(#bgp_update{well_known_attrs = Flags}) ->
  check_well_known_flags(Flags, [?BGP_PATH_ATTR_ORIGIN,
                                 ?BGP_PATH_ATTR_AS_PATH,
                                 ?BGP_PATH_ATTR_NEXT_HOP,
                                 ?BGP_PATH_ATTR_LOCAL_PREF,
                                 ?BGP_PATH_ATTR_ATOMIC_AGGR]).

check_well_known_flags(_Flags, []) ->
  ok;
check_well_known_flags(Flags, [Type | Rest]) ->
  case flag_is_set(Type, Flags) of
    false -> {error, {?BGP_UPDATE_ERR_ATTR_MISSING, <<Type:8>>}};
    true  -> check_well_known_flags(Flags, Rest)
  end.

flag_is_set(Flag, Flags) ->
  Flags band Flag =/= 0.

validate(_Rec, _Code, []) ->
  ok;
validate(Rec, Code, [Validator | Rest]) ->
  case Validator(Rec) of
    ok -> validate(Rec, Code, Rest);
    {error, {SubCode, Data}} -> {error, {Code, SubCode, Data}};
    {error, SubCode} -> {error, {Code, SubCode, <<>>}}
  end.


