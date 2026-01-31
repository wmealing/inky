%%%-------------------------------------------------------------------
%% @doc inky top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(inky_sup).

-behaviour(supervisor).

-export([start_link/1]).

-export([init/1]).

-define(SERVER, ?MODULE).


start_link(State) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [State]).


%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional


init([]) ->
    io:format("EMPTY BRACKET INIT~n"),
    {ok, {{one_for_one, 3, 5}, []}};


init([State]) ->
    io:format("INKY SUP STATE BRACKET~n"),
    ChildSpecs = [#{id => inky,
                    start => {inky, start_link, [State]},
                    restart => permanent,
                    shutdown => brutal_kill,
                    type => worker,
                    modules => [inky]}],
    % 在 5 秒內 restart 超過 3 次，整個程式會死亡，避免無限回圈
    {ok, {{one_for_one, 3, 5}, ChildSpecs}}.
