%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_gcp_pubsub_impl_producer).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-type connector_config() :: #{
    connect_timeout := emqx_schema:duration_ms(),
    max_retries := non_neg_integer(),
    resource_opts := #{request_ttl := infinity | emqx_schema:duration_ms(), any() => term()},
    service_account_json := emqx_bridge_gcp_pubsub_client:service_account_json()
}.
-type action_config() :: #{
    parameters := #{
        attributes_template := [#{key := binary(), value := binary()}],
        ordering_key_template := binary(),
        payload_template := binary(),
        pubsub_topic := binary()
    },
    resource_opts := #{request_ttl := infinity | emqx_schema:duration_ms(), any() => term()}
}.
-type connector_state() :: #{
    client := emqx_bridge_gcp_pubsub_client:state(),
    installed_actions := #{action_resource_id() => action_state()},
    project_id := emqx_bridge_gcp_pubsub_client:project_id()
}.
-type action_state() :: #{
    attributes_template := #{emqx_placeholder:tmpl_token() => emqx_placeholder:tmpl_token()},
    ordering_key_template := emqx_placeholder:tmpl_token(),
    payload_template := emqx_placeholder:tmpl_token(),
    pubsub_topic := binary(),
    request_ttl := infinity | emqx_schema:duration_ms()
}.
-type headers() :: emqx_bridge_gcp_pubsub_client:headers().
-type body() :: emqx_bridge_gcp_pubsub_client:body().
-type status_code() :: emqx_bridge_gcp_pubsub_client:status_code().

%% `emqx_resource' API
-export([
    callback_mode/0,
    query_mode/1,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_query_async/4,
    on_batch_query/3,
    on_batch_query_async/4,
    on_get_status/2,
    on_add_channel/4,
    on_remove_channel/3,
    on_get_channels/1,
    on_get_channel_status/3
]).

-export([reply_delegator/2]).

%%-------------------------------------------------------------------------------------------------
%% `emqx_resource' API
%%-------------------------------------------------------------------------------------------------

callback_mode() -> async_if_possible.

query_mode(_Config) -> async.

-spec on_start(connector_resource_id(), connector_config()) ->
    {ok, connector_state()} | {error, term()}.
on_start(InstanceId, Config0) ->
    ?SLOG(info, #{
        msg => "starting_gcp_pubsub_bridge",
        instance_id => InstanceId
    }),
    Config = maps:update_with(service_account_json, fun emqx_utils_maps:binary_key_map/1, Config0),
    #{service_account_json := #{<<"project_id">> := ProjectId}} = Config,
    case emqx_bridge_gcp_pubsub_client:start(InstanceId, Config) of
        {ok, Client} ->
            State = #{
                client => Client,
                installed_actions => #{},
                project_id => ProjectId
            },
            {ok, State};
        Error ->
            Error
    end.

-spec on_stop(connector_resource_id(), connector_state()) -> ok | {error, term()}.
on_stop(InstanceId, _State) ->
    emqx_bridge_gcp_pubsub_client:stop(InstanceId).

-spec on_get_status(connector_resource_id(), connector_state()) -> connected | disconnected.
on_get_status(_InstanceId, #{client := Client} = _State) ->
    emqx_bridge_gcp_pubsub_client:get_status(Client).

-spec on_query(
    connector_resource_id(),
    {message_tag(), map()},
    connector_state()
) ->
    {ok, map()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_query(ResourceId, {MessageTag, Selected}, ConnectorState) ->
    Requests = [{MessageTag, Selected}],
    ?TRACE(
        "QUERY_SYNC",
        "gcp_pubsub_received",
        #{
            requests => Requests,
            connector => ResourceId,
            state => emqx_utils:redact(ConnectorState)
        }
    ),
    do_send_requests_sync(ConnectorState, Requests, ResourceId).

-spec on_query_async(
    connector_resource_id(),
    {message_tag(), map()},
    {ReplyFun :: function(), Args :: list()},
    connector_state()
) -> {ok, pid()} | {error, no_pool_worker_available}.
on_query_async(ResourceId, {MessageTag, Selected}, ReplyFunAndArgs, ConnectorState) ->
    Requests = [{MessageTag, Selected}],
    ?TRACE(
        "QUERY_ASYNC",
        "gcp_pubsub_received",
        #{
            requests => Requests,
            connector => ResourceId,
            state => emqx_utils:redact(ConnectorState)
        }
    ),
    ?tp(gcp_pubsub_producer_async, #{instance_id => ResourceId, requests => Requests}),
    do_send_requests_async(ConnectorState, Requests, ReplyFunAndArgs).

-spec on_batch_query(
    connector_resource_id(),
    [{message_tag(), map()}],
    connector_state()
) ->
    {ok, map()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
on_batch_query(ResourceId, Requests, ConnectorState) ->
    ?TRACE(
        "QUERY_SYNC",
        "gcp_pubsub_received",
        #{
            requests => Requests,
            connector => ResourceId,
            state => emqx_utils:redact(ConnectorState)
        }
    ),
    do_send_requests_sync(ConnectorState, Requests, ResourceId).

-spec on_batch_query_async(
    connector_resource_id(),
    [{message_tag(), map()}],
    {ReplyFun :: function(), Args :: list()},
    connector_state()
) -> {ok, pid()} | {error, no_pool_worker_available}.
on_batch_query_async(ResourceId, Requests, ReplyFunAndArgs, ConnectorState) ->
    ?TRACE(
        "QUERY_ASYNC",
        "gcp_pubsub_received",
        #{
            requests => Requests,
            connector => ResourceId,
            state => emqx_utils:redact(ConnectorState)
        }
    ),
    ?tp(gcp_pubsub_producer_async, #{instance_id => ResourceId, requests => Requests}),
    do_send_requests_async(ConnectorState, Requests, ReplyFunAndArgs).

-spec on_add_channel(
    connector_resource_id(),
    connector_state(),
    action_resource_id(),
    action_config()
) ->
    {ok, connector_state()}.
on_add_channel(_ConnectorResId, ConnectorState0, ActionId, ActionConfig) ->
    #{installed_actions := InstalledActions0} = ConnectorState0,
    ChannelState = install_channel(ActionConfig),
    InstalledActions = InstalledActions0#{ActionId => ChannelState},
    ConnectorState = ConnectorState0#{installed_actions := InstalledActions},
    {ok, ConnectorState}.

-spec on_remove_channel(
    connector_resource_id(),
    connector_state(),
    action_resource_id()
) ->
    {ok, connector_state()}.
on_remove_channel(_ConnectorResId, ConnectorState0, ActionId) ->
    #{installed_actions := InstalledActions0} = ConnectorState0,
    InstalledActions = maps:remove(ActionId, InstalledActions0),
    ConnectorState = ConnectorState0#{installed_actions := InstalledActions},
    {ok, ConnectorState}.

-spec on_get_channels(connector_resource_id()) ->
    [{action_resource_id(), action_config()}].
on_get_channels(ConnectorResId) ->
    emqx_bridge_v2:get_channels_for_connector(ConnectorResId).

-spec on_get_channel_status(connector_resource_id(), action_resource_id(), connector_state()) ->
    health_check_status().
on_get_channel_status(_ConnectorResId, _ChannelId, _ConnectorState) ->
    %% Should we check the underlying client?  Same as on_get_status?
    ?status_connected.

%%-------------------------------------------------------------------------------------------------
%% Helper fns
%%-------------------------------------------------------------------------------------------------

%% TODO: check if topic exists ("unhealthy target")
install_channel(ActionConfig) ->
    #{
        parameters := #{
            attributes_template := AttributesTemplate,
            ordering_key_template := OrderingKeyTemplate,
            payload_template := PayloadTemplate,
            pubsub_topic := PubSubTopic
        },
        resource_opts := #{
            request_ttl := RequestTTL
        }
    } = ActionConfig,
    #{
        attributes_template => preproc_attributes(AttributesTemplate),
        ordering_key_template => emqx_placeholder:preproc_tmpl(OrderingKeyTemplate),
        payload_template => emqx_placeholder:preproc_tmpl(PayloadTemplate),
        pubsub_topic => PubSubTopic,
        request_ttl => RequestTTL
    }.

-spec do_send_requests_sync(
    connector_state(),
    [{message_tag(), map()}],
    resource_id()
) ->
    {ok, status_code(), headers()}
    | {ok, status_code(), headers(), body()}
    | {error, {recoverable_error, term()}}
    | {error, term()}.
do_send_requests_sync(ConnectorState, Requests, InstanceId) ->
    ?tp(gcp_pubsub_producer_sync, #{instance_id => InstanceId, requests => Requests}),
    #{client := Client} = ConnectorState,
    %% is it safe to assume the tag is the same???  And not empty???
    [{MessageTag, _} | _] = Requests,
    #{installed_actions := InstalledActions} = ConnectorState,
    ChannelState = #{request_ttl := RequestTTL} = maps:get(MessageTag, InstalledActions),
    Payloads =
        lists:map(
            fun({_MessageTag, Selected}) ->
                encode_payload(ChannelState, Selected)
            end,
            Requests
        ),
    Body = to_pubsub_request(Payloads),
    Path = publish_path(ConnectorState, ChannelState),
    Method = post,
    ReqOpts = #{request_ttl => RequestTTL},
    Request = {prepared_request, {Method, Path, Body}, ReqOpts},
    Result = emqx_bridge_gcp_pubsub_client:query_sync(Request, Client),
    QueryMode = sync,
    handle_result(Result, Request, QueryMode, InstanceId).

-spec do_send_requests_async(
    connector_state(),
    [{message_tag(), map()}],
    {ReplyFun :: function(), Args :: list()}
) -> {ok, pid()} | {error, no_pool_worker_available}.
do_send_requests_async(ConnectorState, Requests, ReplyFunAndArgs0) ->
    #{client := Client} = ConnectorState,
    %% is it safe to assume the tag is the same???  And not empty???
    [{MessageTag, _} | _] = Requests,
    #{installed_actions := InstalledActions} = ConnectorState,
    ChannelState = #{request_ttl := RequestTTL} = maps:get(MessageTag, InstalledActions),
    Payloads =
        lists:map(
            fun({_MessageTag, Selected}) ->
                encode_payload(ChannelState, Selected)
            end,
            Requests
        ),
    Body = to_pubsub_request(Payloads),
    Path = publish_path(ConnectorState, ChannelState),
    Method = post,
    ReqOpts = #{request_ttl => RequestTTL},
    Request = {prepared_request, {Method, Path, Body}, ReqOpts},
    ReplyFunAndArgs = {fun ?MODULE:reply_delegator/2, [ReplyFunAndArgs0]},
    emqx_bridge_gcp_pubsub_client:query_async(
        Request, ReplyFunAndArgs, Client
    ).

-spec encode_payload(action_state(), Selected :: map()) ->
    #{
        data := binary(),
        attributes => #{binary() => binary()},
        'orderingKey' => binary()
    }.
encode_payload(ActionState, Selected) ->
    #{
        attributes_template := AttributesTemplate,
        ordering_key_template := OrderingKeyTemplate,
        payload_template := PayloadTemplate
    } = ActionState,
    Data = render_payload(PayloadTemplate, Selected),
    OrderingKey = render_key(OrderingKeyTemplate, Selected),
    Attributes = proc_attributes(AttributesTemplate, Selected),
    Payload0 = #{data => base64:encode(Data)},
    Payload1 = emqx_utils_maps:put_if(Payload0, attributes, Attributes, map_size(Attributes) > 0),
    emqx_utils_maps:put_if(Payload1, 'orderingKey', OrderingKey, OrderingKey =/= <<>>).

-spec render_payload(emqx_placeholder:tmpl_token(), map()) -> binary().
render_payload([] = _Template, Selected) ->
    emqx_utils_json:encode(Selected);
render_payload(Template, Selected) ->
    render_value(Template, Selected).

render_key(Template, Selected) ->
    Opts = #{
        return => full_binary,
        var_trans => fun
            (_Var, undefined) ->
                <<>>;
            (Var, X) when is_boolean(X) ->
                throw({bad_value_for_key, Var, X});
            (_Var, X) when is_binary(X); is_number(X); is_atom(X) ->
                emqx_utils_conv:bin(X);
            (Var, X) ->
                throw({bad_value_for_key, Var, X})
        end
    },
    try
        emqx_placeholder:proc_tmpl(Template, Selected, Opts)
    catch
        throw:{bad_value_for_key, Var, X} ->
            ?tp(
                warning,
                "gcp_pubsub_producer_bad_value_for_key",
                #{
                    placeholder => Var,
                    value => X,
                    action => "key ignored",
                    hint => "only plain values like strings and numbers can be used in keys"
                }
            ),
            <<>>
    end.

render_value(Template, Selected) ->
    Opts = #{
        return => full_binary,
        var_trans => fun
            (undefined) -> <<>>;
            (X) -> emqx_utils_conv:bin(X)
        end
    },
    emqx_placeholder:proc_tmpl(Template, Selected, Opts).

-spec preproc_attributes([#{key := binary(), value := binary()}]) ->
    #{emqx_placeholder:tmpl_token() => emqx_placeholder:tmpl_token()}.
preproc_attributes(AttributesTemplate) ->
    lists:foldl(
        fun(#{key := K, value := V}, Acc) ->
            KT = emqx_placeholder:preproc_tmpl(K),
            VT = emqx_placeholder:preproc_tmpl(V),
            Acc#{KT => VT}
        end,
        #{},
        AttributesTemplate
    ).

-spec proc_attributes(#{emqx_placeholder:tmpl_token() => emqx_placeholder:tmpl_token()}, map()) ->
    #{binary() => binary()}.
proc_attributes(AttributesTemplate, Selected) ->
    maps:fold(
        fun(KT, VT, Acc) ->
            K = render_key(KT, Selected),
            case K =:= <<>> of
                true ->
                    Acc;
                false ->
                    V = render_value(VT, Selected),
                    Acc#{K => V}
            end
        end,
        #{},
        AttributesTemplate
    ).

-spec to_pubsub_request([#{data := binary()}]) -> binary().
to_pubsub_request(Payloads) ->
    emqx_utils_json:encode(#{messages => Payloads}).

-spec publish_path(connector_state(), action_state()) -> binary().
publish_path(#{project_id := ProjectId}, #{pubsub_topic := PubSubTopic}) ->
    <<"/v1/projects/", ProjectId/binary, "/topics/", PubSubTopic/binary, ":publish">>.

handle_result({error, Reason}, _Request, QueryMode, ResourceId) when
    Reason =:= econnrefused;
    %% this comes directly from `gun'...
    Reason =:= {closed, "The connection was lost."};
    Reason =:= timeout
->
    ?tp(
        warning,
        gcp_pubsub_request_failed,
        #{
            reason => Reason,
            query_mode => QueryMode,
            recoverable_error => true,
            connector => ResourceId
        }
    ),
    {error, {recoverable_error, Reason}};
handle_result(
    {error, #{status_code := StatusCode, body := RespBody}} = Result,
    Request,
    _QueryMode,
    ResourceId
) ->
    ?SLOG(error, #{
        msg => "gcp_pubsub_error_response",
        request => emqx_bridge_http_connector:redact_request(Request),
        connector => ResourceId,
        status_code => StatusCode,
        resp_body => RespBody
    }),
    Result;
handle_result({error, #{status_code := StatusCode}} = Result, Request, _QueryMode, ResourceId) ->
    ?SLOG(error, #{
        msg => "gcp_pubsub_error_response",
        request => emqx_bridge_http_connector:redact_request(Request),
        connector => ResourceId,
        status_code => StatusCode
    }),
    Result;
handle_result({error, Reason} = Result, _Request, QueryMode, ResourceId) ->
    ?tp(
        error,
        gcp_pubsub_request_failed,
        #{
            reason => Reason,
            query_mode => QueryMode,
            recoverable_error => false,
            connector => ResourceId
        }
    ),
    Result;
handle_result({ok, _} = Result, _Request, _QueryMode, _ResourceId) ->
    Result.

reply_delegator(ReplyFunAndArgs, Response) ->
    case Response of
        {error, Reason} when
            Reason =:= econnrefused;
            %% this comes directly from `gun'...
            Reason =:= {closed, "The connection was lost."};
            Reason =:= timeout
        ->
            Result = {error, {recoverable_error, Reason}},
            emqx_resource:apply_reply_fun(ReplyFunAndArgs, Result);
        _ ->
            emqx_resource:apply_reply_fun(ReplyFunAndArgs, Response)
    end.
