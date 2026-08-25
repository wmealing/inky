-module(inky_sensor_server).
-behaviour(gen_server).

%% Generic host process for an inky_sensor callback module. One of these
%% runs per sensor, registered under the callback module's own name, so a
%% sensor module itself only has to implement init/read/format.
%%
%% It owns the poll timer, the cached last-good reading and its age, a
%% consecutive-failure count, and alert edge detection.

-export([start_link/1, read/1, info/1, poll_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2, terminate/2]).

-define(DEFAULT_READ_TIMEOUT, 5000).

%% Log a failing sensor once on the way down and once on the way back up,
%% rather than on every poll -- a sensor whose hardware is missing polls
%% forever and would otherwise flood the console.
-define(FAILURE_LOG_EVERY, 20).

-record(state, {mod,
                name,
                interval,
                sensor_state,
                reading,            %% last good reading, or undefined
                read_at,            %% monotonic ms of last good reading
                failures = 0,       %% consecutive failed reads
                last_error,
                alerts = []}).      %% keys of currently-active alerts

%% --- API ---

start_link(Mod) ->
    gen_server:start_link({local, Mod}, ?MODULE, Mod, []).

%% Cached reading, rendered. Never blocks on the underlying I/O.
-spec read(module()) -> map().
read(Mod) ->
    try
        gen_server:call(Mod, read, 5000)
    catch
        exit:{noproc, _} -> #{name => atom_to_binary(Mod), error => not_running};
        exit:{timeout, _} -> #{name => atom_to_binary(Mod), error => busy}
    end.

%% Raw reading plus bookkeeping, for debugging from the shell.
info(Mod) ->
    gen_server:call(Mod, info, 5000).

poll_now(Mod) ->
    gen_server:cast(Mod, poll).

%% --- Callbacks ---

init(Mod) ->
    case Mod:init() of
        {ok, SensorState} ->
            State = #state{mod = Mod,
                           name = Mod:name(),
                           interval = Mod:interval(),
                           sensor_state = SensorState},
            {ok, State, {continue, poll}};
        {error, Reason} ->
            {stop, {sensor_init_failed, Mod, Reason}}
    end.

handle_continue(poll, State) ->
    {noreply, poll(State)}.

handle_call(read, _From, State) ->
    {reply, rendered(State), State};
handle_call(info, _From, State) ->
    {reply, #{name => State#state.name,
              module => State#state.mod,
              reading => State#state.reading,
              age_ms => age_ms(State),
              failures => State#state.failures,
              last_error => State#state.last_error,
              alerts => State#state.alerts}, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(poll, State) ->
    {noreply, poll(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, State) ->
    {noreply, poll(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% --- Internal ---

poll(State) ->
    NewState = apply_read(State, do_read(State)),
    erlang:send_after(NewState#state.interval, self(), poll),
    NewState.

apply_read(State, {ok, Reading, SensorState}) ->
    case State#state.failures of
        0 -> ok;
        N -> io:format("SENSOR ~s: recovered after ~p failed reads~n",
                       [State#state.name, N])
    end,
    S1 = State#state{sensor_state = SensorState,
                     reading = Reading,
                     read_at = erlang:monotonic_time(millisecond),
                     failures = 0,
                     last_error = undefined},
    check_alerts(S1, Reading);
apply_read(State, {error, Reason}) ->
    Failures = State#state.failures + 1,
    case Failures rem ?FAILURE_LOG_EVERY of
        1 -> io:format("SENSOR ~s: read failed (~p consecutive): ~p~n",
                       [State#state.name, Failures, Reason]);
        _ -> ok
    end,
    State#state{failures = Failures, last_error = Reason};
apply_read(State, Other) ->
    apply_read(State, {error, {bad_read_return, Other}}).

%% Run the sensor's read/1 in a throwaway process under a hard timeout, so
%% a wedged device or a hung os:cmd/1 costs one bounded stall rather than
%% permanently blocking this server.
do_read(#state{mod = Mod, sensor_state = SensorState}) ->
    Timeout = read_timeout(Mod),
    Parent = self(),
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                       Result = try Mod:read(SensorState)
                                catch C:E:St -> {error, {C, E, St}}
                                end,
                       Parent ! {read_result, self(), Result}
                   end),
    receive
        {read_result, Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, {sensor_crashed, Reason}}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        receive {read_result, Pid, _} -> ok after 0 -> ok end,
        {error, {timeout, Timeout}}
    end.

read_timeout(Mod) ->
    case erlang:function_exported(Mod, read_timeout, 0) of
        true -> Mod:read_timeout();
        false -> ?DEFAULT_READ_TIMEOUT
    end.

%% Only alert on transitions: newly-true conditions are announced, and
%% conditions that stopped being true are marked resolved.
check_alerts(#state{mod = Mod} = State, Reading) ->
    case erlang:function_exported(Mod, alerts, 2) of
        false -> State;
        true ->
            Active = Mod:alerts(Reading, State#state.sensor_state),
            Keys = [K || {K, _} <- Active],
            Was = State#state.alerts,
            [notify(State#state.name, Msg)
             || {K, Msg} <- Active, not lists:member(K, Was)],
            [notify(State#state.name, resolved_text(K))
             || K <- Was, not lists:member(K, Keys)],
            State#state{alerts = Keys}
    end.

resolved_text(Key) ->
    iolist_to_binary(io_lib:format("resolved: ~p", [Key])).

notify(SensorName, Message) ->
    Text = iolist_to_binary([$[, SensorName, "] ", Message]),
    io:format("SENSOR ALERT: ~s~n", [Text]),
    case whereis(message_user) of
        undefined -> ok;
        _ -> message_user:send(Text)
    end.

rendered(#state{reading = undefined} = State) ->
    #{name => State#state.name,
      error => case State#state.last_error of
                   undefined -> no_reading_yet;
                   Reason -> Reason
               end};
rendered(#state{mod = Mod, reading = Reading} = State) ->
    Base = #{name => State#state.name,
             text => Mod:format(Reading),
             age_ms => age_ms(State)},
    case State#state.failures of
        0 -> Base;
        N -> Base#{stale => N, last_error => State#state.last_error}
    end.

age_ms(#state{read_at = undefined}) -> undefined;
age_ms(#state{read_at = T}) -> erlang:monotonic_time(millisecond) - T.
