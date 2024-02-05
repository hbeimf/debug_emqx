%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_v2_testlib).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-import(emqx_common_test_helpers, [on_exit/1]).

-define(ROOT_KEY_ACTIONS, actions).
-define(ROOT_KEY_SOURCES, sources).

%% ct setup helpers

init_per_suite(Config, Apps) ->
    [{start_apps, Apps} | Config].

end_per_suite(Config) ->
    delete_all_bridges_and_connectors(),
    emqx_mgmt_api_test_util:end_suite(),
    ok = emqx_common_test_helpers:stop_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:stop_apps(lists:reverse(?config(start_apps, Config))),
    _ = application:stop(emqx_connector),
    ok.

init_per_group(TestGroup, BridgeType, Config) ->
    ProxyHost = os:getenv("PROXY_HOST", "toxiproxy"),
    ProxyPort = list_to_integer(os:getenv("PROXY_PORT", "8474")),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    application:load(emqx_bridge),
    ok = emqx_common_test_helpers:start_apps([emqx_conf]),
    ok = emqx_connector_test_helpers:start_apps(?config(start_apps, Config)),
    {ok, _} = application:ensure_all_started(emqx_connector),
    emqx_mgmt_api_test_util:init_suite(),
    UniqueNum = integer_to_binary(erlang:unique_integer([positive])),
    MQTTTopic = <<"mqtt/topic/abc", UniqueNum/binary>>,
    [
        {proxy_host, ProxyHost},
        {proxy_port, ProxyPort},
        {mqtt_topic, MQTTTopic},
        {test_group, TestGroup},
        {bridge_type, BridgeType}
        | Config
    ].

end_per_group(Config) ->
    ProxyHost = ?config(proxy_host, Config),
    ProxyPort = ?config(proxy_port, Config),
    emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
    %    delete_all_bridges(),
    ok.

init_per_testcase(TestCase, Config0, BridgeConfigCb) ->
    ct:timetrap(timer:seconds(60)),
    delete_all_bridges_and_connectors(),
    UniqueNum = integer_to_binary(erlang:unique_integer()),
    BridgeTopic =
        <<
            (atom_to_binary(TestCase))/binary,
            UniqueNum/binary
        >>,
    TestGroup = ?config(test_group, Config0),
    Config = [{bridge_topic, BridgeTopic} | Config0],
    {Name, ConfigString, BridgeConfig} = BridgeConfigCb(
        TestCase, TestGroup, Config
    ),
    ok = snabbkaffe:start_trace(),
    [
        {bridge_name, Name},
        {bridge_config_string, ConfigString},
        {bridge_config, BridgeConfig}
        | Config
    ].

end_per_testcase(_Testcase, Config) ->
    case proplists:get_bool(skip_does_not_apply, Config) of
        true ->
            ok;
        false ->
            ProxyHost = ?config(proxy_host, Config),
            ProxyPort = ?config(proxy_port, Config),
            emqx_common_test_helpers:reset_proxy(ProxyHost, ProxyPort),
            %% in CI, apparently this needs more time since the
            %% machines struggle with all the containers running...
            emqx_common_test_helpers:call_janitor(60_000),
            ok = snabbkaffe:stop(),
            ok
    end.

delete_all_bridges_and_connectors() ->
    delete_all_bridges(),
    delete_all_connectors().

delete_all_bridges() ->
    lists:foreach(
        fun(#{name := Name, type := Type}) ->
            emqx_bridge_v2:remove(actions, Type, Name)
        end,
        emqx_bridge_v2:list(actions)
    ),
    lists:foreach(
        fun(#{name := Name, type := Type}) ->
            emqx_bridge_v2:remove(sources, Type, Name)
        end,
        emqx_bridge_v2:list(sources)
    ).

delete_all_connectors() ->
    lists:foreach(
        fun(#{name := Name, type := Type}) ->
            emqx_connector:remove(Type, Name)
        end,
        emqx_connector:list()
    ).

%% test helpers
parse_and_check(BridgeType, BridgeName, ConfigString) ->
    {ok, RawConf} = hocon:binary(ConfigString, #{format => map}),
    hocon_tconf:check_plain(emqx_bridge_schema, RawConf, #{required => false, atom_key => false}),
    #{<<"bridges">> := #{BridgeType := #{BridgeName := BridgeConfig}}} = RawConf,
    BridgeConfig.

bridge_id(Config) ->
    BridgeType = ?config(bridge_type, Config),
    BridgeName = ?config(bridge_name, Config),
    BridgeId = emqx_bridge_resource:bridge_id(BridgeType, BridgeName),
    ConnectorId = emqx_bridge_resource:resource_id(BridgeType, BridgeName),
    <<"action:", BridgeId/binary, ":", ConnectorId/binary>>.

resource_id(Config) ->
    BridgeType = ?config(bridge_type, Config),
    BridgeName = ?config(bridge_name, Config),
    emqx_bridge_resource:resource_id(BridgeType, BridgeName).

create_bridge(Config) ->
    create_bridge(Config, _Overrides = #{}).

create_bridge(Config, Overrides) ->
    BridgeType = ?config(bridge_type, Config),
    BridgeName = ?config(bridge_name, Config),
    BridgeConfig0 = ?config(bridge_config, Config),
    BridgeConfig = emqx_utils_maps:deep_merge(BridgeConfig0, Overrides),
    ConnectorName = ?config(connector_name, Config),
    ConnectorType = ?config(connector_type, Config),
    ConnectorConfig = ?config(connector_config, Config),
    ct:pal("creating connector with config: ~p", [ConnectorConfig]),
    {ok, _} =
        emqx_connector:create(ConnectorType, ConnectorName, ConnectorConfig),

    ct:pal("creating bridge with config: ~p", [BridgeConfig]),
    emqx_bridge_v2:create(BridgeType, BridgeName, BridgeConfig).

get_ct_config_with_fallback(Config, [Key]) ->
    ?config(Key, Config);
get_ct_config_with_fallback(Config, [Key | Rest]) ->
    case ?config(Key, Config) of
        undefined ->
            get_ct_config_with_fallback(Config, Rest);
        X ->
            X
    end.

get_config_by_kind(Config, Overrides) ->
    Kind = ?config(bridge_kind, Config),
    get_config_by_kind(Kind, Config, Overrides).

get_config_by_kind(Kind, Config, Overrides) ->
    case Kind of
        action ->
            %% TODO: refactor tests to use action_type...
            ActionType = get_ct_config_with_fallback(Config, [action_type, bridge_type]),
            ActionName = get_ct_config_with_fallback(Config, [action_name, bridge_name]),
            ActionConfig0 = get_ct_config_with_fallback(Config, [action_config, bridge_config]),
            ActionConfig = emqx_utils_maps:deep_merge(ActionConfig0, Overrides),
            #{type => ActionType, name => ActionName, config => ActionConfig};
        source ->
            SourceType = ?config(source_type, Config),
            SourceName = ?config(source_name, Config),
            SourceConfig0 = ?config(source_config, Config),
            SourceConfig = emqx_utils_maps:deep_merge(SourceConfig0, Overrides),
            #{type => SourceType, name => SourceName, config => SourceConfig}
    end.

api_path_root(Kind) ->
    case Kind of
        action -> "actions";
        source -> "sources"
    end.

conf_root_key(Kind) ->
    case Kind of
        action -> ?ROOT_KEY_ACTIONS;
        source -> ?ROOT_KEY_SOURCES
    end.

maybe_json_decode(X) ->
    case emqx_utils_json:safe_decode(X, [return_maps]) of
        {ok, Decoded} -> Decoded;
        {error, _} -> X
    end.

request(Method, Path, Params) ->
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    case emqx_mgmt_api_test_util:request_api(Method, Path, "", AuthHeader, Params, Opts) of
        {ok, {Status, Headers, Body0}} ->
            Body = maybe_json_decode(Body0),
            {ok, {Status, Headers, Body}};
        {error, {Status, Headers, Body0}} ->
            Body =
                case emqx_utils_json:safe_decode(Body0, [return_maps]) of
                    {ok, Decoded0 = #{<<"message">> := Msg0}} ->
                        Msg = maybe_json_decode(Msg0),
                        Decoded0#{<<"message">> := Msg};
                    {ok, Decoded0} ->
                        Decoded0;
                    {error, _} ->
                        Body0
                end,
            {error, {Status, Headers, Body}};
        Error ->
            Error
    end.

list_bridges_api() ->
    Params = [],
    Path = emqx_mgmt_api_test_util:api_path(["actions"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("listing bridges (via http)"),
    Res =
        case emqx_mgmt_api_test_util:request_api(get, Path, "", AuthHeader, Params, Opts) of
            {ok, {Status, Headers, Body0}} ->
                {ok, {Status, Headers, emqx_utils_json:decode(Body0, [return_maps])}};
            Error ->
                Error
        end,
    ct:pal("list bridges result: ~p", [Res]),
    Res.

get_bridge_api(BridgeType, BridgeName) ->
    BridgeId = emqx_bridge_resource:bridge_id(BridgeType, BridgeName),
    Params = [],
    Path = emqx_mgmt_api_test_util:api_path(["actions", BridgeId]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    Opts = #{return_all => true},
    ct:pal("get bridge ~p (via http)", [{BridgeType, BridgeName}]),
    Res =
        case emqx_mgmt_api_test_util:request_api(get, Path, "", AuthHeader, Params, Opts) of
            {ok, {Status, Headers, Body0}} ->
                {ok, {Status, Headers, emqx_utils_json:decode(Body0, [return_maps])}};
            Error ->
                Error
        end,
    ct:pal("get bridge ~p result: ~p", [{BridgeType, BridgeName}, Res]),
    Res.

create_bridge_api(Config) ->
    create_bridge_api(Config, _Overrides = #{}).

create_bridge_api(Config, Overrides) ->
    {ok, {{_, 201, _}, _, _}} = create_connector_api(Config),
    create_kind_api(Config, Overrides).

create_kind_api(Config) ->
    create_kind_api(Config, _Overrides = #{}).

create_kind_api(Config, Overrides) ->
    Kind = proplists:get_value(bridge_kind, Config, action),
    #{
        type := Type,
        name := Name,
        config := BridgeConfig
    } = get_config_by_kind(Kind, Config, Overrides),
    Params = BridgeConfig#{<<"type">> => Type, <<"name">> => Name},
    PathRoot = api_path_root(Kind),
    Path = emqx_mgmt_api_test_util:api_path([PathRoot]),
    ct:pal("creating bridge (~s, http):\n  ~p", [Kind, Params]),
    Method = post,
    Res = request(Method, Path, Params),
    ct:pal("bridge create (~s, http) result:\n  ~p", [Kind, Res]),
    Res.

create_connector_api(Config) ->
    create_connector_api(Config, _Overrides = #{}).

create_connector_api(Config, Overrides) ->
    ConnectorConfig0 = ?config(connector_config, Config),
    ConnectorName = ?config(connector_name, Config),
    ConnectorType = ?config(connector_type, Config),
    Method = post,
    Path = emqx_mgmt_api_test_util:api_path(["connectors"]),
    ConnectorConfig = emqx_utils_maps:deep_merge(ConnectorConfig0, Overrides),
    Params = ConnectorConfig#{<<"type">> => ConnectorType, <<"name">> => ConnectorName},
    ct:pal("creating connector (http):\n  ~p", [Params]),
    Res = request(Method, Path, Params),
    ct:pal("connector create (http) result:\n  ~p", [Res]),
    Res.

create_action_api(Config) ->
    create_action_api(Config, _Overrides = #{}).

create_action_api(Config, Overrides) ->
    ActionName = ?config(action_name, Config),
    ActionType = ?config(action_type, Config),
    ActionConfig0 = ?config(action_config, Config),
    ActionConfig = emqx_utils_maps:deep_merge(ActionConfig0, Overrides),
    Params = ActionConfig#{<<"type">> => ActionType, <<"name">> => ActionName},
    Method = post,
    Path = emqx_mgmt_api_test_util:api_path(["actions"]),
    ct:pal("creating action (http):\n  ~p", [Params]),
    Res = request(Method, Path, Params),
    ct:pal("action create (http) result:\n  ~p", [Res]),
    Res.

get_action_api(Config) ->
    ActionName = ?config(action_name, Config),
    ActionType = ?config(action_type, Config),
    ActionId = emqx_bridge_resource:bridge_id(ActionType, ActionName),
    Params = [],
    Method = get,
    Path = emqx_mgmt_api_test_util:api_path(["actions", ActionId]),
    ct:pal("getting action (http)"),
    Res = request(Method, Path, Params),
    ct:pal("get action (http) result:\n  ~p", [Res]),
    Res.

update_bridge_api(Config) ->
    update_bridge_api(Config, _Overrides = #{}).

update_bridge_api(Config, Overrides) ->
    Kind = proplists:get_value(bridge_kind, Config, action),
    #{
        type := Type,
        name := Name,
        config := Params
    } = get_config_by_kind(Kind, Config, Overrides),
    BridgeId = emqx_bridge_resource:bridge_id(Type, Name),
    PathRoot = api_path_root(Kind),
    Path = emqx_mgmt_api_test_util:api_path([PathRoot, BridgeId]),
    ct:pal("updating bridge (~s, http):\n  ~p", [Kind, Params]),
    Method = put,
    Res = request(Method, Path, Params),
    ct:pal("update bridge (~s, http) result:\n  ~p", [Kind, Res]),
    Res.

op_bridge_api(Op, BridgeType, BridgeName) ->
    op_bridge_api(_Kind = action, Op, BridgeType, BridgeName).

op_bridge_api(Kind, Op, BridgeType, BridgeName) ->
    BridgeId = emqx_bridge_resource:bridge_id(BridgeType, BridgeName),
    PathRoot = api_path_root(Kind),
    Path = emqx_mgmt_api_test_util:api_path([PathRoot, BridgeId, Op]),
    ct:pal("calling bridge ~p (~s, http):\n  ~p", [BridgeId, Kind, Op]),
    Method = post,
    Params = [],
    Res = request(Method, Path, Params),
    ct:pal("bridge op result:\n  ~p", [Res]),
    Res.

probe_bridge_api(Config) ->
    probe_bridge_api(Config, _Overrides = #{}).

probe_bridge_api(Config, Overrides) ->
    BridgeType = ?config(bridge_type, Config),
    BridgeName = ?config(bridge_name, Config),
    BridgeConfig0 = ?config(bridge_config, Config),
    BridgeConfig = emqx_utils_maps:deep_merge(BridgeConfig0, Overrides),
    probe_bridge_api(BridgeType, BridgeName, BridgeConfig).

probe_bridge_api(BridgeType, BridgeName, BridgeConfig) ->
    probe_bridge_api(action, BridgeType, BridgeName, BridgeConfig).

probe_bridge_api(Kind, BridgeType, BridgeName, BridgeConfig) ->
    Params = BridgeConfig#{<<"type">> => BridgeType, <<"name">> => BridgeName},
    PathRoot = api_path_root(Kind),
    Path = emqx_mgmt_api_test_util:api_path([PathRoot ++ "_probe"]),
    ct:pal("probing bridge (~s, http):\n  ~p", [Kind, Params]),
    Method = post,
    Res = request(Method, Path, Params),
    ct:pal("bridge probe (~s, http) result:\n  ~p", [Kind, Res]),
    Res.

list_bridges_http_api_v1() ->
    Path = emqx_mgmt_api_test_util:api_path(["bridges"]),
    ct:pal("list bridges (http v1)"),
    Res = request(get, Path, _Params = []),
    ct:pal("list bridges (http v1) result:\n  ~p", [Res]),
    Res.

list_actions_http_api() ->
    Path = emqx_mgmt_api_test_util:api_path(["actions"]),
    ct:pal("list actions (http v2)"),
    Res = request(get, Path, _Params = []),
    ct:pal("list actions (http v2) result:\n  ~p", [Res]),
    Res.

list_sources_http_api() ->
    Path = emqx_mgmt_api_test_util:api_path(["sources"]),
    ct:pal("list sources (http v2)"),
    Res = request(get, Path, _Params = []),
    ct:pal("list sources (http v2) result:\n  ~p", [Res]),
    Res.

list_connectors_http_api() ->
    Path = emqx_mgmt_api_test_util:api_path(["connectors"]),
    ct:pal("list connectors"),
    Res = request(get, Path, _Params = []),
    ct:pal("list connectors result:\n  ~p", [Res]),
    Res.

update_rule_http(RuleId, Params) ->
    Path = emqx_mgmt_api_test_util:api_path(["rules", RuleId]),
    ct:pal("update rule ~p:\n  ~p", [RuleId, Params]),
    Res = request(put, Path, Params),
    ct:pal("update rule ~p result:\n  ~p", [RuleId, Res]),
    Res.

enable_rule_http(RuleId) ->
    Params = #{<<"enable">> => true},
    update_rule_http(RuleId, Params).

is_rule_enabled(RuleId) ->
    {ok, #{enable := Enable}} = emqx_rule_engine:get_rule(RuleId),
    Enable.

try_decode_error(Body0) ->
    case emqx_utils_json:safe_decode(Body0, [return_maps]) of
        {ok, #{<<"message">> := Msg0} = Body1} ->
            case emqx_utils_json:safe_decode(Msg0, [return_maps]) of
                {ok, Msg1} -> Body1#{<<"message">> := Msg1};
                {error, _} -> Body1
            end;
        {ok, Body1} ->
            Body1;
        {error, _} ->
            Body0
    end.

create_rule_api(Opts) ->
    #{
        sql := SQL,
        actions := RuleActions
    } = Opts,
    Params = #{
        enable => true,
        sql => SQL,
        actions => RuleActions
    },
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    ct:pal("create rule:\n  ~p", [Params]),
    Method = post,
    Res = request(Method, Path, Params),
    ct:pal("create rule results:\n  ~p", [Res]),
    Res.

create_rule_and_action_http(BridgeType, RuleTopic, Config) ->
    create_rule_and_action_http(BridgeType, RuleTopic, Config, _Opts = #{}).

create_rule_and_action_http(BridgeType, RuleTopic, Config, Opts) ->
    BridgeName = ?config(bridge_name, Config),
    BridgeId = emqx_bridge_resource:bridge_id(BridgeType, BridgeName),
    SQL = maps:get(sql, Opts, <<"SELECT * FROM \"", RuleTopic/binary, "\"">>),
    Params0 = #{
        enable => true,
        sql => SQL,
        actions => [BridgeId]
    },
    Overrides = maps:get(overrides, Opts, #{}),
    Params = emqx_utils_maps:deep_merge(Params0, Overrides),
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    ct:pal("rule action params: ~p", [Params]),
    case emqx_mgmt_api_test_util:request_api(post, Path, "", AuthHeader, Params) of
        {ok, Res0} ->
            Res = #{<<"id">> := RuleId} = emqx_utils_json:decode(Res0, [return_maps]),
            on_exit(fun() -> ok = emqx_rule_engine:delete_rule(RuleId) end),
            {ok, Res};
        Error ->
            Error
    end.

api_spec_schemas(Root) ->
    Method = get,
    Path = emqx_mgmt_api_test_util:api_path(["schemas", Root]),
    Params = [],
    AuthHeader = [],
    Opts = #{return_all => true},
    case emqx_mgmt_api_test_util:request_api(Method, Path, "", AuthHeader, Params, Opts) of
        {ok, {{_, 200, _}, _, Res0}} ->
            #{<<"components">> := #{<<"schemas">> := Schemas}} =
                emqx_utils_json:decode(Res0, [return_maps]),
            Schemas
    end.

bridges_api_spec_schemas() ->
    api_spec_schemas("bridges").

actions_api_spec_schemas() ->
    api_spec_schemas("actions").

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_sync_query(Config, MakeMessageFun, IsSuccessCheck, TracePoint) ->
    ?check_trace(
        begin
            ?assertMatch({ok, _}, create_bridge_api(Config)),
            ResourceId = resource_id(Config),
            ?retry(
                _Sleep = 1_000,
                _Attempts = 20,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),
            BridgeId = bridge_id(Config),
            Message = {BridgeId, MakeMessageFun()},
            IsSuccessCheck(emqx_resource:simple_sync_query(ResourceId, Message)),
            ok
        end,
        fun(Trace) ->
            ResourceId = resource_id(Config),
            ?assertMatch([#{instance_id := ResourceId}], ?of_kind(TracePoint, Trace))
        end
    ),
    ok.

t_async_query(Config, MakeMessageFun, IsSuccessCheck, TracePoint) ->
    ReplyFun =
        fun(Pid, Result) ->
            Pid ! {result, Result}
        end,
    ?check_trace(
        begin
            ?assertMatch({ok, _}, create_bridge_api(Config)),
            ResourceId = resource_id(Config),
            ?retry(
                _Sleep = 1_000,
                _Attempts = 20,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),
            BridgeId = bridge_id(Config),
            BridgeType = ?config(bridge_type, Config),
            BridgeName = ?config(bridge_name, Config),
            Message = {BridgeId, MakeMessageFun()},
            ?assertMatch(
                {ok, {ok, _}},
                ?wait_async_action(
                    emqx_bridge_v2:query(BridgeType, BridgeName, Message, #{
                        async_reply_fun => {ReplyFun, [self()]}
                    }),
                    #{?snk_kind := TracePoint, instance_id := ResourceId},
                    5_000
                )
            ),
            ok
        end,
        fun(Trace) ->
            ResourceId = resource_id(Config),
            ?assertMatch([#{instance_id := ResourceId}], ?of_kind(TracePoint, Trace))
        end
    ),
    receive
        {result, Result} -> IsSuccessCheck(Result)
    after 5_000 ->
        throw(timeout)
    end,
    ok.

t_create_via_http(Config) ->
    ?check_trace(
        begin
            ?assertMatch({ok, _}, create_bridge_api(Config)),

            ?assertMatch(
                {ok, _},
                update_bridge_api(
                    Config
                )
            ),
            ok
        end,
        []
    ),
    ok.

t_start_stop(Config, StopTracePoint) ->
    Kind = proplists:get_value(bridge_kind, Config, action),
    ConnectorName = ?config(connector_name, Config),
    ConnectorType = ?config(connector_type, Config),
    #{
        type := Type,
        name := Name,
        config := BridgeConfig
    } = get_config_by_kind(Kind, Config, _Overrides = #{}),

    ?assertMatch(
        {ok, {{_, 201, _}, _, _}},
        create_connector_api(Config)
    ),

    ?check_trace(
        begin
            ProbeRes0 = probe_bridge_api(
                Kind,
                Type,
                Name,
                BridgeConfig
            ),
            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes0),
            %% Check that the bridge probe API doesn't leak atoms.
            AtomsBefore = erlang:system_info(atom_count),
            %% Probe again; shouldn't have created more atoms.
            ProbeRes1 = probe_bridge_api(
                Kind,
                Type,
                Name,
                BridgeConfig
            ),

            ?assertMatch({ok, {{_, 204, _}, _Headers, _Body}}, ProbeRes1),
            AtomsAfter = erlang:system_info(atom_count),
            ?assertEqual(AtomsBefore, AtomsAfter),

            ?assertMatch({ok, _}, create_kind_api(Config)),

            ResourceId = emqx_bridge_resource:resource_id(conf_root_key(Kind), Type, Name),

            %% Since the connection process is async, we give it some time to
            %% stabilize and avoid flakiness.
            ?retry(
                _Sleep = 1_000,
                _Attempts = 20,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),

            %% `start` bridge to trigger `already_started`
            ?assertMatch(
                {ok, {{_, 204, _}, _Headers, []}},
                op_bridge_api(Kind, "start", Type, Name)
            ),

            ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId)),

            %% Not supported anymore

            %% ?assertMatch(
            %%     {{ok, _}, {ok, _}},
            %%     ?wait_async_action(
            %%         emqx_bridge_v2_testlib:op_bridge_api("stop", BridgeType, BridgeName),
            %%         #{?snk_kind := StopTracePoint},
            %%         5_000
            %%     )
            %% ),

            %% ?assertEqual(
            %%     {error, resource_is_stopped}, emqx_resource_manager:health_check(ResourceId)
            %% ),

            %% ?assertMatch(
            %%     {ok, {{_, 204, _}, _Headers, []}},
            %%     emqx_bridge_v2_testlib:op_bridge_api("stop", BridgeType, BridgeName)
            %% ),

            %% ?assertEqual(
            %%     {error, resource_is_stopped}, emqx_resource_manager:health_check(ResourceId)
            %% ),

            %% ?assertMatch(
            %%     {ok, {{_, 204, _}, _Headers, []}},
            %%     emqx_bridge_v2_testlib:op_bridge_api("start", BridgeType, BridgeName)
            %% ),

            ?retry(
                _Sleep = 1_000,
                _Attempts = 20,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            ),

            %% Disable the connector, which will also stop it.
            ?assertMatch(
                {{ok, _}, {ok, _}},
                ?wait_async_action(
                    emqx_connector:disable_enable(disable, ConnectorType, ConnectorName),
                    #{?snk_kind := StopTracePoint},
                    5_000
                )
            ),

            #{resource_id => ResourceId}
        end,
        fun(Res, Trace) ->
            #{resource_id := ResourceId} = Res,
            %% one for each probe, one for real
            ?assertMatch(
                [_, _, #{instance_id := ResourceId}],
                ?of_kind(StopTracePoint, Trace)
            ),
            ok
        end
    ),
    ok.

t_on_get_status(Config) ->
    t_on_get_status(Config, _Opts = #{}).

t_on_get_status(Config, Opts) ->
    ProxyPort = ?config(proxy_port, Config),
    ProxyHost = ?config(proxy_host, Config),
    ProxyName = ?config(proxy_name, Config),
    FailureStatus = maps:get(failure_status, Opts, disconnected),
    ?assertMatch({ok, _}, create_bridge(Config)),
    ResourceId = resource_id(Config),
    %% Since the connection process is async, we give it some time to
    %% stabilize and avoid flakiness.
    ?retry(
        _Sleep = 1_000,
        _Attempts = 20,
        ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
    ),
    case ProxyHost of
        undefined ->
            ok;
        _ ->
            emqx_common_test_helpers:with_failure(down, ProxyName, ProxyHost, ProxyPort, fun() ->
                ?retry(
                    _Interval0 = 100,
                    _Attempts0 = 20,
                    ?assertEqual(
                        {ok, FailureStatus}, emqx_resource_manager:health_check(ResourceId)
                    )
                )
            end),
            %% Check that it recovers itself.
            ?retry(
                _Sleep = 1_000,
                _Attempts = 20,
                ?assertEqual({ok, connected}, emqx_resource_manager:health_check(ResourceId))
            )
    end,
    ok.
