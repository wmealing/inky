-module(beam_sensor).
-behaviour(inky_sensor).

%% Reports the health of the BEAM that inky itself is running in: memory
%% by category, the process/port/atom tables against their hard limits,
%% run queue depth, scheduler utilisation, and the mailbox depth of the
%% bot's own long-lived processes.
%%
%% The mailbox check is the one that matters most here. ollama_worker:ask/1
%% blocks its caller for up to 30s, so if Ollama slows down, `inky`'s
%% mailbox is where the backlog piles up -- a growing queue there is the
%% signature of a wedged bot, and it's invisible from the outside because
%% Telegram just looks quiet.
%%
%% Unlike host_sensor this one is stateful: scheduler utilisation is only
%% meaningful as a delta between two samples, so read/1 carries the
%% previous scheduler_wall_time sample forward in its state. The first
%% reading after start reports utilisation as `undefined`.
%%
%% Configure under the inky app env, all keys optional:
%%   {beam_sensor, [{interval, 30000},
%%                  {watch, [inky, ollama_worker, message_user]},
%%                  {mailbox_alert, 100},
%%                  {table_alert_pct, 80},   %% processes / ports / atoms
%%                  {memory_alert_mb, 512}]} %% off by default

-export([name/0, description/0, interval/0, keywords/0, init/0, read/1,
         format/1, alerts/2]).

-define(DEFAULT_INTERVAL, 30000).
-define(DEFAULT_WATCH, [inky, ollama_worker, message_user]).
-define(DEFAULT_MAILBOX_ALERT, 100).
-define(DEFAULT_TABLE_ALERT_PCT, 80).

-record(st, {watch, prev_sched}).

%% --- inky_sensor ---

name() -> <<"beam">>.

description() ->
    <<"Health of the Erlang VM inky runs in: memory, process/port/atom "
      "table use, run queue, scheduler load, and mailbox depth of inky's "
      "own processes.">>.

interval() -> cfg(interval, ?DEFAULT_INTERVAL).

keywords() ->
    [<<"beam">>, <<"vm">>, <<"erlang">>, <<"otp">>, <<"process">>,
     <<"processes">>, <<"mailbox">>, <<"queue">>, <<"scheduler">>,
     <<"reductions">>, <<"heap">>, <<"garbage">>, <<"leak">>,
     <<"bot">>, <<"yourself">>, <<"your own">>].

init() ->
    %% Off by default; turning it on is what makes utilisation measurable
    %% at all. Costs a small amount of per-scheduler bookkeeping.
    catch erlang:system_flag(scheduler_wall_time, true),
    {ok, #st{watch = cfg(watch, ?DEFAULT_WATCH), prev_sched = undefined}}.

read(#st{watch = Watch, prev_sched = Prev} = St) ->
    Sample = sched_sample(),
    Reading = #{memory => memory(),
                processes => {erlang:system_info(process_count),
                              erlang:system_info(process_limit)},
                ports => {erlang:system_info(port_count),
                          erlang:system_info(port_limit)},
                atoms => {erlang:system_info(atom_count),
                          erlang:system_info(atom_limit)},
                run_queue => erlang:statistics(run_queue),
                sched_util => sched_util(Prev, Sample),
                uptime_s => uptime_s(),
                mailboxes => [mailbox(Name) || Name <- Watch]},
    {ok, Reading, St#st{prev_sched = Sample}}.

format(R) ->
    Lines = [fmt_uptime(maps:get(uptime_s, R, undefined)),
             fmt_memory(maps:get(memory, R, undefined)),
             fmt_tables(R),
             fmt_load(R),
             fmt_mailboxes(maps:get(mailboxes, R, []))],
    case [L || L <- Lines, L =/= skip] of
        [] -> <<"no VM metrics available">>;
        Present -> iolist_to_binary(lists:join($\n, Present))
    end.

%% Thresholds are re-read each poll so they can be retuned live, same as
%% host_sensor.
alerts(R, _St) ->
    Pct = cfg(table_alert_pct, ?DEFAULT_TABLE_ALERT_PCT),
    table_alert(processes, "process table", maps:get(processes, R, undefined), Pct)
        ++ table_alert(ports, "port table", maps:get(ports, R, undefined), Pct)
        ++ table_alert(atoms, "atom table", maps:get(atoms, R, undefined), Pct)
        ++ memory_alert(maps:get(memory, R, undefined))
        ++ mailbox_alerts(maps:get(mailboxes, R, [])).

%% --- alerts ---

%% All three of these are hard ceilings the VM dies at rather than soft
%% pressure, and the atom table in particular is never reclaimed -- so
%% crossing the threshold is worth saying out loud.
table_alert(Key, Label, {Count, Limit}, LimitPct) when is_integer(Count), is_integer(Limit) ->
    case inky_fmt:pct(Count, Limit) of
        P when is_integer(P), P >= LimitPct ->
            [{Key, iolist_to_binary(io_lib:format("~s is ~p% full (~p of ~p)",
                                                  [Label, P, Count, Limit]))}];
        _ -> []
    end;
table_alert(_, _, _, _) -> [].

memory_alert(#{total := Total}) when is_integer(Total) ->
    case cfg(memory_alert_mb, undefined) of
        Mb when is_number(Mb), Total >= Mb * 1024 * 1024 ->
            [{memory, iolist_to_binary(io_lib:format("VM memory is ~s (limit ~pM)",
                                                     [inky_fmt:bytes(Total), trunc(Mb)]))}];
        _ -> []
    end;
memory_alert(_) -> [].

mailbox_alerts(Mailboxes) ->
    Limit = cfg(mailbox_alert, ?DEFAULT_MAILBOX_ALERT),
    lists:append([mailbox_alert(M, Limit) || M <- Mailboxes]).

mailbox_alert(#{name := Name, queue := Q}, Limit) when is_integer(Q), Q >= Limit ->
    [{{mailbox, Name},
      iolist_to_binary(io_lib:format("~p has ~p unprocessed messages queued", [Name, Q]))}];
%% A watched process being absent at poll time doesn't mean a transient
%% restart -- the supervisor would have brought it back in microseconds.
%% It means it exhausted its restart intensity and stayed down.
mailbox_alert(#{name := Name, status := down}, _Limit) ->
    [{{down, Name}, iolist_to_binary(io_lib:format("~p is not running", [Name]))}];
mailbox_alert(_, _) ->
    [].

%% --- gathering ---

memory() ->
    try
        Mem = erlang:memory(),
        #{total => proplists:get_value(total, Mem),
          processes => proplists:get_value(processes, Mem),
          binary => proplists:get_value(binary, Mem),
          ets => proplists:get_value(ets, Mem),
          atom => proplists:get_value(atom, Mem)}
    catch _:_ -> undefined
    end.

uptime_s() ->
    {WallClockMs, _SinceLast} = erlang:statistics(wall_clock),
    WallClockMs div 1000.

mailbox(Name) ->
    case whereis(Name) of
        undefined ->
            #{name => Name, status => down};
        Pid ->
            case process_info(Pid, [message_queue_len, memory]) of
                [{message_queue_len, Q}, {memory, Bytes}] ->
                    #{name => Name, status => up, queue => Q, memory => Bytes};
                _ ->
                    #{name => Name, status => down}
            end
    end.

%% scheduler_wall_time is only enabled if the system_flag in init/0 took;
%% on a VM where it's off this returns undefined and utilisation is simply
%% left out of the report.
%%
%% The list also covers dirty CPU schedulers, which sit idle unless
%% something is doing dirty NIF work -- averaging those in halves the
%% figure and made a fully pegged 8-core box report 50%. Normal schedulers
%% are numbered first, so keeping ids up to schedulers/0 gives the number
%% people actually mean by "how busy is the VM".
sched_sample() ->
    case catch erlang:statistics(scheduler_wall_time) of
        List when is_list(List) ->
            Normal = erlang:system_info(schedulers),
            lists:sort([S || {Id, _, _} = S <- List, Id =< Normal]);
        _ -> undefined
    end.

%% Utilisation is Active/Total summed across schedulers, over the interval
%% between the two samples -- an instantaneous read of the counters alone
%% would just report the average since VM start and never move.
sched_util(undefined, _) -> undefined;
sched_util(_, undefined) -> undefined;
sched_util(Prev, Now) ->
    {Active, Total} =
        lists:foldl(fun({Id, A1, T1}, {AccA, AccT}) ->
                        case lists:keyfind(Id, 1, Prev) of
                            {Id, A0, T0} -> {AccA + (A1 - A0), AccT + (T1 - T0)};
                            false -> {AccA, AccT}
                        end
                    end, {0, 0}, Now),
    inky_fmt:pct(Active, Total).

%% --- formatting ---

fmt_uptime(undefined) -> skip;
fmt_uptime(Secs) -> iolist_to_binary(["uptime    ", inky_fmt:duration(Secs)]).

fmt_memory(undefined) -> skip;
fmt_memory(#{total := Total, processes := P, binary := B, ets := E, atom := A}) ->
    iolist_to_binary(io_lib:format(
        "memory    ~s total (procs ~s, binary ~s, ets ~s, atom ~s)",
        [inky_fmt:bytes(Total), inky_fmt:bytes(P), inky_fmt:bytes(B),
         inky_fmt:bytes(E), inky_fmt:bytes(A)]));
fmt_memory(_) -> skip.

%% One line each, fully spelled out. These used to share a single "tables"
%% row of the form "procs 76/1048576", which reads fine to a person but
%% the model re-interpreting the output turned into "76 tables in use" and
%% invented a port count to go with it. Ambiguity in the layout becomes
%% wrong numbers by the time it reaches the user.
fmt_tables(R) ->
    Lines = [fmt_table("processes", maps:get(processes, R, undefined)),
             fmt_table("ports    ", maps:get(ports, R, undefined)),
             fmt_table("atoms    ", maps:get(atoms, R, undefined))],
    case [L || L <- Lines, L =/= skip] of
        [] -> skip;
        Present -> iolist_to_binary(lists:join($\n, Present))
    end.

fmt_table(Label, {Count, Limit}) when is_integer(Count), is_integer(Limit) ->
    iolist_to_binary(io_lib:format("~s ~p of ~p allowed (~p% used)",
                                   [Label, Count, Limit, inky_fmt:pct(Count, Limit)]));
fmt_table(_, _) -> skip.

fmt_load(R) ->
    RunQueue = maps:get(run_queue, R, undefined),
    Util = maps:get(sched_util, R, undefined),
    Parts = [io_lib:format("run queue ~p", [RunQueue]) || is_integer(RunQueue)]
        ++ [io_lib:format("scheduler ~p% busy", [Util]) || is_integer(Util)],
    case Parts of
        [] -> skip;
        _ -> iolist_to_binary(["load      ", lists:join("  ", Parts)])
    end.

fmt_mailboxes([]) -> skip;
fmt_mailboxes(Mailboxes) ->
    iolist_to_binary(["mailbox   ", lists:join("  ", [fmt_mailbox(M) || M <- Mailboxes])]).

fmt_mailbox(#{name := Name, status := down}) ->
    io_lib:format("~p DOWN", [Name]);
fmt_mailbox(#{name := Name, queue := Q}) ->
    io_lib:format("~p ~p", [Name, Q]).

%% --- config ---

cfg(Key, Default) ->
    case application:get_env(inky, beam_sensor) of
        {ok, Props} when is_list(Props) -> proplists:get_value(Key, Props, Default);
        _ -> Default
    end.
