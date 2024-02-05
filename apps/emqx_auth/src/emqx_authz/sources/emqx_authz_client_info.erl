%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authz_client_info).

-include_lib("emqx/include/logger.hrl").

-behaviour(emqx_authz_source).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

%% APIs
-export([
    description/0,
    create/1,
    update/1,
    destroy/1,
    authorize/4
]).

-define(IS_V1(Rules), is_map(Rules)).
-define(IS_V2(Rules), is_list(Rules)).

%% For v1
-define(RULE_NAMES, [
    {[pub, <<"pub">>], publish},
    {[sub, <<"sub">>], subscribe},
    {[all, <<"all">>], all}
]).

%%--------------------------------------------------------------------
%% emqx_authz callbacks
%%--------------------------------------------------------------------

description() ->
    "AuthZ with ClientInfo".

create(Source) ->
    Source.

update(Source) ->
    Source.

destroy(_Source) -> ok.

%% @doc Authorize based on cllientinfo enriched with `acl' data.
%% e.g. From JWT.
%%
%% Supproted rules formats are:
%%
%% v1: (always deny when no match)
%%
%%    #{
%%        pub => [TopicFilter],
%%        sub => [TopicFilter],
%%        all => [TopicFilter]
%%    }
%%
%% v2: (rules are checked in sequence, passthrough when no match)
%%
%%    [{
%%        Permission :: emqx_authz_rule:permission(),
%%        Action :: emqx_authz_rule:action_condition(),
%%        Topics :: emqx_authz_rule:topic_condition()
%%     }]
%%
%%  which is compiled from raw rules like below by emqx_authz_rule_raw
%%
%%    [
%%        #{
%%            permission := allow | deny
%%            action := pub | sub | all
%%            topic => TopicFilter,
%%            topics => [TopicFilter] %% when 'topic' is not provided
%%            qos => 0 | 1 | 2 | [0, 1, 2]
%%            retain => true | false | all %% only for pub action
%%        }
%%    ]
%%
authorize(#{acl := Acl} = Client, PubSub, Topic, _Source) ->
    case check(Acl) of
        {ok, Rules} when ?IS_V2(Rules) ->
            authorize_v2(Client, PubSub, Topic, Rules);
        {ok, Rules} when ?IS_V1(Rules) ->
            authorize_v1(Client, PubSub, Topic, Rules);
        {error, MatchResult} ->
            MatchResult
    end;
authorize(_Client, _PubSub, _Topic, _Source) ->
    nomatch.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

check(#{expire := Expire, rules := Rules}) ->
    Now = erlang:system_time(second),
    case Expire of
        N when is_integer(N) andalso N > Now -> {ok, Rules};
        undefined -> {ok, Rules};
        _ -> {error, {matched, deny}}
    end;
%% no expire
check(#{rules := Rules}) ->
    {ok, Rules};
%% no rules — no match
check(#{}) ->
    {error, nomatch}.

authorize_v1(Client, PubSub, Topic, AclRules) ->
    authorize_v1(Client, PubSub, Topic, AclRules, ?RULE_NAMES).

authorize_v1(_Client, _PubSub, _Topic, _AclRules, []) ->
    {matched, deny};
authorize_v1(Client, PubSub, Topic, AclRules, [{Keys, Action} | RuleNames]) ->
    TopicFilters = get_topic_filters_v1(Keys, AclRules, []),
    case
        emqx_authz_rule:match(
            Client,
            PubSub,
            Topic,
            emqx_authz_rule:compile({allow, all, Action, TopicFilters})
        )
    of
        {matched, Permission} -> {matched, Permission};
        nomatch -> authorize_v1(Client, PubSub, Topic, AclRules, RuleNames)
    end.

get_topic_filters_v1([], _Rules, Default) ->
    Default;
get_topic_filters_v1([Key | Keys], Rules, Default) ->
    case Rules of
        #{Key := Value} -> Value;
        #{} -> get_topic_filters_v1(Keys, Rules, Default)
    end.

authorize_v2(Client, PubSub, Topic, Rules) ->
    emqx_authz_rule:matches(Client, PubSub, Topic, Rules).
