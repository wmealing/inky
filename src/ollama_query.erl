-module(ollama_query).
-export([ask/2]).

ask(Model, Prompt) ->
    %% Start necessary applications
    inets:start(),
    ssl:start(),

    Url = "http://localhost:11434/api/generate",
    Header = [{"Content-Type", "application/json"}],

    %% Create a JSON body (stream: false returns the full response at once)
    Body = lists:flatten(io_lib:format(
        "{\"model\": \"~s\", \"prompt\": \"~s\", \"stream\": false}", 
        [Model, Prompt])),

    %% Make the POST request
    case httpc:request(post, {Url, Header, "application/json", Body}, [], []) of
        {ok, {{_Version, 200, _Reason}, _Headers, RespBody}} ->
            S = unicode:characters_to_binary(RespBody),
            Foo = json:decode(S),
            maps:get(<<"response">>, Foo);
        {error, Reason} ->
	    Reason
    end.
