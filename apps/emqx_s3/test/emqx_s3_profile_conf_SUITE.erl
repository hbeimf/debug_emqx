%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_s3_profile_conf_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/asserts.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

suite() -> [{timetrap, {minutes, 1}}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(emqx_s3),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(emqx_s3).

init_per_testcase(_TestCase, Config) ->
    ok = snabbkaffe:start_trace(),
    TestAwsConfig = emqx_s3_test_helpers:aws_config(tcp),

    Bucket = emqx_s3_test_helpers:unique_bucket(),
    ok = erlcloud_s3:create_bucket(Bucket, TestAwsConfig),

    ProfileBaseConfig = emqx_s3_test_helpers:base_config(tcp),
    ProfileConfig = ProfileBaseConfig#{bucket => Bucket},
    ok = emqx_s3:start_profile(profile_id(), ProfileConfig),

    [{profile_config, ProfileConfig} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok = snabbkaffe:stop(),
    _ = emqx_s3:stop_profile(profile_id()).

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_regular_outdated_pool_cleanup(Config) ->
    _ = process_flag(trap_exit, true),
    Key = emqx_s3_test_helpers:unique_key(),
    {ok, Pid} = emqx_s3:start_uploader(profile_id(), #{key => Key}),

    [OldPool] = emqx_s3_profile_http_pools:all(profile_id()),

    ProfileBaseConfig = ?config(profile_config, Config),
    ProfileConfig = emqx_utils_maps:deep_put(
        [transport_options, pool_size], ProfileBaseConfig, 16
    ),
    ok = emqx_s3:update_profile(profile_id(), ProfileConfig),

    ?assertEqual(
        2,
        length(emqx_s3_profile_http_pools:all(profile_id()))
    ),

    ?assertWaitEvent(
        ok = emqx_s3_uploader:abort(Pid),
        #{?snk_kind := "s3_stop_http_pool", pool_name := OldPool},
        1000
    ),

    [NewPool] = emqx_s3_profile_http_pools:all(profile_id()),

    ?assertWaitEvent(
        ok = emqx_s3:stop_profile(profile_id()),
        #{?snk_kind := "s3_stop_http_pool", pool_name := NewPool},
        1000
    ),

    ?assertEqual(
        0,
        length(emqx_s3_profile_http_pools:all(profile_id()))
    ).

t_timeout_pool_cleanup(Config) ->
    _ = process_flag(trap_exit, true),

    %% We restart the profile to set `http_pool_timeout` value suitable for test
    ok = emqx_s3:stop_profile(profile_id()),
    ProfileBaseConfig = ?config(profile_config, Config),
    ProfileConfig = ProfileBaseConfig#{
        http_pool_timeout => 500,
        http_pool_cleanup_interval => 100
    },
    ok = emqx_s3:start_profile(profile_id(), ProfileConfig),

    %% Start uploader
    Key = emqx_s3_test_helpers:unique_key(),
    {ok, Pid} = emqx_s3:start_uploader(profile_id(), #{key => Key}),
    ok = emqx_s3_uploader:write(Pid, <<"data">>),

    [OldPool] = emqx_s3_profile_http_pools:all(profile_id()),

    NewProfileConfig = emqx_utils_maps:deep_put(
        [transport_options, pool_size], ProfileConfig, 16
    ),

    %% We update profile to create new pool and wait for the old one to be stopped by timeout
    ?assertWaitEvent(
        ok = emqx_s3:update_profile(profile_id(), NewProfileConfig),
        #{?snk_kind := "s3_stop_http_pool", pool_name := OldPool},
        1000
    ),

    %% The uploader now has no valid pool and should fail
    ?assertMatch(
        {error, _},
        emqx_s3_uploader:complete(Pid)
    ).

t_checkout_no_profile(_Config) ->
    ?assertEqual(
        {error, profile_not_found},
        emqx_s3_profile_conf:checkout_config(<<"no_such_profile">>)
    ).

t_httpc_pool_start_error(Config) ->
    %% `ehhtpc_pool`s are lazy so it is difficult to trigger an error
    %% passing some bad connection options.
    %% So we emulate some unknown crash with `meck`.
    meck:new(ehttpc_pool, [passthrough]),
    meck:expect(ehttpc_pool, init, fun(_) -> meck:raise(error, badarg) end),

    ?assertMatch(
        {error, _},
        emqx_s3:start_profile(<<"profile">>, ?config(profile_config, Config))
    ).

t_httpc_pool_update_error(Config) ->
    %% `ehhtpc_pool`s are lazy so it is difficult to trigger an error
    %% passing some bad connection options.
    %% So we emulate some unknown crash with `meck`.
    meck:new(ehttpc_pool, [passthrough]),
    meck:expect(ehttpc_pool, init, fun(_) -> meck:raise(error, badarg) end),

    ProfileBaseConfig = ?config(profile_config, Config),
    NewProfileConfig = emqx_utils_maps:deep_put(
        [transport_options, pool_size], ProfileBaseConfig, 16
    ),

    ?assertMatch(
        {error, _},
        emqx_s3:start_profile(<<"profile">>, NewProfileConfig)
    ).

t_orphaned_pools_cleanup(_Config) ->
    ProfileId = profile_id(),
    Pid = gproc:where({n, l, emqx_s3_profile_conf:id(ProfileId)}),

    %% We kill conf and wait for it to restart
    %% and create a new pool
    ?assertWaitEvent(
        exit(Pid, kill),
        #{?snk_kind := "s3_start_http_pool", profile_id := ProfileId},
        1000
    ),

    %% We should still have only one pool
    ?assertEqual(
        1,
        length(emqx_s3_profile_http_pools:all(ProfileId))
    ).

t_orphaned_pools_cleanup_non_graceful(_Config) ->
    ProfileId = profile_id(),
    Pid = gproc:where({n, l, emqx_s3_profile_conf:id(ProfileId)}),

    %% We stop pool, conf server should not fail when attempting to stop it once more
    [PoolName] = emqx_s3_profile_http_pools:all(ProfileId),
    ok = ehttpc_pool:stop_pool(PoolName),

    %% We kill conf and wait for it to restart
    %% and create a new pool
    ?assertWaitEvent(
        exit(Pid, kill),
        #{?snk_kind := "s3_start_http_pool", profile_id := ProfileId},
        1000
    ),

    %% We should still have only one pool
    ?assertEqual(
        1,
        length(emqx_s3_profile_http_pools:all(ProfileId))
    ).

t_checkout_client(Config) ->
    ProfileId = profile_id(),
    Key = emqx_s3_test_helpers:unique_key(),
    Caller = self(),
    Pid = spawn_link(fun() ->
        emqx_s3:with_client(
            ProfileId,
            fun(Client) ->
                receive
                    put_object ->
                        Caller ! {put_object, emqx_s3_client:put_object(Client, Key, <<"data">>)}
                end,
                receive
                    list_objects ->
                        Caller ! {list_objects, emqx_s3_client:list(Client, [])}
                end
            end
        ),
        Caller ! client_released,
        receive
            stop -> ok
        end
    end),

    %% Ask spawned process to put object
    Pid ! put_object,
    receive
        {put_object, ok} -> ok
    after 1000 ->
        ct:fail("put_object fail")
    end,

    %% Now change config for the profile
    ProfileBaseConfig = ?config(profile_config, Config),
    NewProfileConfig0 = ProfileBaseConfig#{bucket => <<"new_bucket">>},
    NewProfileConfig1 = emqx_utils_maps:deep_put(
        [transport_options, pool_size], NewProfileConfig0, 16
    ),
    ok = emqx_s3:update_profile(profile_id(), NewProfileConfig1),

    %% We should have two pools now, because the old one is still in use
    %% by the spawned process
    ?assertEqual(
        2,
        length(emqx_s3_profile_http_pools:all(ProfileId))
    ),

    %% Ask spawned process to list objects
    Pid ! list_objects,
    receive
        {list_objects, Result} ->
            {ok, OkResult} = Result,
            Contents = proplists:get_value(contents, OkResult),
            ?assertEqual(1, length(Contents)),
            ?assertEqual(Key, proplists:get_value(key, hd(Contents)))
    after 1000 ->
        ct:fail("list_objects fail")
    end,

    %% Wait till spawned process releases client
    receive
        client_released -> ok
    after 1000 ->
        ct:fail("client not released")
    end,

    %% We should have only one pool now, because the old one is released
    ?assertEqual(
        1,
        length(emqx_s3_profile_http_pools:all(ProfileId))
    ).

t_unknown_messages(_Config) ->
    Pid = gproc:where({n, l, emqx_s3_profile_conf:id(profile_id())}),

    Pid ! unknown,
    ok = gen_server:cast(Pid, unknown),

    ?assertEqual(
        {error, not_implemented},
        gen_server:call(Pid, unknown)
    ).

%%--------------------------------------------------------------------
%% Test helpers
%%--------------------------------------------------------------------

profile_id() ->
    <<"test">>.
