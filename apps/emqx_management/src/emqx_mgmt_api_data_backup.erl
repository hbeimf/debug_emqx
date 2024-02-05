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

-module(emqx_mgmt_api_data_backup).

-behaviour(minirest_api).

-include_lib("emqx/include/logger.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([api_spec/0, paths/0, schema/1, fields/1]).

-export([
    data_export/2,
    data_import/2,
    data_files/2,
    data_file_by_name/2
]).

-define(TAGS, [<<"Data Backup">>]).

-define(BAD_REQUEST, 'BAD_REQUEST').
-define(NOT_FOUND, 'NOT_FOUND').

-define(node_field(IsRequired), ?node_field(IsRequired, #{})).
-define(node_field(IsRequired, Meta),
    {node, ?HOCON(binary(), Meta#{desc => "Node name", required => IsRequired})}
).
-define(filename_field(IsRequired), ?filename_field(IsRequired, #{})).
-define(filename_field(IsRequired, Meta),
    {filename,
        ?HOCON(binary(), Meta#{
            desc => "Data backup file name",
            required => IsRequired
        })}
).

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/data/export",
        "/data/import",
        "/data/files",
        "/data/files/:filename"
    ].

schema("/data/export") ->
    #{
        'operationId' => data_export,
        post => #{
            tags => ?TAGS,
            desc => <<"Export a data backup file">>,
            responses => #{
                200 =>
                    emqx_dashboard_swagger:schema_with_example(
                        ?R_REF(backup_file_info),
                        backup_file_info_example()
                    )
            }
        }
    };
schema("/data/import") ->
    #{
        'operationId' => data_import,
        post => #{
            tags => ?TAGS,
            desc => <<"Import a data backup file">>,
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                ?R_REF(import_request_body),
                maps:with([node, filename], backup_file_info_example())
            ),

            responses => #{
                204 => <<"No Content">>,
                400 => emqx_dashboard_swagger:error_codes(
                    [?BAD_REQUEST], <<"Backup file import failed">>
                )
            }
        }
    };
schema("/data/files") ->
    #{
        'operationId' => data_files,
        post => #{
            tags => ?TAGS,
            desc => <<"Upload a data backup file">>,
            'requestBody' => emqx_dashboard_swagger:file_schema(filename),
            responses => #{
                204 => <<"No Content">>,
                400 => emqx_dashboard_swagger:error_codes(
                    [?BAD_REQUEST], <<"Bad backup file">>
                )
            }
        },
        get => #{
            tags => ?TAGS,
            desc => <<"List backup files">>,
            parameters => [
                ?R_REF(emqx_dashboard_swagger, page),
                ?R_REF(emqx_dashboard_swagger, limit)
            ],
            responses => #{
                200 =>
                    emqx_dashboard_swagger:schema_with_example(
                        ?R_REF(files_response),
                        files_response_example()
                    )
            }
        }
    };
schema("/data/files/:filename") ->
    #{
        'operationId' => data_file_by_name,
        get => #{
            tags => ?TAGS,
            desc => <<"Download a data backup file">>,
            parameters => [
                ?filename_field(true, #{in => path}),
                ?node_field(false, #{in => query})
            ],
            responses => #{
                200 => ?HOCON(binary),
                400 => emqx_dashboard_swagger:error_codes(
                    [?BAD_REQUEST], <<"Bad request">>
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    [?NOT_FOUND], <<"Backup file not found">>
                )
            }
        },
        delete => #{
            tags => ?TAGS,
            desc => <<"Delete a data backup file">>,
            parameters => [
                ?filename_field(true, #{in => path}),
                ?node_field(false, #{in => query})
            ],
            responses => #{
                204 => <<"No Content">>,
                400 => emqx_dashboard_swagger:error_codes(
                    [?BAD_REQUEST], <<"Bad request">>
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    [?NOT_FOUND], <<"Backup file not found">>
                )
            }
        }
    }.

fields(files_response) ->
    [
        {data, ?ARRAY(?R_REF(backup_file_info))},
        {meta, ?R_REF(emqx_dashboard_swagger, meta)}
    ];
fields(backup_file_info) ->
    [
        ?node_field(true),
        ?filename_field(true),
        {created_at,
            ?HOCON(binary(), #{
                desc => "Data backup file creation date and time",
                required => true
            })}
    ];
fields(import_request_body) ->
    [?node_field(false), ?filename_field(true)];
fields(data_backup_file) ->
    [
        ?filename_field(true),
        {file,
            ?HOCON(binary(), #{
                desc => "Data backup file content",
                required => true
            })}
    ].

%%------------------------------------------------------------------------------
%% HTTP API Callbacks
%%------------------------------------------------------------------------------

data_export(post, _Request) ->
    case emqx_mgmt_data_backup:export() of
        {ok, #{filename := FileName} = File} ->
            {200, File#{filename => filename:basename(FileName)}};
        Error ->
            Error
    end.

data_import(post, #{body := #{<<"filename">> := FileName} = Body}) ->
    case safe_parse_node(Body) of
        {error, Msg} ->
            {400, #{code => ?BAD_REQUEST, message => Msg}};
        FileNode ->
            CoreNode = core_node(FileNode),
            response(
                emqx_mgmt_data_backup_proto_v1:import_file(CoreNode, FileNode, FileName, infinity)
            )
    end.

core_node(FileNode) ->
    case mria_rlog:role(FileNode) of
        core ->
            FileNode;
        replicant ->
            case mria_rlog:role() of
                core ->
                    node();
                replicant ->
                    mria_membership:coordinator()
            end
    end.

data_files(post, #{body := #{<<"filename">> := #{type := _} = File}}) ->
    [{FileName, FileContent} | _] = maps:to_list(maps:without([type], File)),
    case emqx_mgmt_data_backup:upload(FileName, FileContent) of
        ok ->
            {204};
        {error, Reason} ->
            {400, #{code => ?BAD_REQUEST, message => emqx_mgmt_data_backup:format_error(Reason)}}
    end;
data_files(post, #{body := _}) ->
    {400, #{code => ?BAD_REQUEST, message => "Missing required parameter: filename"}};
data_files(get, #{query_string := PageParams}) ->
    case emqx_mgmt_api:parse_pager_params(PageParams) of
        false ->
            {400, #{code => ?BAD_REQUEST, message => <<"page_limit_invalid">>}};
        #{page := Page, limit := Limit} = Pager ->
            {Count, HasNext, Data} = list_backup_files(Page, Limit),
            {200, #{data => Data, meta => Pager#{count => Count, hasnext => HasNext}}}
    end.

data_file_by_name(Method, #{bindings := #{filename := Filename}, query_string := QS}) ->
    case safe_parse_node(QS) of
        {error, Msg} ->
            {400, #{code => ?BAD_REQUEST, message => Msg}};
        Node ->
            case get_or_delete_file(Method, Filename, Node) of
                {error, not_found} ->
                    {404, #{
                        code => ?NOT_FOUND, message => emqx_mgmt_data_backup:format_error(not_found)
                    }};
                Other ->
                    response(Other)
            end
    end.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

get_or_delete_file(get, Filename, Node) ->
    emqx_mgmt_data_backup_proto_v1:read_file(Node, Filename, infinity);
get_or_delete_file(delete, Filename, Node) ->
    emqx_mgmt_data_backup_proto_v1:delete_file(Node, Filename, infinity).

safe_parse_node(#{<<"node">> := NodeBin}) ->
    NodesBin = [erlang:atom_to_binary(N, utf8) || N <- emqx:running_nodes()],
    case lists:member(NodeBin, NodesBin) of
        true -> erlang:binary_to_atom(NodeBin, utf8);
        false -> {error, io_lib:format("Unknown node: ~s", [NodeBin])}
    end;
safe_parse_node(_) ->
    node().

response({ok, #{db_errors := DbErrs, config_errors := ConfErrs}}) ->
    case DbErrs =:= #{} andalso ConfErrs =:= #{} of
        true ->
            {204};
        false ->
            DbErrs1 = emqx_mgmt_data_backup:format_db_errors(DbErrs),
            ConfErrs1 = emqx_mgmt_data_backup:format_conf_errors(ConfErrs),
            Msg = unicode:characters_to_binary(io_lib:format("~s", [DbErrs1 ++ ConfErrs1])),
            {400, #{code => ?BAD_REQUEST, message => Msg}}
    end;
response({ok, Res}) ->
    {200, Res};
response(ok) ->
    {204};
response({error, Reason}) ->
    {400, #{code => ?BAD_REQUEST, message => emqx_mgmt_data_backup:format_error(Reason)}}.

list_backup_files(Page, Limit) ->
    Start = Page * Limit - Limit + 1,
    AllFiles = list_backup_files(),
    Count = length(AllFiles),
    HasNext = Start + Limit - 1 < Count,
    {Count, HasNext, lists:sublist(AllFiles, Start, Limit)}.

list_backup_files() ->
    Nodes = emqx:running_nodes(),
    Results = emqx_mgmt_data_backup_proto_v1:list_files(Nodes, 30_0000),
    NodeResults = lists:zip(Nodes, Results),
    {Successes, Failures} =
        lists:partition(
            fun({_Node, Result}) ->
                case Result of
                    {ok, _} -> true;
                    _ -> false
                end
            end,
            NodeResults
        ),
    case Failures of
        [] ->
            ok;
        [_ | _] ->
            ?SLOG(error, #{msg => "list_exported_backup_files_failed", node_errors => Failures})
    end,
    FileList = [FileInfo || {_Node, {ok, FileInfos}} <- Successes, FileInfo <- FileInfos],
    lists:sort(
        fun(#{created_at_sec := T1, filename := F1}, #{created_at_sec := T2, filename := F2}) ->
            case T1 =:= T2 of
                true -> F1 >= F2;
                false -> T1 > T2
            end
        end,
        FileList
    ).

backup_file_info_example() ->
    #{
        created_at => <<"2023-11-23T19:13:19+02:00">>,
        created_at_sec => 1700759599,
        filename => <<"emqx-export-2023-11-23-19-13-19.043.tar.gz">>,
        node => 'emqx@127.0.0.1',
        size => 22740
    }.

files_response_example() ->
    #{
        data => [
            #{
                created_at => <<"2023-09-02T11:11:33+02:00">>,
                created_at_sec => 1693645893,
                filename => <<"emqx-export-2023-09-02-11-11-33.012.tar.gz">>,
                node => 'emqx@127.0.0.1',
                size => 22740
            },
            #{
                created_at => <<"2023-11-23T19:13:19+02:00">>,
                created_at_sec => 1700759599,
                filename => <<"emqx-export-2023-11-23-19-13-19.043.tar.gz">>,
                node => 'emqx@127.0.0.1',
                size => 22740
            }
        ],
        meta => #{
            page => 0,
            limit => 20,
            count => 300
        }
    }.
