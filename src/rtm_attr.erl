-module(rtm_attr).
-export([get/3, fold/3]).
-export([attrs_to_binary/1, to_binary/1]).
-export([update_for_ebgp/5, update_for_ibgp/3]).
-export([origin/1, next_hop/1, med/1, empty_as_path/0]).

-include_lib("bgp.hrl").

-spec get(bgp_path_attr_type_code(), bgp_path_attrs(), term()) -> none | term().
get(Attr, PathAttrs, Default) ->
  case dict:find(Attr, PathAttrs) of
    {ok, [#bgp_path_attr{value = Value}]} -> Value;
    error -> Default
  end.

-spec fold(fun((bgp_path_attr_type_code(), #bgp_path_attr{}, any()) -> any()),
           any(), bgp_path_attrs()) -> any().
fold(Fun, Init, Attrs) ->
  dict:fold(fun(TypeCode, [Attr], Acc) ->
    Fun(TypeCode, Attr, Acc)
  end, Init, Attrs).

-spec attrs_to_binary(bgp_path_attrs()) -> binary().
attrs_to_binary(Attrs) ->
  AttrList =
    dict:fold(fun(_Type, [#bgp_path_attr{extended = Extended} = Attr], Acc) ->
      {Type, Len, Val} = to_binary(Attr),
      L = (to_bit(Extended) + 1) * 8,
      [<< Type:16,Len:L,Val:Len/binary >> | Acc]
    end, [], Attrs),
  list_to_binary(AttrList).

-spec to_binary(#bgp_path_attr{}) ->
        {bgp_path_attr_type_code(), uint16(), binary()}.
to_binary(#bgp_path_attr{optional   = Optional,
                         transitive = Transitive,
                         partial    = Partial,
                         extended   = Extended,
                         type_code  = TypeCode,
                         length     = Len,
                         binary     = Val}) ->
  <<Type:16>> =
    <<
       (to_bit(Optional)):1,
       (to_bit(Transitive)):1,
       (to_bit(Partial)):1,
       (to_bit(Extended)):1,
       0:4,
       TypeCode:8
    >>,
  {Type, Len, Val}.

-spec update_for_ebgp(bgp_path_attr_type_code(), #bgp_path_attr{},
                      bgp_path_attrs(), uint16(), uint32()) ->
        bgp_path_attrs().
update_for_ebgp(TypeCode, Attr, PathAttrs, Asn, Addr) ->
  case TypeCode of
    ?BGP_PATH_ATTR_AS_PATH ->
      NewASPath = prepend_asn(Asn, Attr),
      dict:store(?BGP_PATH_ATTR_AS_PATH, [NewASPath], PathAttrs);
    ?BGP_PATH_ATTR_NEXT_HOP ->
      NewNextHop = next_hop(Addr),
      dict:store(?BGP_PATH_ATTR_NEXT_HOP, [NewNextHop], PathAttrs);
    _ ->
      PathAttrs
  end.

-spec update_for_ibgp(bgp_path_attr_type_code(), #bgp_path_attr{},
                      bgp_path_attrs()) -> bgp_path_attrs().
update_for_ibgp(TypeCode, Attr, PathAttrs) ->
  case TypeCode of
    ?BGP_PATH_ATTR_MED ->
      dict:store(?BGP_PATH_ATTR_MED, [Attr], PathAttrs);
    ?BGP_PATH_ATTR_LOCAL_PREF ->
      dict:store(?BGP_PATH_ATTR_LOCAL_PREF, [Attr], PathAttrs);
    _ ->
      PathAttrs
  end.

origin(Origin) ->
  build(?BGP_PATH_ATTR_ORIGIN, <<Origin:8>>, [transitive]).

empty_as_path() ->
  build(?BGP_PATH_ATTR_AS_PATH, <<>>, [transitive]).

next_hop(Addr) ->
  build(?BGP_PATH_ATTR_NEXT_HOP, <<Addr:32>>, [transitive]).

med(Med) ->
  build(?BGP_PATH_ATTR_MED, <<Med:32>>, [optional]).

build(TypeCode, Bin, Flags) ->
  Length = byte_size(Bin),
  InitAttr = #bgp_path_attr{
    optional   = false,
    transitive = false,
    partial    = false,
    extended   = is_extended(Length),
    type_code  = TypeCode,
    length     = Length,
    binary     = Bin
  },
  lists:foldl(fun(Flag, Acc) ->
    case Flag of
      optional   -> Acc#bgp_path_attr{optional   = true};
      transitive -> Acc#bgp_path_attr{transitive = true};
      partial    -> Acc#bgp_path_attr{partial    = true};
      extended   -> Acc#bgp_path_attr{extended   = true}
    end
  end, InitAttr, Flags).

prepend_asn(Asn, #bgp_path_attr{extended  = Extended,
                                type_code = ?BGP_PATH_ATTR_AS_PATH,
                                binary    = Path} = ASPath) ->
  NewPath = case Path of
    << ?BGP_AS_PATH_SEQUENCE:8, N:8, FirstAsn:16, Rest/binary >> ->
      << ?BGP_AS_PATH_SEQUENCE:8, (N+1):8, Asn:16, FirstAsn:16, Rest/binary >>;
    << ?BGP_AS_PATH_SET:8, _Rest/binary >> ->
      << ?BGP_AS_PATH_SEQUENCE:8, 1:8, Asn:16, Path/binary >>;
    << >> ->
      << ?BGP_AS_PATH_SEQUENCE:8, 1:8, Asn:16 >>
  end,
  Length = byte_size(NewPath),
  ASPath#bgp_path_attr{
    extended  = Extended orelse is_extended(Length),
    length    = Length,
    binary    = NewPath
  }.

to_bit(false) -> 0;
to_bit(true)  -> 1.

is_extended(Length) -> Length > 255.
