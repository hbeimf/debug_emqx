%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Common Test Helper proxy module for slave -> peer migration.
%% OTP 26 has slave module deprecated, use peer instead.

-module(emqx_cth_peer).

-export([start/2, start/3, start/4]).
-export([start_link/2, start_link/3, start_link/4]).
-export([stop/1]).

start(Name, Args) ->
    start(Name, Args, []).

start(Name, Args, Envs) ->
    start(Name, Args, Envs, timer:seconds(20)).

start(Name, Args, Envs, Timeout) when is_atom(Name) ->
    do_start(Name, Args, Envs, Timeout, start).

start_link(Name, Args) ->
    start_link(Name, Args, []).

start_link(Name, Args, Envs) ->
    start_link(Name, Args, Envs, timer:seconds(20)).

start_link(Name, Args, Envs, Timeout) when is_atom(Name) ->
    do_start(Name, Args, Envs, Timeout, start_link).

do_start(Name0, Args, Envs, Timeout, Func) when is_atom(Name0) ->
    {Name, Host} = parse_node_name(Name0),
    %% Create exclusive current directory for the node.  Some configurations, like plugin
    %% installation directory, are the same for the whole cluster, and nodes on the same
    %% machine will step on each other's toes...
    {ok, Cwd} = file:get_cwd(),
    NodeCwd = filename:join([Cwd, Name]),
    ok = filelib:ensure_dir(filename:join([NodeCwd, "dummy"])),
    try
        file:set_cwd(NodeCwd),
        {ok, Pid, Node} = peer:Func(#{
            name => Name,
            host => Host,
            args => Args,
            env => Envs,
            wait_boot => Timeout,
            longnames => true,
            shutdown => {halt, 1000}
        }),
        true = register(Node, Pid),
        {ok, Node}
    after
        file:set_cwd(Cwd)
    end.

stop(Node) when is_atom(Node) ->
    Pid = whereis(Node),
    case is_pid(Pid) of
        true ->
            unlink(Pid),
            ok = peer:stop(Pid);
        false ->
            ct:pal("The control process for node ~p is unexpetedly down", [Node]),
            ok
    end.

parse_node_name(NodeName) ->
    case string:tokens(atom_to_list(NodeName), "@") of
        [Name, Host] ->
            {list_to_atom(Name), Host};
        [_] ->
            {NodeName, host()}
    end.

host() ->
    [_Name, Host] = string:tokens(atom_to_list(node()), "@"),
    Host.
