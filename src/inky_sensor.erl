-module(inky_sensor).

%% Behaviour for a background sensor: something that polls a piece of the
%% world on its own timer and caches the last reading. Implement this in
%% its own module and inky_sensor_sup picks it up automatically -- no
%% registry edits needed. See host_sensor.erl for an example.
%%
%% Sensors are deliberately NOT inky_tool modules. Tool dispatch happens
%% inside ollama_worker:ask/1, which blocks the Telegram handler on a 30s
%% timeout; a sensor that talks to slow or flaky I/O there would stall the
%% whole bot. Polling in the background and serving the cached value keeps
%% tool dispatch cheap and always-answerable (worst case it reports a
%% stale reading and its age). sensor_tool is the single tool that exposes
%% every sensor to the model.

%% Sensor name as used by the model and by inky_sensor_server:read/1,
%% e.g. <<"host">>. Must be unique across sensors.
-callback name() -> binary().

%% One line describing what this sensor reports, shown to the model.
-callback description() -> binary().

%% How often to poll, in milliseconds.
-callback interval() -> pos_integer().

%% Set up whatever the sensor needs to hold on to between reads.
-callback init() -> {ok, State :: term()} | {error, Reason :: term()}.

%% Take a reading. Runs in a short-lived process under a timeout (see
%% read_timeout/0), so blocking here is contained. On error the server
%% keeps serving the previous reading, tagged with its age.
-callback read(State :: term()) ->
    {ok, Reading :: term(), NewState :: term()} | {error, Reason :: term()}.

%% Render a reading as text for the model / the user.
-callback format(Reading :: term()) -> binary().

%% How long a single read/1 may take before it's killed. Defaults to 5000.
-callback read_timeout() -> pos_integer().

%% Words in a user message that should cause this sensor to be offered to
%% the model (all lowercase). Defaults to just name/0. Keep these narrow --
%% sensor_tool advertises itself whenever any sensor matches.
-callback keywords() -> [binary()].

%% Threshold checks. Return one entry per condition that is *currently*
%% true; the Key identifies the condition so the server can tell a new
%% alert from an ongoing one. Only transitions are messaged, so a value
%% hovering on a threshold doesn't spam the chat.
-callback alerts(Reading :: term(), State :: term()) ->
    [{Key :: term(), Message :: binary()}].

-optional_callbacks([read_timeout/0, alerts/2, keywords/0]).
