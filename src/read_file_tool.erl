-module(read_file_tool).
-behaviour(inky_tool).

-export([name/0, schema/0, matches/1, dispatch/1]).

%% Cap how much we send back in one go -- Telegram messages have a hard
%% 4096-character limit and tool results are sent as a single message.
-define(MAX_READ_BYTES, 3000).

name() -> <<"read_file">>.

%% Match on intent (a read-ish verb plus "file"/"contents") rather than
%% fixed phrases -- real messages don't stick to one word order, e.g.
%% "can you read the file at ..." vs "show me what's in the file".
matches(Content) ->
    Verbs = [<<"read">>, <<"open">>, <<"show">>, <<"cat ">>, <<"view">>,
             <<"print">>, <<"display">>, <<"what's in">>, <<"whats in">>],
    Nouns = [<<"file">>, <<"contents">>],
    has_any(Content, Verbs) andalso has_any(Content, Nouns).

has_any(Content, Words) ->
    lists:any(fun(W) -> binary:match(Content, W) =/= nomatch end, Words).

schema() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => name(),
        <<"description">> => <<"Read the contents of a file from disk.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"path">> => #{<<"type">> => <<"string">>,
                                <<"description">> => <<"Path to the file to read">>}
            },
            <<"required">> => [<<"path">>]
        }
      }}.

dispatch(#{<<"path">> := Path}) ->
    PathStr = unicode:characters_to_list(Path),
    case file:read_file(PathStr) of
        {ok, Bin} -> maybe_truncate(Bin);
        {error, Reason} ->
            iolist_to_binary(io_lib:format("Could not read ~s: ~p", [PathStr, Reason]))
    end.

maybe_truncate(Bin) when byte_size(Bin) > ?MAX_READ_BYTES ->
    <<(binary:part(Bin, 0, ?MAX_READ_BYTES))/binary, "\n... (truncated)">>;
maybe_truncate(Bin) ->
    Bin.
