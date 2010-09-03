-module(rtm_fsm).
-behaviour(gen_fsm).

-export([start_link/1]).
-export([init/1]).

% BGP FSM states.
-export([idle/2, connect/2, active/2, open_sent/2, open_confirm/2,
         established/2]).

% Exports for gen_fsm.
-export([terminate/3]).

-include_lib("bgp.hrl").

start_link(Establishment) ->
  gen_fsm:start_link(?MODULE, Establishment, []).

init(Establishment) ->
  io:format("Starting FSM ~w~n", [self()]),
  Session = #session{establishment   = Establishment,
                     hold_time       = ?BGP_TIMER_HOLD,
                     keepalive_time  = ?BGP_TIMER_KEEPALIVE,
                     conn_retry_time = ?BGP_TIMER_CONN_RETRY},
  {ok, idle, Session}.

%
% BGP FSM.
%

% Idle state.

idle(start, #session{establishment = Establishment} = Session) ->
  ConnRetry = start_timer(conn_retry, Session#session.conn_retry_time),
  NewSession = Session#session{conn_retry_timer = ConnRetry},
  case Establishment of
    active ->
      io:format("FSM:idle/start(active)~n"),
      EstabSession = connect_to_peer(NewSession),
      {next_state, connect, EstabSession};
    {passive, Socket} ->
      io:format("FSM:idle/start(passive)~n"),
      {ok, Pid} = rtm_server_sup:start_child(self()),
      gen_tcp:controlling_process(Socket, Pid),
      {next_state, active, NewSession#session{server = Pid}}
  end;

idle(_Error, Session) ->
  % TODO exponential backoff for reconnection attempt.
  NewSession = close_connection(Session),
  {next_state, idle, NewSession}.


% Connect state.

connect(start, Session) ->
  {next_state, connect, Session};

connect(tcp_open, Session) ->
  clear_timer(Session#session.conn_retry_timer),
  send_open(Session),
  {next_state, active, Session};

connect(tcp_open_failed, Session) ->
  ConnRetry = restart_timer(conn_retry, Session),
  NewSession = close_connection(Session),
  {next_state, active, NewSession#session{conn_retry_timer = ConnRetry}};

connect({timeout, _Ref, conn_retry}, Session) ->
  ConnRetry = restart_timer(conn_retry, Session),
  NewSession = connect_to_peer(Session#session{conn_retry_timer = ConnRetry}),
  {next_state, connect, NewSession};

connect(_Event, Session) ->
  {stop, normal, Session}.


% Active state.

active(start, Session) ->
  {next_state, active, Session};

active(tcp_open, Session) ->
  case check_peer(Session) of
    ok ->
      clear_timer(Session#session.conn_retry_timer),
      send_open(Session),
      HoldTimer = start_timer(hold, Session#session.hold_time),
      {next_state, open_sent, Session#session{hold_timer = HoldTimer}};
    bad_peer ->
      ConnRetry = restart_timer(conn_retry, Session),
      NewSession =
        close_connection(Session#session{conn_retry_timer = ConnRetry}),
      {next_state, active, NewSession}
  end;

active({timeout, _Ref, conn_retry}, Session) ->
  ConnRetry = restart_timer(conn_retry, Session),
  NewSession = connect_to_peer(Session#session{conn_retry_timer = ConnRetry}),
  {next_state, connect, NewSession};

active(_Event, Session) ->
  {stop, normal, Session}.


% OpenSent state

open_sent(start, Session) ->
  {next_state, open_sent, Session};

open_sent(stop, Session) ->
  send_notification(Session, ?BGP_ERR_CEASE),
  {stop, normal, Session};

open_sent({open_received, Bin}, Session) ->
  case rtm_parser:parse_open(Bin) of
    {ok, #bgp_open{asn = ASN, hold_time = HoldTime}} ->
      send_keepalive(Session),
      NewHoldTime = negotiate_hold_time(Session#session.hold_time, HoldTime),
      NewSession = start_timers(Session, NewHoldTime),
      {next_state, open_confirm, NewSession#session{remote_asn = ASN}};
    {error, Error} ->
      send_notification(Session, Error),
      {stop, normal, Session}
  end;

open_sent({timeout, _Ref, hold}, Session) ->
  send_notification(Session, ?BGP_ERR_HOLD_TIME),
  {stop, normal, Session};

open_sent(tcp_closed, Session) ->
  close_connection(Session),
  ConnRetry = restart_timer(conn_retry, Session),
  {next_state, active, Session#session{conn_retry_timer = ConnRetry}};

open_sent(tcp_fatal, Session) ->
  {stop, normal, Session};

open_sent(_Event, Session) ->
  send_notification(Session, ?BGP_ERR_FSM),
  {stop, normal, Session}.


% OpenConfirm state.

open_confirm(start, Session) ->
  {next_state, open_confirm, Session};

open_confirm(stop, Session) ->
  send_notification(Session, ?BGP_ERR_CEASE),
  {stop, normal, Session};

open_confirm(keepalive_received, Session) ->
  {next_state, established, Session};

open_confirm({timeout, hold}, Session) ->
  send_notification(Session, ?BGP_ERR_HOLD_TIME),
  {next_state, idle, Session};

open_confirm({notification_received, _Bin}, Session) ->
  % TODO parse notification.
  {next_state, idle, Session};

open_confirm({timeout, keepalive}, Session) ->
  KeepAlive = restart_timer(keepalive, Session),
  send_keepalive(Session),
  {next_state, open_confirm, Session#session{keepalive_timer = KeepAlive}};

open_confirm(tcp_closed, Session) ->
  {stop, normal, Session};

open_confirm(tcp_fatal, Session) ->
  {stop, normal, Session};

open_confirm(_Event, Session) ->
  send_notification(Session, ?BGP_ERR_FSM),
  {stop, normal, Session}.


% Established state.

established(start, Session) ->
  {next_state, established, Session};

established(stop, Session) ->
  send_notification(Session, ?BGP_ERR_CEASE),
  {stop, stop, Session};

established({update_received, Bin, Len}, Session) ->
  Hold = restart_timer(hold, Session),
  NewSession = Session#session{hold_timer = Hold},
  case rtm_parser:parse_update(Bin, Len) of
    {ok, _Msg} ->
      % TODO handle update - section 6.3.
      {next_state, established, NewSession};
    {error, _Error} ->
      send_notification(NewSession, ?BGP_ERR_UPDATE),
      {stop, normal, NewSession}
  end;

established(keepalive_received, Session) ->
  Hold = restart_timer(hold, Session),
  {next_state, established, Session#session{hold_timer = Hold}};

established({notification_received, _Bin}, Session) ->
  % TODO parse notification.
  {stop, normal, Session};

established({timeout, hold}, Session) ->
  send_notification(Session, ?BGP_ERR_HOLD_TIME),
  {stop, normal, Session};

established({timeout, keepalive}, Session) ->
  KeepAlive = restart_timer(keepalive, Session),
  send_keepalive(Session),
  {next_state, established, Session#session{keepalive_timer = KeepAlive}};

established(tcp_closed, Session) ->
  {stop, normal, Session};

established(tcp_fatal, Session) ->
  {stop, normal, Session};

established(_Event, Session) ->
  send_notification(Session, ?BGP_ERR_FSM),
  % TODO delete_routes(Session),
  {stop, normal, Session}.


%
% gen_fsm callbacks.
%
terminate(_Reason, _StateName, Session) ->
  release_resources(Session),
  ok.

%
% Internal functions.
%

restart_timer(conn_retry, Session) ->
  clear_timer(Session#session.conn_retry_timer),
  start_timer(conn_retry, Session#session.conn_retry_time);

restart_timer(keepalive, Session) ->
  clear_timer(Session#session.keepalive_timer),
  start_timer(keepalive, Session#session.keepalive_time);

restart_timer(hold, #session{hold_time = HoldTime} = Session) ->
  clear_timer(Session#session.hold_timer),
  case HoldTime > 0 of
    true  -> start_timer(keepalive, Session#session.keepalive_time);
    false -> undefined
  end.

start_timer(Name, Time) ->
  gen_fsm:start_timer(Time, Name).

clear_timer(undefined) ->
  false;
clear_timer(Timer) ->
  gen_fsm:cancel_timer(Timer).

% Instead of implementing collision detection, just make sure there's
% only one connection per peer. This is what OpenBGPd does.
connect_to_peer(#session{server      = undefined,
                         local_addr  = LocalAddr,
                         remote_addr = RemoteAddr} = Session) ->
  {ok, Pid} = rtm_server_sup:start_child(self()),
  SockOpts = [binary, {ip, LocalAddr}, {packet, raw}, {active, false}],
  case gen_tcp:connect(RemoteAddr, ?BGP_PORT, SockOpts) of
    {ok, Socket}     ->
      gen_tcp:controlling_process(Socket, Pid),
      gen_fsm:send_event(self(), tcp_open),
      Session#session{server = Pid};
    {error, _Reason} ->
      gen_fsm:send_event(self(), tcp_open_failed),
      Session
  end;

% There's already an associated server; ignore.
connect_to_peer(Session) ->
  Session.

close_connection(#session{server = Server} = Session) ->
  gen_server:cast(Server, close_connection),
  Session#session{server = undefined}.

release_resources(Session) ->
  NewSession = close_connection(Session),
  clear_timer(Session#session.conn_retry_timer),
  clear_timer(Session#session.hold_timer),
  clear_timer(Session#session.keepalive_timer),
  NewSession.

check_peer(#session{server = Server, remote_addr = RemoteAddr}) ->
  case gen_server:call(Server, peer_addr) of
    {ok, RemoteAddr} -> ok;
    {ok, _}          -> bad_peer
  end.

negotiate_hold_time(LocalHoldTime, RemoteHoldTime) ->
  HoldTime = min(LocalHoldTime, RemoteHoldTime),
  case HoldTime < ?BGP_TIMER_HOLD_MIN of
    true  -> 0;
    false -> HoldTime
  end.

start_timers(Session, 0) ->
  Session;
start_timers(Session, HoldTime) ->
  KeepAlive = start_timer(keepalive, Session#session.keepalive_time),
  Hold = start_timer(hold, HoldTime),
  Session#session{hold_time       = HoldTime,
                  hold_timer      = Hold,
                  keepalive_timer = KeepAlive}.


% Message sending.

send_open(#session{server     = Server,
                   local_asn  = ASN,
                   hold_time  = HoldTime,
                   local_addr = LocalAddr}) ->
  send(Server, rtm_msg:build_open(ASN, HoldTime, LocalAddr)).

send_notification(#session{server = Server}, Error) ->
  send(Server, rtm_msg:build_notification(Error)).

send_keepalive(#session{server = Server}) ->
  send(Server, rtm_msg:build_keepalive()).

send(Server, Bin) ->
  gen_server:cast(Server, {send_msg, Bin}).
