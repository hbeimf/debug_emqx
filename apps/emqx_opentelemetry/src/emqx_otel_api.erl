%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_otel_api).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/http_api.hrl").

-import(hoconsc, [ref/2]).

-export([
    api_spec/0,
    paths/0,
    schema/1
]).

-export([config/2]).

-define(TAGS, [<<"Monitor">>]).

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/opentelemetry"
    ].

schema("/opentelemetry") ->
    #{
        'operationId' => config,
        get =>
            #{
                description => "Get opentelmetry configuration",
                tags => ?TAGS,
                responses =>
                    #{200 => otel_config_schema()}
            },
        put =>
            #{
                description => "Update opentelmetry configuration",
                tags => ?TAGS,
                'requestBody' => otel_config_schema(),
                responses =>
                    #{
                        200 => otel_config_schema(),
                        400 =>
                            emqx_dashboard_swagger:error_codes(
                                [?BAD_REQUEST], <<"Update Config Failed">>
                            )
                    }
            }
    }.

%%--------------------------------------------------------------------
%% API Handler funcs
%%--------------------------------------------------------------------

config(get, _Params) ->
    {200, get_raw()};
config(put, #{body := Body}) ->
    case emqx_otel_config:update(Body) of
        {ok, NewConfig} ->
            {200, NewConfig};
        {error, Reason} ->
            Message = list_to_binary(io_lib:format("Update config failed ~p", [Reason])),
            {400, ?BAD_REQUEST, Message}
    end.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

get_raw() ->
    Path = <<"opentelemetry">>,
    #{Path := Conf} =
        emqx_config:fill_defaults(
            #{Path => emqx_conf:get_raw([Path])},
            #{obfuscate_sensitive_values => true}
        ),
    Conf.

otel_config_schema() ->
    emqx_dashboard_swagger:schema_with_example(
        ref(emqx_otel_schema, "opentelemetry"),
        otel_config_example()
    ).

otel_config_example() ->
    #{
        exporter => #{
            endpoint => "http://localhost:4317",
            ssl_options => #{}
        },
        logs => #{
            enable => true,
            level => warning
        },
        metrics => #{
            enable => true
        },
        traces => #{
            enable => true,
            filter => #{trace_all => false}
        }
    }.
