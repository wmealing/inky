%%%-------------------------------------------------------------------
%% @doc Supervisor for background sensors.
%%
%% Deliberately separate from inky_sup: a sensor whose hardware is
%% unplugged crash-loops, and under inky_sup's {one_for_one, 3, 5} that
%% would blow the restart intensity and take the bot and ollama_worker
%% down with it. Here it's isolated, with a looser intensity, and sensors
%% are `transient` so one that legitimately can't start (missing device,
%% no config) doesn't keep being retried.
%% @end
%%%-------------------------------------------------------------------

-module(inky_sensor_sup).
-behaviour(supervisor).

-export([start_link/0, sensors/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% Sensor modules to run. By default every module in the inky application
%% carrying `-behaviour(inky_sensor)` -- same auto-discovery as inky_tools
%% -- so adding a sensor is just adding a module. Set the `sensors` app env
%% to an explicit list to override (e.g. to disable one on a given host).
sensors() ->
    case application:get_env(inky, sensors) of
        {ok, Mods} when is_list(Mods) -> Mods;
        _ -> discover()
    end.

discover() ->
    case application:get_key(inky, modules) of
        {ok, Modules} -> lists:filter(fun is_sensor_module/1, Modules);
        undefined -> []
    end.

is_sensor_module(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Attrs = Module:module_info(attributes),
            Behaviours = lists:flatten(proplists:get_all_values(behaviour, Attrs)),
            lists:member(inky_sensor, Behaviours);
        _ ->
            false
    end.

init([]) ->
    ChildSpecs = [child_spec(Mod) || Mod <- sensors()],
    io:format("SENSOR SUP: starting ~p sensor(s): ~p~n",
              [length(ChildSpecs), sensors()]),
    {ok, {{one_for_one, 10, 60}, ChildSpecs}}.

child_spec(Mod) ->
    #{id => Mod,
      start => {inky_sensor_server, start_link, [Mod]},
      restart => transient,
      shutdown => 5000,
      type => worker,
      modules => [inky_sensor_server, Mod]}.
