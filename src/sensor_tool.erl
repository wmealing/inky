-module(sensor_tool).
-behaviour(inky_tool).

%% The single tool through which the model reads every sensor. One schema
%% with a sensor-name argument beats one schema per sensor: a dozen
%% near-identical function definitions compete for a small model's
%% attention and it starts picking the wrong one. The list of valid names
%% is baked into the schema's enum, so the model can't invent one.

-export([name/0, schema/0, matches/1, dispatch/1, interpret/0]).

%% Past this, a reading is old enough that the user should be told so
%% rather than being handed it as current.
-define(STALE_AFTER_MS, 300000).

name() -> <<"read_sensor">>.

%% Sensor readings go back through the model to be turned into a sentence
%% before the user sees them -- see ollama_worker:interpret_result/5.
interpret() -> true.

%% Offer the tool when the message mentions any running sensor by name or
%% by one of its keywords, plus a couple of generic openers.
matches(Content) ->
    Words = [<<"sensor">>, <<"sensors">>] ++ lists:flatmap(fun keywords/1, running()),
    lists:any(fun(W) -> binary:match(Content, W) =/= nomatch end, Words).

schema() ->
    Names = [Mod:name() || Mod <- running()],
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => name(),
        <<"description">> => <<"Read a live sensor on the machine inky runs on. "
                               "Available sensors:\n", (sensor_list())/binary,
                               "\nOmit the sensor argument to read all of them.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"sensor">> => #{<<"type">> => <<"string">>,
                                  <<"enum">> => Names,
                                  <<"description">> => <<"Which sensor to read">>}
            }
        }
      }}.

dispatch(Args) ->
    case requested(Args) of
        all ->
            case running() of
                [] -> <<"No sensors are running.">>;
                Mods -> join([render(M) || M <- Mods])
            end;
        {sensor, Mod} ->
            render(Mod);
        {unknown, Requested} ->
            iolist_to_binary(["No sensor named \"", Requested, "\". Available: ",
                              join_names(), $.])
    end.

%% --- internal ---

%% The model has been seen to use `name` or `sensor_name` instead of the
%% documented `sensor`, so accept the obvious variants rather than falling
%% through to a confusing "read everything".
requested(Args) ->
    case first_value(Args, [<<"sensor">>, <<"name">>, <<"sensor_name">>]) of
        undefined -> all;
        <<"all">> -> all;
        Requested -> lookup(Requested)
    end.

first_value(_Args, []) -> undefined;
first_value(Args, [Key | Rest]) ->
    case maps:get(Key, Args, undefined) of
        undefined -> first_value(Args, Rest);
        Value -> Value
    end.

lookup(Requested) ->
    Wanted = string:lowercase(iolist_to_binary(Requested)),
    case [M || M <- running(), string:lowercase(M:name()) =:= Wanted] of
        [Mod | _] -> {sensor, Mod};
        [] -> {unknown, Requested}
    end.

%% Only sensors whose process is actually alive -- inky_sensor_sup starts
%% them `transient`, so a sensor that failed to start is genuinely absent
%% and shouldn't be advertised as readable.
running() ->
    [Mod || Mod <- inky_sensor_sup:sensors(), is_pid(whereis(Mod))].

keywords(Mod) ->
    case erlang:function_exported(Mod, keywords, 0) of
        true -> Mod:keywords();
        false -> [Mod:name()]
    end.

render(Mod) ->
    case inky_sensor_server:read(Mod) of
        #{text := Text} = Reading ->
            iolist_to_binary([Mod:name(), $\n, Text, age_note(Reading)]);
        #{error := Reason} ->
            iolist_to_binary(io_lib:format("~s: unavailable (~p)", [Mod:name(), Reason]))
    end.

age_note(Reading) ->
    Age = maps:get(age_ms, Reading, undefined),
    Stale = maps:is_key(stale, Reading),
    case {Age, Stale} of
        {undefined, _} -> "";
        {Ms, false} when Ms < ?STALE_AFTER_MS -> "";
        {Ms, _} -> io_lib:format("~n(reading is ~s old)", [fmt_age(Ms)])
    end.

fmt_age(Ms) when Ms < 60000 -> io_lib:format("~ps", [Ms div 1000]);
fmt_age(Ms) when Ms < 3600000 -> io_lib:format("~pm", [Ms div 60000]);
fmt_age(Ms) -> io_lib:format("~ph", [Ms div 3600000]).

sensor_list() ->
    iolist_to_binary(lists:join($\n,
        [["- ", Mod:name(), ": ", Mod:description()] || Mod <- running()])).

join_names() ->
    lists:join(", ", [Mod:name() || Mod <- running()]).

join(Parts) ->
    iolist_to_binary(lists:join("\n\n", Parts)).
