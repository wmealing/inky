%%%-------------------------------------------------------------------
%%% @doc
%%% Recompiles the project via `rebar3 compile` and hot-loads every
%%% resulting beam into the running node. Only useful under `rebar3
%%% shell` -- a packaged relx release has no rebar3 binary to shell out
%%% to.
%%% @end
%%%-------------------------------------------------------------------
-module(reload).

-export([run/0]).

-define(EXIT_MARKER, "INKY_RELOAD_EXIT:").

-spec run() -> {ok, binary()} | {error, binary()}.
run() ->
    Output = os:cmd("rebar3 compile 2>&1; echo " ?EXIT_MARKER "$?"),
    case split_exit(Output) of
        {0, Log} ->
            {Reloaded, Failed} = reload_modules(),
            Msg = io_lib:format(
                "Recompiled OK.~nReloaded ~p module(s): ~p~s",
                [length(Reloaded), Reloaded, failed_suffix(Failed)]),
            io:format("RELOAD: ~s~n", [Log]),
            {ok, iolist_to_binary(Msg)};
        {_, Log} ->
            {error, iolist_to_binary(["Compile failed:\n", Log])}
    end.

failed_suffix([]) -> <<"">>;
failed_suffix(Failed) -> io_lib:format("~nFailed to reload: ~p", [Failed]).

%% `rebar3 compile` gives no exit code back through os:cmd/1 directly, so
%% we append a marker with $? and split on it.
split_exit(Output) ->
    case string:split(Output, ?EXIT_MARKER, trailing) of
        [Log, ExitStr] ->
            case string:to_integer(string:trim(ExitStr)) of
                {Code, _} when is_integer(Code) -> {Code, Log};
                _ -> {1, Output}
            end;
        _ -> {1, Output}
    end.

%% code:load_file/1 on a module that's already current is a cheap no-op,
%% so it's safe to sweep every module in the app rather than track which
%% ones actually changed on disk.
reload_modules() ->
    {ok, Modules} = application:get_key(inky, modules),
    lists:foldr(fun(M, {Ok, Fail}) ->
        code:purge(M),
        case code:load_file(M) of
            {module, M} -> {[M | Ok], Fail};
            {error, Reason} -> {Ok, [{M, Reason} | Fail]}
        end
    end, {[], []}, Modules).
