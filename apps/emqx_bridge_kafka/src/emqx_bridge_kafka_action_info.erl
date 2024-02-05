%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_kafka_action_info).

-behaviour(emqx_action_info).

-export([
    bridge_v1_type_name/0,
    action_type_name/0,
    connector_type_name/0,
    schema_module/0,
    connector_action_config_to_bridge_v1_config/2,
    bridge_v1_config_to_action_config/2
]).

bridge_v1_type_name() -> kafka.

action_type_name() -> kafka_producer.

connector_type_name() -> kafka_producer.

schema_module() -> emqx_bridge_kafka.

connector_action_config_to_bridge_v1_config(ConnectorConfig, ActionConfig) ->
    BridgeV1Config1 = maps:remove(<<"connector">>, ActionConfig),
    BridgeV1Config2 = emqx_utils_maps:deep_merge(ConnectorConfig, BridgeV1Config1),
    emqx_utils_maps:rename(<<"parameters">>, <<"kafka">>, BridgeV1Config2).

bridge_v1_config_to_action_config(BridgeV1Conf, ConnectorName) ->
    Config0 = emqx_action_info:transform_bridge_v1_config_to_action_config(
        BridgeV1Conf, ConnectorName, schema_module(), kafka_producer
    ),
    KafkaMap = maps:get(<<"kafka">>, BridgeV1Conf, #{}),
    Config2 = emqx_utils_maps:deep_merge(Config0, #{<<"parameters">> => KafkaMap}),
    maps:with(producer_action_field_keys(), Config2).

%%------------------------------------------------------------------------------------------
%% Internal helper functions
%%------------------------------------------------------------------------------------------

producer_action_field_keys() ->
    [
        to_bin(K)
     || {K, _} <- emqx_bridge_kafka:fields(kafka_producer_action)
    ].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
