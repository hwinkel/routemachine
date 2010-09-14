-module(rtm_sup).

-export([start_link/2]).
-export([init/1]).

start_link(ListenPort, Peers) ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, {ListenPort, Peers}).

init({ListenPort, Peers}) ->
  SockOpts = [binary, {reuseaddr, true}, {packet, raw}, {active, false}],
  {ok, ListenSocket} = gen_tcp:listen(ListenPort, SockOpts),

  ChildSpecs = [
    {rtm_acceptor,
      {rtm_acceptor, start_link, [ListenSocket, Peers]},
      permanent,
      brutal_kill,
      worker,
      [rtm_acceptor]},

    {rtm_rib_mgr,
      {rtm_rib_mgr, start_link, []},
      permanent,
      2000,
      worker,
      [rtm_rib_mgr]},

    {rtm_rib_sup,
      {rtm_rib_sup, start_link, []},
      permanent,
      infinity,
      supervisor,
      [rtm_rib_sup]},

    {rtm_server_sup,
      {rtm_server_sup, start_link, []},
      permanent,
      infinity,
      supervisor,
      [rtm_server_sup]},

    {rtm_fsm_sup,
      {rtm_fsm_sup, start_link, []},
      permanent,
      infinity,
      supervisor,
      [rtm_fsm_sup]}
  ],

  {ok, {{one_for_one, 1, 1}, ChildSpecs}}.
