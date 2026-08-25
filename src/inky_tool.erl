-module(inky_tool).

%% Behaviour for a locally-dispatched LLM tool. Implement this in its own
%% module and it is picked up automatically by inky_tools -- no registry
%% edits needed. See weather_tool.erl for an example.

%% Tool name as sent to/from Ollama, e.g. <<"get_weather">>.
-callback name() -> binary().

%% Full Ollama tool schema (the {"type": "function", "function": {...}} map).
-callback schema() -> map().

%% Decides whether this tool's schema should be offered to the model for
%% a given user message (already lowercased). Keep this narrow -- offering
%% a tool on unrelated questions tempts small models into calling it (or
%% leaking tool-call-shaped JSON) when it shouldn't -- but match on intent
%% (e.g. an action verb plus a relevant noun) rather than exact phrases,
%% since real messages don't stick to a fixed word order.
-callback matches(Content :: binary()) -> boolean().

%% Whether this tool's result should be handed back to the model to be
%% put into plain language before the user sees it, instead of being sent
%% verbatim. Defaults to false, which is right for tools whose output is
%% already exact and must not be paraphrased -- file contents, command
%% output. Sensors set this to true: their readings are dense columns of
%% numbers that read better as a sentence.
-callback interpret() -> boolean().

%% Run the tool given the arguments map the model supplied; return the
%% plain-text result to show the user.
-callback dispatch(Args :: map()) -> binary().

-optional_callbacks([interpret/0]).
