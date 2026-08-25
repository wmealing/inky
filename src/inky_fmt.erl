-module(inky_fmt).

%% Shared human-readable formatting for sensor output. Sensors report raw
%% numbers; this is the only place that decides how a byte count or a
%% duration is spelled, so every sensor's text reads the same way.

-export([bytes/1, kb/1, duration/1, pct/2]).

-define(UNITS, [<<"B">>, <<"K">>, <<"M">>, <<"G">>, <<"T">>, <<"P">>]).

%% Byte count -> <<"1.4G">>. Non-numbers render as "?" rather than
%% crashing: sensors deliberately return `undefined` for anything they
%% couldn't read on this host.
-spec bytes(number() | term()) -> binary().
bytes(B) when is_number(B) -> scale(B * 1.0, ?UNITS);
bytes(_) -> <<"?">>.

-spec kb(number() | term()) -> binary().
kb(Kb) when is_number(Kb) -> bytes(Kb * 1024);
kb(_) -> <<"?">>.

scale(Value, [Unit]) ->
    iolist_to_binary(io_lib:format("~.1f~s", [Value, Unit]));
scale(Value, [Unit | Rest]) ->
    case abs(Value) < 1024 of
        true -> iolist_to_binary(io_lib:format("~.1f~s", [Value, Unit]));
        false -> scale(Value / 1024, Rest)
    end.

%% Seconds -> <<"104d 0h 10m">>. Days and hours are dropped once they're
%% zero from the left, so a fresh boot reads "12m" rather than "0d 0h 12m".
-spec duration(number() | term()) -> binary().
duration(Secs) when is_number(Secs), Secs < 60 ->
    iolist_to_binary(io_lib:format("~ps", [trunc(Secs)]));
duration(Secs) when is_number(Secs) ->
    S = trunc(Secs),
    Days = S div 86400,
    Hours = (S rem 86400) div 3600,
    Mins = (S rem 3600) div 60,
    Parts = [io_lib:format("~pd", [Days]) || Days > 0]
        ++ [io_lib:format("~ph", [Hours]) || Days > 0 orelse Hours > 0]
        ++ [io_lib:format("~pm", [Mins])],
    iolist_to_binary(lists:join($\s, Parts));
duration(_) ->
    <<"?">>.

%% Part/Whole as a whole-number percentage, or `undefined` when that can't
%% be computed -- callers pattern-match on the integer to decide whether a
%% threshold has been crossed, so a bogus 0 would be worse than nothing.
-spec pct(term(), term()) -> non_neg_integer() | undefined.
pct(Part, Whole) when is_number(Part), is_number(Whole), Whole > 0 ->
    round(Part * 100 / Whole);
pct(_, _) ->
    undefined.
