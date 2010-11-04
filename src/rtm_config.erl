-module(rtm_config).
-export([parse/1, peers/1, get/2, get/3, networks/1]).

-include_lib("bgp.hrl").
-include_lib("session.hrl").

-type(conf() :: [term()]).

-spec parse(file:name()) -> conf().
parse(File) ->
  {ok, Conf} = file:consult(File),
  Conf.

-spec peers(conf()) -> [#session{}].
peers(Conf) ->
  {local, Local} = get(local, Conf),
  Peers = get_all(peer, Conf),
  build_session(Local, Peers).

-spec networks(conf()) -> [prefix()].
networks(Conf) ->
  {local, Local} = get(local, Conf),
  lists:map(fun({Net, Len}) ->
    {rtm_util:ip_to_num(Net), Len}
  end, get_all(network, Local)).

-spec get(atom(), conf()) -> none | tuple().
get(Key, Conf) ->
  proplists:lookup(Key, Conf).

-spec get(atom(), conf(), term()) -> term().
get(Key, Conf, Default) ->
  proplists:get_value(Key, Conf, Default).

get_all(Key, Conf) ->
  proplists:get_all_values(Key, Conf).

build_session(Local, Peers) ->
  build_session(Local, Peers, []).

build_session(_Local, [], Sessions) ->
  Sessions;
build_session(Local, [Peer | Rest], Sessions) ->
  {asn, LocalAsn}      = get(asn, Local),
  {address, LocalAddr} = get(address, Local),
  {asn, PeerAsn}       = get(asn, Peer),
  {address, PeerAddr}  = get(address, Peer),
  Session = #session{
    local_asn       = LocalAsn,
    local_addr      = LocalAddr,
    peer_asn        = PeerAsn,
    peer_addr       = PeerAddr,
    % TODO Make sure we have installed routes for the configured networks
    % in the Loc-RIB, and add the proper entries in rtm_rib.
    hold_time       = get(hold_time, Peer, ?BGP_TIMER_HOLD),
    keepalive_time  = get(keepalive_time, Peer, ?BGP_TIMER_KEEPALIVE),
    conn_retry_time = get(conn_retry_time, Peer, ?BGP_TIMER_CONN_RETRY),
    idle_time       = get(idle_time, Peer, ?BGP_TIMER_IDLE),
    establishment   = get(establishment, Peer, active)
  },
  build_session(Local, Rest, [Session | Sessions]).


