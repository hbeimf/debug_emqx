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

-module(emqx_secret_tests).

-include_lib("eunit/include/eunit.hrl").

wrap_unwrap_test() ->
    ?assertEqual(
        42,
        emqx_secret:unwrap(emqx_secret:wrap(42))
    ).

unwrap_immediate_test() ->
    ?assertEqual(
        42,
        emqx_secret:unwrap(42)
    ).

wrap_unwrap_load_test_() ->
    Secret = <<"foobaz">>,
    {
        setup,
        fun() -> write_temp_file(Secret) end,
        fun(Filename) -> file:delete(Filename) end,
        fun(Filename) ->
            ?_assertEqual(
                Secret,
                emqx_secret:unwrap(emqx_secret:wrap_load({file, Filename}))
            )
        end
    }.

wrap_load_term_test() ->
    ?assertEqual(
        {file, "no/such/file/i/swear"},
        emqx_secret:term(emqx_secret:wrap_load({file, "no/such/file/i/swear"}))
    ).

wrap_unwrap_missing_file_test() ->
    ?assertThrow(
        #{msg := failed_to_read_secret_file, reason := "No such file or directory"},
        emqx_secret:unwrap(emqx_secret:wrap_load({file, "no/such/file/i/swear"}))
    ).

wrap_term_test() ->
    ?assertEqual(
        42,
        emqx_secret:term(emqx_secret:wrap(42))
    ).

external_fun_term_error_test() ->
    Term = {foo, bar},
    ?assertError(
        badarg,
        emqx_secret:term(fun() -> Term end)
    ).

write_temp_file(Bytes) ->
    Ts = erlang:system_time(millisecond),
    Filename = filename:join("/tmp", ?MODULE_STRING ++ integer_to_list(-Ts)),
    ok = file:write_file(Filename, Bytes),
    Filename.
