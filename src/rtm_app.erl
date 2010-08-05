-module(rtm_app).
-behaviour(application).
-export([start/2, stop/1]).

-define(DEFAULT_PORT, 1179).

start(_Type, _Args) ->
  Port =
    case application:get_env(routemachine, listen_port) of
      {ok, ConfigPort} -> ConfigPort;
      undefined        -> ?DEFAULT_PORT
    end,
  rtm_sup:start_link(Port).

stop(_State) ->
  ok.
