-module(write_file_tool).
-behaviour(inky_tool).

-export([name/0, schema/0, matches/1, dispatch/1]).

%% All writes are confined under this directory, however the path is
%% given (relative, absolute, with "..", etc). Parent directories are
%% created as needed.
-define(ROOT, "/Users/wmealing/tmp/").

name() -> <<"write_file">>.

%% Match on intent (a write-ish verb plus "file") rather than fixed
%% phrases -- real messages don't stick to one word order, e.g. "can you
%% make file X with content Y" vs "save this text to a file".
matches(Content) ->
    Verbs = [<<"write">>, <<"save">>, <<"create">>, <<"make">>, <<"store">>,
             <<"put">>, <<"new file">>],
    has_any(Content, Verbs) andalso has_any(Content, [<<"file">>]).

has_any(Content, Words) ->
    lists:any(fun(W) -> binary:match(Content, W) =/= nomatch end, Words).

schema() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => name(),
        <<"description">> => <<"Write content to a file on disk. Writes are confined to "
                                "the ", (list_to_binary(?ROOT))/binary, " directory.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"path">> => #{<<"type">> => <<"string">>,
                                <<"description">> => <<"Path of the file to write">>},
                <<"content">> => #{<<"type">> => <<"string">>,
                                    <<"description">> => <<"Content to write to the file">>}
            },
            <<"required">> => [<<"path">>, <<"content">>]
        }
      }}.

dispatch(#{<<"path">> := Path, <<"content">> := Content}) ->
    case resolve_path(Path) of
        {ok, FullPath} ->
            ok = filelib:ensure_dir(FullPath),
            case file:write_file(FullPath, unescape_literal_sequences(Content)) of
                ok -> iolist_to_binary(io_lib:format("Wrote ~s", [FullPath]));
                {error, Reason} ->
                    iolist_to_binary(io_lib:format("Write failed for ~s: ~p", [FullPath, Reason]))
            end;
        {error, outside_root} ->
            iolist_to_binary(io_lib:format(
                "Refused: ~s escapes the allowed directory (~s).", [Path, ?ROOT]))
    end.

%% The model's JSON decode already turns a properly-escaped "\n" into a
%% real newline byte -- but small models are inconsistent and sometimes
%% double-escape, emitting the literal two characters backslash+n instead
%% of an actual line break (observed on llama3.1:8b in roughly 1 in 5
%% multi-line write requests). Since we can't control the model's
%% escaping, normalize the common literal sequences here.
unescape_literal_sequences(Content) ->
    Step1 = binary:replace(Content, <<"\\r\\n">>, <<"\r\n">>, [global]),
    Step2 = binary:replace(Step1, <<"\\n">>, <<"\n">>, [global]),
    binary:replace(Step2, <<"\\t">>, <<"\t">>, [global]).

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
