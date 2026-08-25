-module(host_sensor).
-behaviour(inky_sensor).

%% Reports host health: uptime, load average, memory, and free space on
%% each configured mount. Supports Linux (via /proc) and macOS (via
%% sysctl/vm_stat); df -kP is POSIX and parses identically on both.
%%
%% Every component is gathered defensively: anything that can't be read on
%% this host comes back as `undefined` and is simply left out of the
%% rendered text, rather than failing the whole reading. A monitoring
%% sensor that reports nothing because one field is unavailable is worse
%% than one that reports what it has.
%%
%% Configure under the inky app env, all keys optional:
%%   {host_sensor, [{mounts, ["/", "/data"]},
%%                  {interval, 60000},
%%                  {disk_alert_pct, 90},
%%                  {mem_alert_pct, 90},
%%                  {load_alert, 8.0}]}      %% default: 2.0 x logical cores

-export([name/0, description/0, interval/0, init/0, read/1, format/1,
         read_timeout/0, alerts/2, keywords/0]).

-define(DEFAULT_INTERVAL, 60000).
-define(DEFAULT_MOUNTS, ["/"]).
-define(DEFAULT_DISK_ALERT_PCT, 90).
-define(DEFAULT_MEM_ALERT_PCT, 90).

-record(cfg, {os, mounts, cores, disk_alert_pct, mem_alert_pct, load_alert}).

%% --- inky_sensor ---

name() -> <<"host">>.

description() ->
    <<"Host health for the machine inky runs on: uptime, load average, "
      "memory use, and free disk space per mount.">>.

interval() -> cfg(interval, ?DEFAULT_INTERVAL).

keywords() ->
    [<<"disk">>, <<"disk space">>, <<"free space">>, <<"load">>,
     <<"load average">>, <<"uptime">>, <<"memory">>, <<"ram">>, <<"cpu">>,
     <<"host">>, <<"server">>, <<"machine">>, <<"how full">>].

%% df/sysctl on a wedged network mount can hang well past the default;
%% give it room but still bound it.
read_timeout() -> 15000.

init() ->
    {OsFamily, OsName} = os:type(),
    Cores = case erlang:system_info(logical_processors) of
                N when is_integer(N) -> N;
                _ -> 1
            end,
    Cfg = #cfg{os = {OsFamily, OsName},
               mounts = valid_mounts(cfg(mounts, ?DEFAULT_MOUNTS)),
               cores = Cores,
               disk_alert_pct = cfg(disk_alert_pct, ?DEFAULT_DISK_ALERT_PCT),
               mem_alert_pct = cfg(mem_alert_pct, ?DEFAULT_MEM_ALERT_PCT),
               load_alert = cfg(load_alert, 2.0 * Cores)},
    {ok, Cfg}.

read(#cfg{os = Os, mounts = Mounts, cores = Cores} = Cfg) ->
    Reading = #{uptime_s => uptime_s(Os),
                load => load_avg(Os),
                cores => Cores,
                mem => mem(Os),
                disks => [disk(M) || M <- Mounts]},
    {ok, Reading, Cfg}.

format(Reading) ->
    Lines = [fmt_uptime(maps:get(uptime_s, Reading, undefined)),
             fmt_load(maps:get(load, Reading, undefined),
                      maps:get(cores, Reading, undefined)),
             fmt_mem(maps:get(mem, Reading, undefined))]
        ++ [fmt_disk(D) || D <- maps:get(disks, Reading, [])],
    case [L || L <- Lines, L =/= skip] of
        [] -> <<"no host metrics available">>;
        Present -> iolist_to_binary(lists:join($\n, Present))
    end.

%% Thresholds are re-read from app env on every poll rather than taken
%% from the #cfg{} captured at init, so they can be retuned live with
%% application:set_env/3 without restarting the sensor.
alerts(Reading, #cfg{cores = Cores}) ->
    Cfg = #cfg{cores = Cores,
               disk_alert_pct = cfg(disk_alert_pct, ?DEFAULT_DISK_ALERT_PCT),
               mem_alert_pct = cfg(mem_alert_pct, ?DEFAULT_MEM_ALERT_PCT),
               load_alert = cfg(load_alert, 2.0 * Cores)},
    disk_alerts(maps:get(disks, Reading, []), Cfg)
        ++ mem_alerts(maps:get(mem, Reading, undefined), Cfg)
        ++ load_alerts(maps:get(load, Reading, undefined), Cfg).

%% --- alerts ---

disk_alerts(Disks, #cfg{disk_alert_pct = Limit}) ->
    [{{disk, Mount},
      iolist_to_binary(io_lib:format("disk ~s is ~p% full (~s free)",
                                     [Mount, Pct, inky_fmt:kb(Avail)]))}
     || #{mount := Mount, used_pct := Pct, avail_kb := Avail} <- Disks,
        is_integer(Pct), Pct >= Limit].

mem_alerts(#{total_kb := Total, avail_kb := Avail}, #cfg{mem_alert_pct = Limit})
  when is_integer(Total), Total > 0, is_integer(Avail) ->
    Pct = used_pct(Total, Avail),
    case Pct >= Limit of
        true ->
            [{memory, iolist_to_binary(
                        io_lib:format("memory is ~p% used (~s free of ~s)",
                                      [Pct, inky_fmt:kb(Avail), inky_fmt:kb(Total)]))}];
        false -> []
    end;
mem_alerts(_, _) -> [].

load_alerts({L1, _, _}, #cfg{load_alert = Limit, cores = Cores})
  when is_number(L1), L1 >= Limit ->
    [{load, iolist_to_binary(io_lib:format("load average is ~.2f across ~p cores",
                                           [L1, Cores]))}];
load_alerts(_, _) -> [].

%% --- config ---

cfg(Key, Default) ->
    case application:get_env(inky, host_sensor) of
        {ok, Props} when is_list(Props) -> proplists:get_value(Key, Props, Default);
        _ -> Default
    end.

%% Mounts land in a shell command, so refuse anything with quoting in it
%% rather than trying to escape it.
valid_mounts(Mounts) ->
    [M || M <- Mounts, is_list(M), M =/= "", safe_path(M)].

safe_path(Path) ->
    nomatch =:= re:run(Path, "['\"`$\\\\\n]", [{capture, none}]).

%% --- uptime ---

uptime_s({unix, linux}) ->
    case file:read_file("/proc/uptime") of
        {ok, Bin} ->
            case parse_floats(binary_to_list(Bin), 1) of
                [Secs] -> round(Secs);
                _ -> undefined
            end;
        _ -> undefined
    end;
uptime_s({unix, darwin}) ->
    %% kern.boottime looks like: { sec = 1778689158, usec = 74956 } Thu May ...
    case re:run(cmd("sysctl -n kern.boottime"), "sec\\s*=\\s*([0-9]+)",
                [{capture, all_but_first, list}]) of
        {match, [SecStr]} ->
            max(0, erlang:system_time(second) - list_to_integer(SecStr));
        _ -> undefined
    end;
uptime_s(_) -> undefined.

%% --- load average ---

%% /proc/loadavg is "0.12 0.20 0.25 1/234 5678"; sysctl vm.loadavg is
%% "{ 1.76 2.03 2.15 }". Pulling the first three floats out handles both.
load_avg({unix, linux}) ->
    load_from(fun() ->
        case file:read_file("/proc/loadavg") of
            {ok, Bin} -> binary_to_list(Bin);
            _ -> ""
        end
    end);
load_avg({unix, darwin}) ->
    load_from(fun() -> cmd("sysctl -n vm.loadavg") end);
load_avg(_) -> undefined.

load_from(Fun) ->
    case parse_floats(Fun(), 3) of
        [L1, L5, L15] -> {L1, L5, L15};
        _ -> undefined
    end.

%% --- memory ---

mem({unix, linux}) ->
    case file:read_file("/proc/meminfo") of
        {ok, Bin} ->
            Lines = string:split(binary_to_list(Bin), "\n", all),
            Total = meminfo_kb(Lines, "MemTotal:"),
            %% MemAvailable is what's actually reclaimable; MemFree alone
            %% reads as near-zero on any box with a warm page cache.
            Avail = case meminfo_kb(Lines, "MemAvailable:") of
                        undefined -> meminfo_kb(Lines, "MemFree:");
                        V -> V
                    end,
            mem_map(Total, Avail);
        _ -> undefined
    end;
mem({unix, darwin}) ->
    Total = case string:trim(cmd("sysctl -n hw.memsize")) of
                "" -> undefined;
                S -> try list_to_integer(S) div 1024 catch _:_ -> undefined end
            end,
    mem_map(Total, darwin_avail_kb());
mem(_) -> undefined.

mem_map(Total, Avail) when is_integer(Total), is_integer(Avail) ->
    #{total_kb => Total, avail_kb => Avail, used_kb => Total - Avail};
mem_map(_, _) -> undefined.

meminfo_kb(Lines, Prefix) ->
    case [L || L <- Lines, lists:prefix(Prefix, L)] of
        [Line | _] ->
            case string:lexemes(Line, " \t") of
                [_, Value | _] -> try list_to_integer(Value) catch _:_ -> undefined end;
                _ -> undefined
            end;
        [] -> undefined
    end.

%% vm_stat reports pages, with the page size in its header line. Available
%% memory is free + inactive + speculative + purgeable -- everything the
%% kernel can hand out without swapping.
darwin_avail_kb() ->
    Out = cmd("vm_stat"),
    case re:run(Out, "page size of ([0-9]+) bytes", [{capture, all_but_first, list}]) of
        {match, [PageStr]} ->
            PageSize = list_to_integer(PageStr),
            Pages = lists:sum([vm_stat_pages(Out, K)
                               || K <- ["free", "inactive", "speculative", "purgeable"]]),
            (Pages * PageSize) div 1024;
        _ -> undefined
    end.

vm_stat_pages(Out, Key) ->
    Re = "Pages " ++ Key ++ "[^:]*:\\s*([0-9]+)",
    case re:run(Out, Re, [{capture, all_but_first, list}]) of
        {match, [N]} -> list_to_integer(N);
        _ -> 0
    end.

%% --- disk ---

%% -P forces the POSIX single-line-per-filesystem format; without it a long
%% device name wraps onto its own line and the columns shift.
disk(Mount) ->
    Out = cmd("df -kP '" ++ Mount ++ "' 2>/dev/null"),
    case string:split(Out, "\n", all) of
        [_Header, Row | _] ->
            case string:lexemes(Row, " \t") of
                [_Fs, Blocks, Used, Avail, _Capacity | _] ->
                    TotalKb = to_int(Blocks),
                    AvailKb = to_int(Avail),
                    #{mount => list_to_binary(Mount),
                      total_kb => TotalKb,
                      used_kb => to_int(Used),
                      avail_kb => AvailKb,
                      used_pct => used_pct(TotalKb, AvailKb)};
                _ ->
                    #{mount => list_to_binary(Mount), error => unparsable}
            end;
        _ ->
            #{mount => list_to_binary(Mount), error => unavailable}
    end.

%% Percentage of capacity in use. Derived from total/available rather than
%% total/used because on macOS the two don't sum to the total (reserved
%% blocks, APFS snapshots), and "how full is it" is the question actually
%% being asked.
used_pct(Total, Avail) when is_integer(Total), is_integer(Avail) ->
    inky_fmt:pct(Total - Avail, Total);
used_pct(_, _) -> undefined.

%% --- formatting ---

fmt_uptime(undefined) -> skip;
fmt_uptime(Secs) ->
    iolist_to_binary(["uptime  ", inky_fmt:duration(Secs)]).

fmt_load(undefined, _) -> skip;
fmt_load({L1, L5, L15}, Cores) ->
    Suffix = case Cores of
                 undefined -> "";
                 N -> io_lib:format(" (~p cores)", [N])
             end,
    iolist_to_binary(io_lib:format("load    ~.2f ~.2f ~.2f~s", [L1, L5, L15, Suffix])).

fmt_mem(undefined) -> skip;
fmt_mem(#{total_kb := Total, avail_kb := Avail, used_kb := Used}) ->
    iolist_to_binary(io_lib:format("memory  ~s / ~s used (~p%)",
                                   [inky_fmt:kb(Used), inky_fmt:kb(Total), used_pct(Total, Avail)])).

fmt_disk(#{mount := Mount, error := Reason}) ->
    iolist_to_binary(io_lib:format("disk    ~s unavailable (~p)", [Mount, Reason]));
fmt_disk(#{mount := Mount, total_kb := Total, avail_kb := Avail, used_pct := Pct})
  when is_integer(Total), is_integer(Avail) ->
    iolist_to_binary(io_lib:format("disk    ~s ~s free of ~s (~p% used)",
                                   [Mount, inky_fmt:kb(Avail), inky_fmt:kb(Total), Pct]));
fmt_disk(#{mount := Mount}) ->
    iolist_to_binary(io_lib:format("disk    ~s unavailable", [Mount])).

%% --- misc ---

cmd(Command) ->
    try os:cmd(Command) catch _:_ -> "" end.

to_int(Str) ->
    try list_to_integer(string:trim(Str)) catch _:_ -> undefined end.

%% Pull the first N floats (or integers, read as floats) out of a string.
parse_floats(Str, N) ->
    Tokens = string:lexemes(Str, " \t\n{},"),
    Floats = lists:filtermap(fun(T) ->
                                 case to_float(T) of
                                     undefined -> false;
                                     F -> {true, F}
                                 end
                             end, Tokens),
    lists:sublist(Floats, N).

to_float(Token) ->
    case string:to_float(Token) of
        {error, _} ->
            case string:to_integer(Token) of
                {error, _} -> undefined;
                {Int, _} -> Int * 1.0
            end;
        {Float, _} -> Float
    end.
