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
-module(epmd_api).

-behaviour(gen_server).

%% API
-export([reg/1, reg/2,
         reg_linkto/2, reg_linkto/3,
         lookup/1, lookup/2,
         service_name/2]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { socket }).

-define(EPMD_ALIVE2_REQ,       $x).
-define(EPMD_PORT_PLEASE2_REQ, $z).
-define(EPMD_ALIVE2_RESP,      $y).
-define(EPMD_PORT2_RESP,       $w).

-define(ERLANG_EPMD_PORT,   4369).
-define(ERL_EPMD_DIST_HIGH, 5).
-define(ERL_EPMD_DIST_LOW,  5).

-include("epmd_api.hrl").


%% ====================================================================
%% API
%% ====================================================================

%%
%% Register a #empd_node record with the local EPMD.
%%
%% @see reg/2
%%
reg(Node) ->
    reg_internal(Node, "localhost", self()).


%%
%% Register a #empd_node record with the EPMD running on Host.
%%
%% Note that this creates a process linked to the calling process for the
%% requested name. When the process exits, the requested name will be
%% de-registered with EPMD.
%%
%% Also note that if a fully qualified node name is provided in the #epmd_node
%% record, it will override the Host parameter.
%%
reg(Node, Host) ->
    reg_internal(Node, Host, self()).


%%
%% Register a #epmd_node record with the local EPMD and link to the provided PID
%% instead of the calling process.
%%
reg_linkto(Node, Pid) ->
    reg_internal(Node, "localhost", Pid).


%%
%% Register a #epmd_node record with the EPMD on Host and link to the provided PID
%% instead of the calling process.
%%
reg_linkto(Node, Host, Pid) ->
    reg_internal(Node, Host, Pid).
    

%%
%% Retrieve the #epmd_node information for the specified name. If the name contains an '@',
%% it is assumed that this is a fully-qualified node name and the lookup will happen
%% against the specified host. Otherwise, the local EPMD is used.
%%
lookup(Name) ->
    case parse_fq_node(to_binstr(Name)) of
        {Node, <<>>} ->
            lookup(Node, "localhost");
        {Node, Host} ->
            lookup(Node, binary_to_list(Host))
    end.

%%
%% Retrieve the #epmd_node record for the specified name from the EPMD running on Host.
%%
lookup(Name, Host) ->
    case do_connect(Host, 2500) of
        {ok, Socket} ->
            do_lookup_node(Socket, Name, 2500); 
        {error, Reason} ->
            {error, Reason}
    end.

%%
%% Parse the provided node name and concatenate the service on the end.
%%
service_name(Name, Service) ->
    case parse_fq_node(to_binstr(Name)) of
        {Node, <<>>} ->
            <<Node/binary, ".", (to_binstr(Service))/binary>>;
        {Node, Host} ->
            <<Node/binary, ".", (to_binstr(Service))/binary, "@", Host/binary>>
    end.
    


%% ====================================================================
%% gen_server callbacks
%% ====================================================================

init([Pid]) ->
    link(Pid),
    {ok, #state{}}.

handle_call({register, Node, Host}, _From, State) ->
    %% Open the connection -- if this fails, the process exits
    case do_connect(Host, 1000) of
        {ok, Socket} ->
            case do_register_node(Socket, Node, 1000) of
                ok ->
                    {reply, {ok, self()}, #state { socket = Socket }};
                {error, {register_failed, _Result}} ->
                    {stop, {error, register_failed}, {error, register_failed}, State};
                {error, Reason} ->
                    {stop, {error, Reason}, {error, Reason}, State}
            end;
        {error, Reason} ->
            {stop, {error, Reason}, {error, Reason}, State}
    end.
    

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp_data, _Socket, _Data}, State) ->
    %% Drop any unexpected data from socket -- likely old/timedout response
    {noreply, State};

handle_info({tcp_error, _Socket, Reason}, State) ->
    {stop, {error, Reason}, State};

handle_info({tcp_closed, _Socket}, State) ->
    {stop, {error, epmd_closed}, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




%% ====================================================================
%% Internal functions
%% ====================================================================

reg_internal(Node, RequestedHost, LinkToPid) ->
    {N2, FinalHost} = normalize_rec(Node, RequestedHost),
    {ok, Pid} = gen_server:start(?MODULE, [LinkToPid], []),
    gen_server:call(Pid, {register, N2, FinalHost}).
    
    
%%
%% Cleanup the epmd_node record and make sure all fields are properly initialized.
%%
normalize_rec(Node, RequestedHost) ->
    %% First, see if the requested name is actually a fully-qualfied node name; if it
    %% is, parse it out and use that hostname in lieu of the requested host
    case parse_fq_node(to_binstr(Node#epmd_node.name)) of
        {Name, <<>>} ->
            FinalHost = RequestedHost;
        {Name, Host} ->
            FinalHost = binary_to_list(Host)
    end,
    
    N2 = Node#epmd_node { name = Name,
                          high_vsn = if_undefined(Node#epmd_node.high_vsn, epmd_dist_high()),
                          low_vsn  = if_undefined(Node#epmd_node.low_vsn, epmd_dist_low()),
                          extra    = <<>> },
    {N2, FinalHost}.



%%
%% Parse a node name into {Node, Host} components (where both are binaries)
%%
parse_fq_node(BinStr) ->
    split_bin_str(BinStr, $@, <<>>).

%%
%% Split a binary string at the first occurrence of the Delimiter
%%
split_bin_str(<<>>, _Delimiter, Acc) ->
    {Acc, <<>>};
split_bin_str(<<Delimiter:8, Rest/binary>>, Delimiter, Acc) ->
    {Acc, Rest};
split_bin_str(<<Other:8, Rest/binary>>, Delimiter, Acc) ->
    split_bin_str(Rest, Delimiter, <<Acc/binary, Other:8>>).

%%
%% Convert an atom, string or binary to a binary.
%%
to_binstr(Atom) when is_atom(Atom) -> list_to_binary(atom_to_list(Atom));
to_binstr(Str) when is_list(Str)   -> list_to_binary(Str);
to_binstr(Bin) when is_binary(Bin) -> Bin.

%%
%% If the first argument is undefined, return the second.
%%
if_undefined(undefined, Other) -> Other;
if_undefined(Value, _Other)    -> Value.

    
do_connect(Host, Timeout) ->
    gen_tcp:connect(Host, get_epmd_port(),
                    [binary, {active, true}], Timeout).
        

do_register_node(Socket, Node, Timeout) ->
    case Node#epmd_node.hidden of
        true ->
            NodeType = 72; % Hidden node
        false ->
            NodeType = 77  % Normal node
    end,
    Request = <<?EPMD_ALIVE2_REQ:8,
                (Node#epmd_node.port):16,
                NodeType:8,
                (Node#epmd_node.protocol):8,
                (Node#epmd_node.high_vsn):16,
                (Node#epmd_node.low_vsn):16,
                (size(Node#epmd_node.name)):16, (Node#epmd_node.name)/binary,
                (size(Node#epmd_node.extra)):16, (Node#epmd_node.extra)/binary >>,
    ok = gen_tcp:send(Socket, [<<(size(Request)):16>>, Request]),
    wait_for_register_response(<<>>, Timeout).


wait_for_register_response(Data, Timeout) ->
    receive
        {tcp, _Socket, Payload} ->
            %% Append payload to existing data and check it
            case <<Data/binary, Payload/binary>> of
                <<?EPMD_ALIVE2_RESP:8, 0:8, _Creation:16>> ->
                    ok;
                <<?EPMD_ALIVE2_RESP:8, Result:8, _Creation:16>> ->
                    {error, {register_failed, Result}};
                Other ->
                    wait_for_register_response(Other, Timeout)
            end;
        {tcp_closed, _Socket} ->
            {error, epmd_closed};
        {tcp_error, _Socket, Reason} ->
            {error, Reason}
    after Timeout ->
            {error, epmd_not_responding}
    end.
    
            
do_lookup_node(Socket, Name, Timeout) ->
    Request = <<(size(Name)+1):16, ?EPMD_PORT_PLEASE2_REQ:8, Name/binary>>,
    gen_tcp:send(Socket, Request),
    wait_for_lookup_response(<<>>, Socket, Timeout).
    
wait_for_lookup_response(Data, Socket, Timeout) ->
    receive
        {tcp, Socket, Payload} ->
            case <<Data/binary, Payload/binary>> of
                <<?EPMD_PORT2_RESP:8, 0:8, Port:16, NodeType:8,
                  Protocol:8, HighVsn:16, LowVsn:16,
                  Nlen:16, Name:Nlen/binary, _Rest/binary>> ->
                    gen_tcp:close(Socket),
                    case NodeType of
                        72 -> Hidden = true;
                        77 -> Hidden = false
                    end,
                    {ok, #epmd_node { name   = Name,
                                      port   = Port,
                                      hidden = Hidden,
                                      protocol = Protocol,
                                      high_vsn = HighVsn,
                                      low_vsn  = LowVsn }};
                <<?EPMD_PORT2_RESP:8, _Result:8>> ->
                    gen_tcp:close(Socket),
                    not_found;
                Other ->
                    wait_for_lookup_response(Other, Socket, Timeout)
            end;
        {tcp_closed, Socket} ->
            {error, epmd_closed};
        {tcp_error, Socket, Reason} ->
            {error, Reason}
    after Timeout ->
            gen_tcp:close(Socket),
            {error, epmd_not_responding}
    end.

               

%% ====================================================================
%% Functions from erl_epmd.erl
%% ====================================================================

get_epmd_port() ->
    case init:get_argument(epmd_port) of
	{ok, [[PortStr|_]|_]} when is_list(PortStr) ->
	    list_to_integer(PortStr);
	error ->
	    ?ERLANG_EPMD_PORT
    end.

epmd_dist_high() ->
    case os:getenv("ERL_EPMD_DIST_HIGH") of
	false ->
	   ?ERL_EPMD_DIST_HIGH; 
	Version ->
	    case (catch list_to_integer(Version)) of
		N when is_integer(N), N < ?ERL_EPMD_DIST_HIGH ->
		    N;
		_ ->
		   ?ERL_EPMD_DIST_HIGH
	    end
    end.

epmd_dist_low() ->
    case os:getenv("ERL_EPMD_DIST_LOW") of
	false ->
	   ?ERL_EPMD_DIST_LOW; 
	Version ->
	    case (catch list_to_integer(Version)) of
		N when is_integer(N), N > ?ERL_EPMD_DIST_LOW ->
		    N;
		_ ->
		   ?ERL_EPMD_DIST_LOW
	    end
    end.
		    




                                                      
