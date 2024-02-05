%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_s3_profile_conf).

-behaviour(gen_server).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/types.hrl").

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-include("emqx_s3.hrl").

-export([
    start_link/2,
    child_spec/2
]).

-export([
    checkout_config/1,
    checkout_config/2,
    checkin_config/1,
    checkin_config/2,

    update_config/2,
    update_config/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% For test purposes
-export([
    client_config/2,
    start_http_pool/2,
    id/1
]).

-define(DEFAULT_CALL_TIMEOUT, 5000).

-define(DEFAULT_HTTP_POOL_TIMEOUT, 60000).
-define(DEAFULT_HTTP_POOL_CLEANUP_INTERVAL, 60000).

-define(SAFE_CALL_VIA_GPROC(ProfileId, Message, Timeout),
    ?SAFE_CALL_VIA_GPROC(id(ProfileId), Message, Timeout, profile_not_found)
).

-spec child_spec(emqx_s3:profile_id(), emqx_s3:profile_config()) -> supervisor:child_spec().
child_spec(ProfileId, ProfileConfig) ->
    #{
        id => ProfileId,
        start => {?MODULE, start_link, [ProfileId, ProfileConfig]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link(emqx_s3:profile_id(), emqx_s3:profile_config()) -> gen_server:start_ret().
start_link(ProfileId, ProfileConfig) ->
    gen_server:start_link(?VIA_GPROC(id(ProfileId)), ?MODULE, [ProfileId, ProfileConfig], []).

-spec update_config(emqx_s3:profile_id(), emqx_s3:profile_config()) -> ok_or_error(term()).
update_config(ProfileId, ProfileConfig) ->
    update_config(ProfileId, ProfileConfig, ?DEFAULT_CALL_TIMEOUT).

-spec update_config(emqx_s3:profile_id(), emqx_s3:profile_config(), timeout()) ->
    ok_or_error(term()).
update_config(ProfileId, ProfileConfig, Timeout) ->
    ?SAFE_CALL_VIA_GPROC(ProfileId, {update_config, ProfileConfig}, Timeout).

-spec checkout_config(emqx_s3:profile_id()) ->
    {ok, emqx_s3_client:config(), emqx_s3_uploader:config()} | {error, profile_not_found}.
checkout_config(ProfileId) ->
    checkout_config(ProfileId, ?DEFAULT_CALL_TIMEOUT).

-spec checkout_config(emqx_s3:profile_id(), timeout()) ->
    {ok, emqx_s3_client:config(), emqx_s3_uploader:config()} | {error, profile_not_found}.
checkout_config(ProfileId, Timeout) ->
    ?SAFE_CALL_VIA_GPROC(ProfileId, {checkout_config, self()}, Timeout).

-spec checkin_config(emqx_s3:profile_id()) -> ok | {error, profile_not_found}.
checkin_config(ProfileId) ->
    checkin_config(ProfileId, ?DEFAULT_CALL_TIMEOUT).

-spec checkin_config(emqx_s3:profile_id(), timeout()) -> ok | {error, profile_not_found}.
checkin_config(ProfileId, Timeout) ->
    ?SAFE_CALL_VIA_GPROC(ProfileId, {checkin_config, self()}, Timeout).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([ProfileId, ProfileConfig]) ->
    _ = process_flag(trap_exit, true),
    ok = cleanup_profile_pools(ProfileId),
    case start_http_pool(ProfileId, ProfileConfig) of
        {ok, PoolName} ->
            HttpPoolCleanupInterval = http_pool_cleanup_interval(ProfileConfig),
            {ok, #{
                profile_id => ProfileId,
                profile_config => ProfileConfig,
                client_config => client_config(ProfileConfig, PoolName),
                uploader_config => uploader_config(ProfileConfig),
                pool_name => PoolName,
                pool_clients => emqx_s3_profile_http_pool_clients:create_table(),
                %% We don't expose these options to users currently, but use in tests
                http_pool_timeout => http_pool_timeout(ProfileConfig),
                http_pool_cleanup_interval => HttpPoolCleanupInterval,

                outdated_pool_cleanup_tref => erlang:send_after(
                    HttpPoolCleanupInterval, self(), cleanup_outdated
                )
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(
    {checkout_config, Pid},
    _From,
    #{
        client_config := ClientConfig,
        uploader_config := UploaderConfig
    } = State
) ->
    ok = register_client(Pid, State),
    {reply, {ok, ClientConfig, UploaderConfig}, State};
handle_call({checkin_config, Pid}, _From, State) ->
    ok = unregister_client(Pid, State),
    {reply, ok, State};
handle_call(
    {update_config, NewProfileConfig},
    _From,
    #{profile_id := ProfileId} = State
) ->
    case update_http_pool(ProfileId, NewProfileConfig, State) of
        {ok, PoolName} ->
            NewState = State#{
                profile_config => NewProfileConfig,
                client_config => client_config(NewProfileConfig, PoolName),
                uploader_config => uploader_config(NewProfileConfig),
                http_pool_timeout => http_pool_timeout(NewProfileConfig),
                http_pool_cleanup_interval => http_pool_cleanup_interval(NewProfileConfig),
                pool_name => PoolName
            },
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    ok = unregister_client(Pid, State),
    {noreply, State};
handle_info(cleanup_outdated, #{http_pool_cleanup_interval := HttpPoolCleanupInterval} = State0) ->
    %% Maybe cleanup asynchoronously
    ok = cleanup_outdated_pools(State0),
    State1 = State0#{
        outdated_pool_cleanup_tref => erlang:send_after(
            HttpPoolCleanupInterval, self(), cleanup_outdated
        )
    },
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{profile_id := ProfileId}) ->
    cleanup_profile_pools(ProfileId).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

id(ProfileId) ->
    {?MODULE, ProfileId}.

client_config(ProfileConfig, PoolName) ->
    HTTPOpts = maps:get(transport_options, ProfileConfig, #{}),
    #{
        scheme => scheme(HTTPOpts),
        host => maps:get(host, ProfileConfig),
        port => maps:get(port, ProfileConfig),
        url_expire_time => maps:get(url_expire_time, ProfileConfig),
        headers => maps:get(headers, HTTPOpts, #{}),
        acl => maps:get(acl, ProfileConfig, undefined),
        bucket => maps:get(bucket, ProfileConfig),
        access_key_id => maps:get(access_key_id, ProfileConfig, undefined),
        secret_access_key => maps:get(secret_access_key, ProfileConfig, undefined),
        request_timeout => maps:get(request_timeout, HTTPOpts, undefined),
        max_retries => maps:get(max_retries, HTTPOpts, undefined),
        pool_type => maps:get(pool_type, HTTPOpts, random),
        http_pool => PoolName
    }.

uploader_config(#{max_part_size := MaxPartSize, min_part_size := MinPartSize} = _ProfileConfig) ->
    #{
        min_part_size => MinPartSize,
        max_part_size => MaxPartSize
    }.

scheme(#{ssl := #{enable := true}}) -> "https://";
scheme(_TransportOpts) -> "http://".

start_http_pool(ProfileId, ProfileConfig) ->
    HttpConfig = http_config(ProfileConfig),
    PoolName = pool_name(ProfileId),
    case do_start_http_pool(PoolName, HttpConfig) of
        ok ->
            ok = emqx_s3_profile_http_pools:register(ProfileId, PoolName),
            ok = ?tp(debug, "s3_start_http_pool", #{pool_name => PoolName, profile_id => ProfileId}),
            {ok, PoolName};
        {error, _} = Error ->
            Error
    end.

update_http_pool(ProfileId, ProfileConfig, #{pool_name := OldPoolName} = State) ->
    HttpConfig = http_config(ProfileConfig),
    OldHttpConfig = old_http_config(State),
    case OldHttpConfig =:= HttpConfig of
        true ->
            {ok, OldPoolName};
        false ->
            PoolName = pool_name(ProfileId),
            case do_start_http_pool(PoolName, HttpConfig) of
                ok ->
                    ok = set_old_pool_outdated(State),
                    ok = emqx_s3_profile_http_pools:register(ProfileId, PoolName),
                    {ok, PoolName};
                {error, _} = Error ->
                    Error
            end
    end.

pool_name(ProfileId) ->
    iolist_to_binary([
        <<"s3-http-">>,
        profile_id_to_bin(ProfileId),
        <<"-">>,
        integer_to_binary(erlang:system_time(millisecond)),
        <<"-">>,
        integer_to_binary(erlang:unique_integer([positive]))
    ]).
profile_id_to_bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
profile_id_to_bin(Bin) when is_binary(Bin) -> Bin.

old_http_config(#{profile_config := ProfileConfig}) -> http_config(ProfileConfig).

set_old_pool_outdated(#{
    profile_id := ProfileId, pool_name := PoolName, http_pool_timeout := HttpPoolTimeout
}) ->
    _ = emqx_s3_profile_http_pools:set_outdated(ProfileId, PoolName, HttpPoolTimeout),
    ok.

cleanup_profile_pools(ProfileId) ->
    lists:foreach(
        fun(PoolName) ->
            ok = stop_http_pool(ProfileId, PoolName)
        end,
        emqx_s3_profile_http_pools:all(ProfileId)
    ).

register_client(Pid, #{profile_id := ProfileId, pool_clients := PoolClients, pool_name := PoolName}) ->
    MRef = monitor(process, Pid),
    ok = emqx_s3_profile_http_pool_clients:register(PoolClients, Pid, MRef, PoolName),
    _ = emqx_s3_profile_http_pools:register_client(ProfileId, PoolName),
    ok.

unregister_client(
    Pid,
    #{
        profile_id := ProfileId, pool_clients := PoolClients, pool_name := PoolName
    }
) ->
    case emqx_s3_profile_http_pool_clients:unregister(PoolClients, Pid) of
        undefined ->
            ok;
        {MRef, PoolName} ->
            true = erlang:demonitor(MRef, [flush]),
            _ = emqx_s3_profile_http_pools:unregister_client(ProfileId, PoolName),
            ok;
        {MRef, OutdatedPoolName} ->
            true = erlang:demonitor(MRef, [flush]),
            ClientNum = emqx_s3_profile_http_pools:unregister_client(ProfileId, OutdatedPoolName),
            maybe_stop_outdated_pool(ProfileId, OutdatedPoolName, ClientNum)
    end.

maybe_stop_outdated_pool(ProfileId, OutdatedPoolName, 0) ->
    ok = stop_http_pool(ProfileId, OutdatedPoolName);
maybe_stop_outdated_pool(_ProfileId, _OutdatedPoolName, _ClientNum) ->
    ok.

cleanup_outdated_pools(#{profile_id := ProfileId}) ->
    lists:foreach(
        fun(PoolName) ->
            ok = stop_http_pool(ProfileId, PoolName)
        end,
        emqx_s3_profile_http_pools:outdated(ProfileId)
    ).

%%--------------------------------------------------------------------
%% HTTP Pool implementation dependent functions
%%--------------------------------------------------------------------

http_config(
    #{
        host := Host,
        port := Port,
        transport_options := #{
            pool_type := PoolType,
            pool_size := PoolSize,
            enable_pipelining := EnablePipelining,
            connect_timeout := ConnectTimeout
        } = HTTPOpts
    }
) ->
    {Transport, TransportOpts} =
        case scheme(HTTPOpts) of
            "http://" ->
                {tcp, []};
            "https://" ->
                SSLOpts = emqx_tls_lib:to_client_opts(maps:get(ssl, HTTPOpts)),
                {tls, SSLOpts}
        end,
    NTransportOpts = maybe_ipv6_probe(TransportOpts, maps:get(ipv6_probe, HTTPOpts, true)),
    [
        {host, Host},
        {port, Port},
        {connect_timeout, ConnectTimeout},
        {keepalive, 30000},
        {pool_type, PoolType},
        {pool_size, PoolSize},
        {transport, Transport},
        {transport_opts, NTransportOpts},
        {enable_pipelining, EnablePipelining}
    ].

maybe_ipv6_probe(TransportOpts, true) ->
    emqx_utils:ipv6_probe(TransportOpts);
maybe_ipv6_probe(TransportOpts, false) ->
    TransportOpts.

http_pool_cleanup_interval(ProfileConfig) ->
    maps:get(
        http_pool_cleanup_interval, ProfileConfig, ?DEAFULT_HTTP_POOL_CLEANUP_INTERVAL
    ).

http_pool_timeout(ProfileConfig) ->
    maps:get(
        http_pool_timeout, ProfileConfig, ?DEFAULT_HTTP_POOL_TIMEOUT
    ).

stop_http_pool(ProfileId, PoolName) ->
    case ehttpc_sup:stop_pool(PoolName) of
        ok ->
            ok;
        {error, Reason} ->
            ?SLOG(error, #{msg => "ehttpc_pool_stop_fail", pool_name => PoolName, reason => Reason}),
            ok
    end,
    ok = emqx_s3_profile_http_pools:unregister(ProfileId, PoolName),
    ok = ?tp(debug, "s3_stop_http_pool", #{pool_name => PoolName}).

do_start_http_pool(PoolName, HttpConfig) ->
    ?SLOG(debug, #{msg => "s3_starting_http_pool", pool_name => PoolName, config => HttpConfig}),
    case ehttpc_sup:start_pool(PoolName, HttpConfig) of
        {ok, _} ->
            ?SLOG(info, #{msg => "s3_start_http_pool_success", pool_name => PoolName}),
            ok;
        {error, _} = Error ->
            ?SLOG(error, #{msg => "s3_start_http_pool_fail", pool_name => PoolName, error => Error}),
            Error
    end.
