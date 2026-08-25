-module(execute_tool).
-behaviour(inky_tool).

-include_lib("kernel/include/file.hrl").

-export([name/0, schema/0, matches/1, dispatch/1]).

%% Only files under this directory may be executed, however the path is
%% given (relative, absolute, with "..", etc). Mirrors write_file_tool's
%% confinement so anything written there can also be run.
-define(ROOT, "/Users/wmealing/tmp/").

%% Hard cap on how long a run may take before it's killed.
-define(TIMEOUT_MS, 10000).

%% Cap how much combined stdout/stderr we send back -- Telegram messages
%% have a hard 4096-character limit and tool results are sent as a single
%% message.
-define(MAX_OUTPUT_BYTES, 3000).

name() -> <<"execute_file">>.

%% Match on intent (a run-ish verb plus "file"/"script") rather than fixed
%% phrases -- real messages don't stick to one word order, e.g. "can you
%% run the script at ..." vs "execute this file for me".
matches(Content) ->
    Verbs = [<<"run">>, <<"execute">>, <<"launch">>],
    Nouns = [<<"file">>, <<"script">>, <<"program">>],
    has_any(Content, Verbs) andalso has_any(Content, Nouns).

has_any(Content, Words) ->
    lists:any(fun(W) -> binary:match(Content, W) =/= nomatch end, Words).

schema() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => name(),
        <<"description">> => <<"Execute a file on disk. Execution is confined to "
                                "the ", (list_to_binary(?ROOT))/binary, " directory.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"path">> => #{<<"type">> => <<"string">>,
                                 <<"description">> => <<"Path of the file to execute">>},
                <<"args">> => #{<<"type">> => <<"array">>,
                                 <<"items">> => #{<<"type">> => <<"string">>},
                                 <<"description">> => <<"Optional arguments to pass to the file">>}
            },
            <<"required">> => [<<"path">>]
        }
      }}.

dispatch(#{<<"path">> := Path} = Args) ->
    RawArgList = maps:get(<<"args">>, Args, []),
    ArgList = [unicode:characters_to_list(A) || A <- RawArgList],
    case resolve_path(Path) of
        {ok, FullPath} -> run(FullPath, ArgList);
        {error, outside_root} ->
            iolist_to_binary(io_lib:format(
                "Refused: ~s escapes the allowed directory (~s).", [Path, ?ROOT]))
    end.

run(FullPath, ArgList) ->
    case filelib:is_regular(FullPath) of
        false ->
            iolist_to_binary(io_lib:format("Refused: ~s is not a regular file.", [FullPath]));
        true ->
            case is_executable(FullPath) of
                false ->
                    iolist_to_binary(io_lib:format("Refused: ~s is not executable.", [FullPath]));
                true ->
                    execute(FullPath, ArgList)
            end
    end.

is_executable(FullPath) ->
    case file:read_file_info(FullPath) of
        {ok, #file_info{mode = Mode}} -> (Mode band 8#100) =/= 0;
        {error, _} -> false
    end.

execute(FullPath, ArgList) ->
    Port = erlang:open_port({spawn_executable, FullPath},
                             [{args, ArgList}, binary, stderr_to_stdout,
                              exit_status, {cd, ?ROOT}]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            format_result(Status, Acc)
    after ?TIMEOUT_MS ->
        erlang:port_close(Port),
        format_timeout(Acc)
    end.

format_result(Status, Output) ->
    iolist_to_binary(io_lib:format("Exit status: ~p~n~s", [Status, maybe_truncate(Output)])).

format_timeout(Output) ->
    iolist_to_binary(io_lib:format(
        "Timed out after ~ps, process killed.~n~s",
        [?TIMEOUT_MS div 1000, maybe_truncate(Output)])).

maybe_truncate(Bin) when byte_size(Bin) > ?MAX_OUTPUT_BYTES ->
    <<(binary:part(Bin, 0, ?MAX_OUTPUT_BYTES))/binary, "\n... (truncated)">>;
maybe_truncate(Bin) ->
    Bin.

%% Resolves Path (relative or absolute) against ?ROOT and lexically
%% normalizes ".."/"." segments, then requires the result stay under
%% ?ROOT -- rejects escapes like "../../etc/passwd" or an absolute path
%% outside the root, without requiring the target to already exist.
resolve_path(Path) ->
    PathStr = unicode:characters_to_list(Path),
    Joined = case filename:pathtype(PathStr) of
        absolute -> PathStr;
        _ -> filename:join(?ROOT, PathStr)
    end,
    NormParts = normalize_parts(filename:split(Joined)),
    RootParts = normalize_parts(filename:split(?ROOT)),
    case lists:prefix(RootParts, NormParts) of
        true -> {ok, filename:join(NormParts)};
        false -> {error, outside_root}
    end.

normalize_parts(Parts) ->
    lists:reverse(lists:foldl(fun
        (".", Acc) -> Acc;
        ("..", []) -> [];
        ("..", [_ | Rest]) -> Rest;
        (P, Acc) -> [P | Acc]
    end, [], Parts)).
