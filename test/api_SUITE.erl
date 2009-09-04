%% -------------------------------------------------------------------
%%
%% Erlang Port Mapper (EPMD) API Library
%%
%% Copyright (c) 2009 Dave Smith <dizzyd@dizzyd.com>
%%
%% Portions/logic of this library were taken from erl_epmd.erl which is part of
%% the Erlang distribution and licensed under the EPL.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%%
%% -------------------------------------------------------------------
-module(api_SUITE).

-compile(export_all).

-include_lib("ct.hrl").
-include_lib("epmd_api/include/epmd_api.hrl").

all() ->
    [register_should_work,
     register_proc_death_should_unregister,
     lookup_should_accept_fq_node,
     service_name_should_append,
     fq_name_should_override_host].

init_per_suite(Config) ->
    %% Make sure epmd is running
    os:cmd("epmd -daemon"),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    ok.

register_should_work(_Config) ->
    {ok, _Pid} = epmd_api:reg(#epmd_node { name = foobar, port = 1234 }),
    {ok, #epmd_node{ port = 1234 }} = epmd_api:lookup(foobar).


register_proc_death_should_unregister(_Config) ->
    {ok, Pid} = epmd_api:reg(#epmd_node { name = regtest2, port = 1235 }),
    {ok, #epmd_node{ port = 1235 }} = epmd_api:lookup(regtest2),

    unlink_and_kill(Pid),

    not_found = epmd_api:lookup(regtest2).


lookup_should_accept_fq_node(_Config) ->
    {ok, Pid} = epmd_api:reg(#epmd_node { name = regtest3, port = 1236 }),
    {ok, #epmd_node{ port = 1236 }} = epmd_api:lookup('regtest3@localhost').


service_name_should_append(_Config) ->
    <<"node.service@localhost">> = epmd_api:service_name('node@localhost', 'service'),
    <<"node.service2@foobar">> = epmd_api:service_name("node@foobar", service2),
    <<"node.service3@barbaz">> = epmd_api:service_name(<<"node@barbaz">>, <<"service3">>).

fq_name_should_override_host(_Config) ->
    {ok, Pid} = epmd_api:reg(#epmd_node { name = 'regtest4@localhost', port = 1237 },
                             "example.com"),
    {ok, #epmd_node{ port = 1237 }} = epmd_api:lookup(regtest4).
    



%% ====================================================================
%% Internal functions
%% ====================================================================

unlink_and_kill(Pid) ->
    unlink(Pid),
    Mref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Mref, _, _, _} ->
            ok
    end.
    


