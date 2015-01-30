%%------------------------------------------------------------------------------
%% Copyright (c) 2012-2015, Feng Lee <feng@emqtt.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------
-module(emqttc).

-author('feng@emqtt.io').
-author('hiroe.orz@gmail.com').

-include("emqttc_packet.hrl").

-import(proplists, [get_value/2, get_value/3]).

%% start application.
-export([start/0]).

%% start one mqtt client
-export([start_link/0, start_link/1, start_link/2]).

%% api
-export([subscribe/2, subscribe/3,
         publish/3, publish/4, 
         unsubscribe/2,
         ping/1,
         disconnect/1]).

-behavior(gen_fsm).

%% gen_fsm callbacks
-export([init/1,
         handle_info/3, 
         handle_event/3, 
         handle_sync_event/4, 
         code_change/4, 
         terminate/3]).

%% fsm state
-export([connecting/2, connecting/3,
         waiting_for_connack/2, waiting_for_connack/3,
         connected/2, connected/3,
         disconnected/2, disconnected/3]).

-type mqttc_opt()   :: {host, inet:ip_address() | binary() | string} 
                     | {port, inet:port_number()}
                     | {client_id, binary()}
                     | {clean_sess, boolean()}
                     | {keep_alive, non_neg_integer()}
                     | {proto_vsn, mqtt_vsn()}
                     | {username, binary()}
                     | {password, binary()}
                     | {will_topic, binary()}
                     | {will_msg, binary()}
                     | {will_qos, mqtt_qos()}
                     | {will_retain, boolean()}
                     | {logger, atom() | {atom(), atom()}}
                     | {reconnector, emqttc_reconnector:reconnector() | false}.

-type mqtt_pubopt() :: {qos, mqtt_qos()} | {retain, boolean()}.


-record(state, {name                :: atom(),
                host = "localhost"  :: inet:ip_address() | string(),
                port = 1883         :: inet:port_number(),
                socket              :: inet:socket(),
                parse_state         :: none | fun(),
                proto_state         :: emqttc_protocol:proto_state(),
                pubsub_map          :: map(),
                ping_reqs = []      :: list(), 
                pending             :: list(),
                keepalive           :: emqttc_keepalive:keepalive(),
                logger              :: gen_logger:logmod(),
                reconnector         :: false | emqttc_reconnector:reconnector()}).

%%--------------------------------------------------------------------
%% @doc Start emqttc application
%%--------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(emqttc).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with default options.
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Client :: pid()} | ignore | {error, any()}. 
start_link() ->
    start_link([]).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with options.
%%--------------------------------------------------------------------
-spec start_link(MqttOpts) -> {ok, Client} | ignore | {error, any()} when 
      MqttOpts  :: [mqttc_opt()],
      Client    :: pid().
start_link(MqttOpts) when is_list(MqttOpts) ->
    gen_fsm:start_link(?MODULE, [undefined, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Start emqttc client with name, options.
%%--------------------------------------------------------------------
-spec start_link(Name, MqttOpts) -> {ok, pid()} | ignore | {error, any()} when
      Name      :: atom(),
      MqttOpts  :: [mqttc_opt()].
start_link(Name, MqttOpts) when is_atom(Name), is_list(MqttOpts) ->
    gen_fsm:start_link({local, Name}, ?MODULE, [Name, MqttOpts], []).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with default qos.
%%--------------------------------------------------------------------
-spec publish(Client, Topic, Payload) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{topic = Topic, payload = Payload}).

%%--------------------------------------------------------------------
%% @doc Publish message to broker with qos or opts.
%%--------------------------------------------------------------------
-spec publish(Client, Topic, Payload, PubOpts) -> ok | {ok, MsgId} when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Payload   :: binary(),
      PubOpts   :: mqtt_qos() | [mqtt_pubopt()],
      MsgId     :: mqtt_packet_id().
publish(Client, Topic, Payload, PubOpts) when is_binary(Topic), is_binary(Payload) ->
    publish(Client, #mqtt_message{qos     = get_value(qos, PubOpts, ?QOS_0),
                                  retain  = get_value(retain, PubOpts, false),
                                  topic   = Topic,
                                  payload = Payload }).

-spec publish(Client, Message) -> ok when
      Client    :: pid() | atom(),
      Message   :: mqtt_message().
publish(Client, Msg) when is_record(Msg, mqtt_message) ->
    gen_fsm:send_event(Client, {publish, Msg}).

%%--------------------------------------------------------------------
%% @doc Subscribe topics or topic.
%%--------------------------------------------------------------------
-spec subscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [{binary(), mqtt_qos()}] | {binary(), mqtt_qos()} | binary().
subscribe(Client, Topic) when is_binary(Topic) ->
    subscribe(Client, [{Topic, ?QOS_0}]);
subscribe(Client, {Topic, QoS}) when is_binary(Topic) ->
    subscribe(Client, [{Topic, QoS}]);
subscribe(Client, [{Topic, Qos} | _] = Topics) when is_binary(Topic), ?IS_QOS(Qos) ->
    gen_fsm:send_event(Client, {subscribe, self(), Topics}).

%%--------------------------------------------------------------------
%% @doc Subscribe topic with qos.
%%--------------------------------------------------------------------
-spec subscribe(Client, Topic, Qos) -> ok when
      Client    :: pid() | atom(),
      Topic     :: binary(),
      Qos       :: mqtt_qos().
subscribe(Client, Topic, Qos) when is_binary(Topic), ?IS_QOS(Qos) ->
    subscribe(Client, [{Topic, Qos}]).

%%--------------------------------------------------------------------
%% @doc Unsubscribe topics
%%--------------------------------------------------------------------
-spec unsubscribe(Client, Topics) -> ok when
      Client    :: pid() | atom(),
      Topics    :: [binary()] | binary().
unsubscribe(Client, Topic) when is_binary(Topic) ->
    unsubscribe(Client, [Topic]);
unsubscribe(Client, [Topic | _] = Topics) when is_binary(Topic) ->
    gen_fsm:send_event(Client, {unsubscribe, Topics}).

%%--------------------------------------------------------------------
%% @doc Send ping to broker.
%%--------------------------------------------------------------------
-spec ping(Client) -> pong when Client :: pid() | atom().
ping(Client) ->
    gen_fsm:sync_send_event(Client, ping).

%%--------------------------------------------------------------------
%% @doc Disconnect from broker.
%%--------------------------------------------------------------------
-spec disconnect(Client) -> ok when Client :: pid() | atom().
disconnect(Client) ->
    gen_fsm:send_event(Client, disconnect).

%%%===================================================================
%%% gen_fms callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}.
%%--------------------------------------------------------------------
init([undefined, MqttOpts]) ->
    init([pid_to_list(self()), MqttOpts]);

init([Name, MqttOpts]) ->

    Logger = gen_logger:new(get_value(logger, MqttOpts, {stdout, debug})),

    case get_value(client_id, MqttOpts) of
        undefined -> Logger:warning("ClientId is NULL!");
        _ -> ok
    end,

    ProtoState = emqttc_protocol:init([{logger, Logger} | MqttOpts]),
    
    State = init(MqttOpts, #state{ name         = Name,
                                   host         = "localhost",
                                   port         = 1883,
                                   proto_state  = ProtoState,
                                   logger       = Logger,
                                   reconnector  = false }),
     {ok, connecting, State, 0}.

init([], State) ->
    State;
init([{host, Host} | Opts], State) ->
    init(Opts, State#state{host = Host});
init([{port, Port} | Opts], State) ->
    init(Opts, State#state{port = Port});
init([{logger, Cfg} | Opts], State) ->
    init(Opts, State#state{logger = gen_logger:new(Cfg)});
init([{reconnect, ReconnOpt} | Opts], State) ->
    init(Opts, State#state{reconnector = init_reconnector(ReconnOpt)});
init([_Opt | Opts], State) ->
    init(Opts, State).

init_reconnector(false) ->
    false;
init_reconnector(Interval) when is_integer(Interval) ->
    emqttc_reconnector:new(Interval);
init_reconnector({Interval, MaxRetries}) when is_integer(Interval) -> 
    emqttc_reconnector:new(Interval, MaxRetries).

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(timeout, State) ->
    connect(State);

connecting(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected event: ~p", [Name, Event]),
    {next_state, connecting, pending(Event, connecting, State)}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sync message Handler for state that connecting to MQTT broker.
%%--------------------------------------------------------------------
connecting(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s] Unexpected event: ~p", [Name, Event]),
    {reply, {error, connecting}, connecting, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that waiting_for_connack from MQTT broker.
%%--------------------------------------------------------------------
waiting_for_connack(Event, State) ->
    {next_state, waiting_for_connack, pending(Event, waiting_for_connack, State)}.

waiting_for_connack(Event, _From, State = #state{name = Name, logger = Logger }) ->
    Logger:warning("[Client ~s] Unexpected event: ~p", [Name, Event]),
    {next_state, waiting_for_connack, pending(Event, waiting_for_connack, State)}.

%%--------------------------------------------------------------------
%% @private
%% @doc Message Handler for state that connected to MQTT broker.
%%--------------------------------------------------------------------
connected({publish, Msg}, State=#state{proto_state = ProtoState}) ->
    emqttc_protocol:publish(Msg, ProtoState),
    {next_state, connected, State};

connected({subscribe, From, Topics}, State = #state{pubsub_map = PubSubMap,
                                                    proto_state = ProtoState }) ->
    emqttc_protocol:subscribe(Topics, ProtoState),
    PubSubMap1 =
    lists:foldl(
        fun(Topic, Map) ->
            case maps:find(Topic, Map) of 
                {ok, Subs} ->
                    case lists:keyfind(From, 1, Subs) of
                        {From, _MonRef} -> 
                            Map;
                        false -> 
                            MonRef = erlang:monitor(process, From),
                            maps:put(Topic, [{From, MonRef}| Subs], Map)
                    end; 
                error ->
                    MonRef = erlang:monitor(process, From),
                    maps:put(Topic, [{From, MonRef}], Map)
            end
        end, PubSubMap, Topics),
    {next_state, connected, State#state{ pubsub_map = PubSubMap1 }};

connected({unsubscribe, From, Topics}, State=#state{pubsub_map  = PubSubMap, 
                                                    proto_state = ProtoState}) ->
    emqttc_protocol:unsubscribe(Topics, ProtoState),
    PubSubMap1 = 
    lists:foldl(
        fun(Topic, Map) ->
            case maps:find(Topic, Map) of
                {ok, Subs} ->
                    case lists:keyfind(From, 1, Subs) of
                        {From, MonRef} ->
                            erlang:demonitor(process, MonRef),
                            maps:put(Topic, lists:keydelete(From, 1, Subs), Map);
                        false ->
                            Map
                    end;
                error ->
                    Map
            end
        end, PubSubMap, Topics),
    {next_state, connected, State#state{pubsub_map = PubSubMap1}};

connected(disconnect, State=#state{socket = Socket, proto_state = ProtoState}) ->
    emqttc_protocol:disconnect(ProtoState),
    emqttc_socket:close(Socket),
    {stop, normal, State#state{socket = undefined}};

connected(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s/CONNECTED] Unexpected Event: ~p", [Name, Event]),
    {next_state, connected, State}.

connected(ping, From, State = #state{ping_reqs = PingReqs, proto_state = ProtoState}) ->
    emqttc_protocol:ping(ProtoState),
    PingReqs1 =
    case lists:keyfind(From, 1, PingReqs) of
        {From, _MonRef} ->
            PingReqs;
        false ->
            [{From, erlang:monitor(process, From)} | PingReqs]
    end,
    {next_state, connected, State#state{ping_reqs = PingReqs1}};

connected(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s/CONNECTED] Unexpected Event: ~p", [Name, Event]),
    {reply, {error, unsupport}, connected, State}.

disconnected(Event, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s/CONNECTED] Unexpected Event: ~p", [Name, Event]),
    {next_state, disconnected, State}.

disconnected(Event, _From, State = #state{name = Name, logger = Logger}) ->
    Logger:error("Client ~s/CONNECTED] Unexpected event ~p", [Name, Event]),
    {reply, {error, disonnected}, disconnected, State}.
    
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%%--------------------------------------------------------------------

%% connack message from broker(without remaining length).
handle_info({tcp, Socket, Data}, StateName, State = #state{name = Name, 
                                                           socket = Socket, 
                                                           logger = Logger}) ->
    emqttc_socket:setopts(Socket, [{active, once}]),
    Logger:debug("[Client ~s/~s] RECV: ~p", [Name, StateName, Data]),
    process_received_bytes(Data, StateName, State);

handle_info({tcp, error, Reason}, StateName, State = #state{name = Name, logger = Logger}) ->
    %TODO: Reconnect??
    Logger:error("[Client ~s/~s] TCP Error: ~p", [Name, StateName, Reason]),
    {next_state, StateName, State};

handle_info({tcp_closed, Socket}, StateName, State = #state{name = Name, socket = Socket, reconnector = Reconnector, logger = Logger}) ->
    Logger:error("[Client ~s/~s] TCP Closed.", [Name, StateName]),
    case Reconnector of
        false -> {stop, {shutdown, tcp_closed}, State};
        _ -> 
            case emqttc_reconnector:execute(Reconnector, {timeout, reconnect}) of
                {stop, _} -> 
                    {stop, {shutdown, tcp_closed}, State};
                {ok, Reconnector1} -> 
                    {next_state, disconnected, State#state{socket = undefined,
                                                           reconnector = Reconnector1}}
            end
    end;

handle_info({reconnect, timeout}, disconnected, State = #state{name = Name, logger = Logger}) ->
    Logger:info("[Client ~s] start to reconnecting.", [Name]),
    connect(State);

handle_info({keepalive, start, TimeoutSec}, connected, State = #state{name = Name, socket = Socket, logger = Logger}) ->
    Logger:info("[Client ~s] Start KeepAlive with ~p seconds", [Name, TimeoutSec]),
    KeepAlive = emqtt_keepalive:new(Socket, TimeoutSec, {keepalive, timeout}),
    {next_state, connected, State#state{keepalive = KeepAlive}};

handle_info({keepalive, timeout}, connected, State = #state{name = Name, proto_state = ProtoState, keepalive = KeepAlive, logger = Logger}) ->
    case emqtt_keepalive:resume(KeepAlive) of
    timeout ->
        Logger:info("[Client ~s] Keepalive Timeout!", [Name]),
        emqttc_protocol:ping(ProtoState),
        {next_state, connected, State};
    {resumed, KeepAlive1} ->
        Logger:info("[Client ~s] Keepalive Resumed.", [Name]),
        {next_state, connected, State#state{keepalive = KeepAlive1}}
    end;

handle_info(Info, StateName, State = #state{name = Name, logger = Logger}) ->
    Logger:error("[Client ~s/] BadInfo: ~p", [Name, Info]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%%--------------------------------------------------------------------
handle_sync_event(status, _From, StateName, State) ->
    Statistics = [{N, get(N)} || N <- [inserted]],
    {reply, {StateName, Statistics}, StateName, State};

handle_sync_event(stop, _From, _StateName, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, _StateName, _State = #state{proto_state = ProtoState}) ->
    emqttc_protocol:shutdown(Reason, ProtoState),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
connect(State = #state{name = Name, 
                       host = Host, port = Port, 
                       proto_state = ProtoState,
                       socket = undefined, 
                       logger = Logger,
                       reconnector = Reconnector}) ->
    Logger:info("[Client ~s]: connecting to ~p:~p", [Name, Host, Port]),
    case emqttc_socket:connect(Host, Port) of
        {ok, Socket} ->
            ProtoState1 = emqttc_protocol:set_socket(ProtoState, Socket),
            emqttc_protocol:connect(ProtoState1),
            Logger:info("[Client ~p] connected with ~p:~p", [Name, Host, Port]),
            {next_state, waiting_for_connack, State#state{socket = Socket,
                                                          parse_state = emqttc_parser:init(), 
                                                          proto_state = ProtoState1} };
        {error, Reason} ->
            Logger:info("[Client ~p] connection failure: ~p", [Name, Reason]),
            case Reconnector of
                false -> 
                    {stop, {error, Reason}, State};
                _ -> 
                    case emqttc_reconnector:execute(Reconnector, {reconnect, timeout}) of
                        {ok, Reconnector1} -> {next_state, disconnected, State#state{reconnector = Reconnector1}};
                        {stop, Error} -> {stop, {error, Error}, State}
                    end
            end
    end.

stop(Reason, State ) ->
    {stop, Reason, State}.

pending(Event = {subscribe, _From, _Topics}, _StateName, State = #state{pending = Pending}) ->
    State#state{pending = [Event | Pending]};

pending(Event = {publish, _Msg}, _StateName, State = #state{pending = Pending}) ->
    State#state{pending = [Event | Pending]};

pending(Event, StateName, State = #state{name = Name, logger = Logger}) ->
    Logger:warning("[Client ~s ~s] Unexpected event: ~p", [Name, StateName, Event]),
    State.

process_received_bytes(<<>>, EventState, State) ->
    {next_state, EventState, State};

process_received_bytes(Bytes, StateName, State = #state{name        = Name, 
                                                        parse_state = ParseState, 
                                                        logger      = Logger }) ->
    case emqttc_parser:parse(Bytes, ParseState) of
    {more, ParseState1} ->
        {next_state, StateName, State#state{parse_state = ParseState1}};
    {ok, Packet, Rest} ->
        case handle_received_packet(Packet, StateName, State) of
            {ok, NewStateName, NewState} ->
                process_received_bytes(Rest, NewStateName, 
                                       NewState#state{parse_state = emqttc_parser:init()});
            {error, Error, NewState} ->
                stop({shutdown, Error}, NewState)
        end;
    {error, Error} ->
        Logger:error("[Client ~s/~s] MQTT Framing error ~p", [Name, StateName, Error]),
        stop({shutdown, Error}, State)
    end.

handle_received_packet(?PACKET_TYPE(Packet, ?CONNACK), waiting_for_connack, 
                       State = #state{name = Name, pending = Pending, proto_state = ProtoState, logger = Logger}) ->
    #mqtt_packet_connack{return_code  = ReturnCode} = Packet#mqtt_packet.variable,
    Logger:info("[Client ~s] RECV CONNACK: ~p", [Name, ReturnCode]),
    {ok, ProtoState1} = emqttc_protocol:handle_connack(ReturnCode, ProtoState),
    if 
        ReturnCode =:= ?CONNACK_ACCEPT ->
            [gen_fsm:send_event(self(), Event) || Event <- Pending],
            {ok, connected, State#state{proto_state = ProtoState1}};
        true ->
            {error, connack_error(ReturnCode), State}
    end;

handle_received_packet(?PACKET_TYPE(Packet, ?PINGRESP), connected, 
                       State = #state{name = Name, ping_reqs = PingReqs, logger = Logger}) ->
    Logger:info("[Client ~s] RECV: PINGRESP", [Name]),
    lists:foreach(fun({From, MonRef}) -> 
            erlang:demonitor(process, MonRef),
            gen_fsm:reply(From, pong)       
        end, PingReqs),
    {ok, connected, State#state{ping_reqs = []}};

handle_received_packet(?PACKET_TYPE(Packet, ?PUBLISH), connected, 
                       State = #state{name = Name, ping_reqs = PingReqs, logger = Logger}) ->

    Logger:info("[~p] RECV: ~p", [Name, emqttc_pPacket]),

(Type, Packet, connected, State = #state{name = Name, logger = Logger, proto_state = ProtoState}) ->
    Logger:info("[~p] RECV: ~p", [Name, Packet]),
    case emqttc_protocol:handle_packet(Type, Packet, ProtoState) of
        {ok, NewProtoState} ->
            {ok, NewProtoState};
        {error, Error} ->
            Logger:error("[~p] MQTT protocol error ~p", [Name, Error]),
            stop({shutdown, Error}, State);
        {error, Error, ProtoState1} ->
            stop({shutdown, Error}, State#state{proto_state = ProtoState1});
        {stop, Reason, ProtoState1} ->
            stop(Reason, State#state{proto_state = ProtoState1})
    end.


