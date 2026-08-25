-module(weather_tool).
-behaviour(inky_tool).

-export([name/0, schema/0, matches/1, dispatch/1]).

name() -> <<"get_weather">>.

matches(Content) ->
    Keywords = [<<"weather">>, <<"temperature">>, <<"forecast">>, <<"rain">>,
                <<"raining">>, <<"sunny">>, <<"humidity">>],
    lists:any(fun(K) -> binary:match(Content, K) =/= nomatch end, Keywords).

schema() ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
        <<"name">> => name(),
        <<"description">> => <<"Get current weather for a city">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"location">> => #{<<"type">> => <<"string">>}
            }
        }
      }}.

dispatch(#{<<"city">> := _Loc}) -> <<"The weather in Brisbane is 22C.">>;
dispatch(#{<<"city_name">> := _Loc}) -> <<"The weather in Brisbane is 22C.">>;
dispatch(#{<<"location">> := _Loc}) -> <<"The weather in Brisbane is 22C.">>.
