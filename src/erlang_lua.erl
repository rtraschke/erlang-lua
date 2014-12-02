-module(erlang_lua).

-behaviour(gen_server).

-export([start_link/1, start_link/2, lua/2, call/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

% logging macros
-define(LOG_FATAL(FUN, REPORT),
	error_logger:error_report(format_log(
		[{level, "FATAL"}, {module, ?MODULE}, {file, ?FILE}, {line, ?LINE}, {function, FUN}], REPORT))).
-define(LOG_ERROR(FUN, REPORT),
	error_logger:error_report(format_log(
		[{level, "ERROR"}, {module, ?MODULE}, {file, ?FILE}, {line, ?LINE}, {function, FUN}], REPORT))).
-define(LOG_WARNING(FUN, REPORT),
	error_logger:warning_report(format_log(
		[{level, "WARNING"}, {module, ?MODULE}, {file, ?FILE}, {line, ?LINE}, {function, FUN}], REPORT))).
-define(LOG_INFO(FUN, REPORT),
	error_logger:info_report(format_log(
		[{level, "INFO"}, {module, ?MODULE}, {file, ?FILE}, {line, ?LINE}, {function, FUN}], REPORT))).
-define(LOG_DEBUG(FUN, REPORT),
	error_logger:info_report(format_log(
		[{level, "DEBUG"}, {module, ?MODULE}, {file, ?FILE}, {line, ?LINE}, {function, FUN}], REPORT))).


start_link(Id) ->
	start_link(Id, 0).

start_link(Id, Tracelevel) when Tracelevel >= 0 ->
	gen_server:start_link({local, Id}, ?MODULE, [Id, Tracelevel], []).

lua(Id, Code) when is_list(Code) ->
	gen_server:call(Id, {exec, list_to_binary(Code)}, infinity);
lua(Id, Code) when is_binary(Code) ->
	gen_server:call(Id, {exec, Code}, infinity).

call(Id, Fun, Args) when is_atom(Fun), is_list(Args) ->
	gen_server:call(Id, {call, Fun, Args}, infinity).

stop(Id) ->
	gen_server:call(Id, stop, infinity).


% Here follow the gen_server callback functions.

-record(state, {
	id,
	port,
	mbox, % The Lua Node gets messages sent to this Mbox.
	from, % The client where results need to be sent back to.
	infotext = [], % Stores up any info text coming from the Lua Node.
	infoline = [] % Builds up complete lines of info text.
}).
-define(MAX_INFOTEXT_LINES, 1000).

init([Id, Tracelevel]) ->
	process_flag(trap_exit, true),
	{Clean_Id, Host, Lua_Node_Name} = mk_node_name(Id),
	Path = case code:priv_dir(erlang_lua) of
		{error, bad_name} -> os:getenv("PATH");
		Folder -> Folder
	end,
	{Result, Cmd_or_Error} = case os:find_executable("lua_enode", Path) of
		false ->
			{stop, lua_not_found};
		Lua ->
			{ok, mk_cmdline(Lua, Clean_Id, Host, Tracelevel)}
	end,
	case {Result, Cmd_or_Error} of
		{stop, Error} ->
			{stop, Error};
		{ok, Cmd} ->
			?LOG_INFO(init, [{lua_node, Clean_Id}, {start, Cmd}]),
			Port = open_port({spawn, Cmd}, [stream, {line, 100}, stderr_to_stdout, exit_status]),
			wait_for_startup(#state{id=Id, port=Port, mbox={lua, Lua_Node_Name}})
	end.

mk_cmdline(Lua, Id, Host, Tracelevel) ->
	lists:flatten([
		Lua,
		quote(Id),
		quote(Host),
		quote(atom_to_list(node())),
		quote(atom_to_list(erlang:get_cookie())),
		quote(integer_to_list(Tracelevel))
	]).

% Wait for the READY signal before confirming that our Lua Server is
% up and running.  Just echo out some of the chit chat coming from the
% Node program.
wait_for_startup(#state{port=Port} = State) ->
	receive
		{Port, {exit_status, N}} ->
			?LOG_ERROR(wait_for_startup, [{startup_failure, {exit_status, N}}, State]),
			{stop, {exit_status, N}};
		{Port, {data, {eol, "READY"}}} ->
			?LOG_INFO(wait_for_startup, [ready, State]),
			{ok, State};
		{Port, {data, {eol, "."}}} ->
			wait_for_startup(State);
		{Port, {data, {eol, S}}} ->
			?LOG_DEBUG(wait_for_startup, [{startup, S}, State]),
			wait_for_startup(State)
	end.


handle_call({exec, Code}, From, #state{mbox=Mbox, from=undefined} = State) ->
	?LOG_DEBUG(handle_call, [{exec, Code}, State]),
	Mbox ! {exec, self(), Code, []},
	{noreply, State#state{from=From}};
handle_call({call, Fun, Args}, From, #state{mbox=Mbox, from=undefined} = State) ->
	?LOG_DEBUG(handle_call, [{call, Fun, Args}, State]),
	Mbox ! {call, self(), Fun, Args},
	{noreply, State#state{from=From}};
handle_call(stop, _From, #state{from=undefined} = State) ->
	?LOG_DEBUG(handle_call, [stop, State]),
	{stop, normal, ok, State};
handle_call(Request, _From, #state{from=Id} = State) when Id =/= undefined ->
	?LOG_DEBUG(handle_call, [{busy, Request}, State]),
	{reply, {error, busy}, State}.

handle_cast(_Request, State) ->
	{noreply, State}.


% We're going to receive a number of different kinds of messages from
% the Lua Node program:
% termination messages, stdout messages, and proper execution replies.

% The first three messages mean that the Lua program is no longer running.
% So we stop.
% The first is normal termination, the other two are abnormal.
handle_info({Port, {exit_status, 0}}, #state{port=Port} = State) ->
	?LOG_INFO(handle_info, [{'EXIT', {exit_status, 0}}, State]),
	{stop, normal, State#state{port=undefined, mbox=undefined}};
handle_info({Port, {exit_status, N}}, #state{port=Port} = State) ->
	?LOG_ERROR(handle_info, [{'EXIT', {exit_status, N}}, State]),
	{stop, {port_status, N}, State#state{port=undefined, mbox=undefined}};
handle_info({'EXIT', Port, Reason}, #state{port=Port} = State) ->
	?LOG_ERROR(handle_info, [{'EXIT', Reason}, State]),
	{stop, {port_exit, Reason}, State#state{port=undefined, mbox=undefined}};

% Stdout data messages come from the standard output of the Lua Node program.
% Unfinished output lines are tagged with noeol.
handle_info({Port, {data, {noeol, S}}}, #state{port=Port} = State) ->
	{noreply, noeol_port_data(S, State)};
% Finished lines are tagged with eol.
% The convention in the Lua Node program is to send a solitary "." line to signal
% that this particular bit of output is complete; we flush in this case.
handle_info({Port, {data, {eol, "."}}}, #state{port=Port, infoline = []} = State) ->
	{noreply, flush_port_data(State)};
% Otherwise, we handle the complete line.
handle_info({Port, {data, {eol, S}}}, #state{port=Port} = State) ->
	{noreply, eol_port_data(S, State)};

% Finally, we can get proper returns coming from the Lua Node:
% error message or return value message.
handle_info({error, _Reason} = Error, #state{from=From} = State) when From =/= undefined ->
	gen_server:reply(From, Error),
	{noreply, State#state{from=undefined}};
handle_info({lua, _Result} = Reply, #state{from=From} = State) when From =/= undefined ->
	gen_server:reply(From, Reply),
	{noreply, State#state{from=undefined}};

% Anything else is weird and should, at least, be logged.
handle_info(Info, State) ->
	?LOG_DEBUG(handle_info, [{info, Info}, State]),
	{noreply, State}.


% A termination request when the Lua Node is already down,
% we simply acknowledge.
terminate(Reason, #state{mbox=undefined} = State) ->
	?LOG_DEBUG(terminate, [{terminate, Reason}, State]),
	ok;
% Any termination while the Lua Node is up and running,
% we try and stop the Lua Node.
% This could be an explicit call to stop() (Reason=normal),
% or a supervisor shutting us down (Reason=shutdown),
% or an out of band termination (Reason=?)
terminate(Reason, #state{mbox=Mbox} = State) ->
	?LOG_INFO(terminate, [{terminate, Reason}, State]),
	Mbox ! {stop, self(), [], []},
	wait_for_exit(State).

wait_for_exit(#state{port=Port} = State) ->
	receive
		{Port, {exit_status, 0}} ->
			?LOG_INFO(wait_for_exit, [{'EXIT', {exit_status, 0}}, State]),
			ok;
		{Port, {exit_status, N}} ->
			?LOG_ERROR(wait_for_exit, [{'EXIT', {exit_status, N}}, State]),
			ok;
		{'EXIT', Port, Reason} ->
			?LOG_ERROR(wait_for_exit, [{'EXIT', Reason}, State]),
			ok;
		{Port, {data, {eol, "."}}} ->
			wait_for_exit(flush_port_data(State));
		{Port, {data, {noeol, S}}} ->
			wait_for_exit(noeol_port_data(S, State));
		{Port, {data, {eol, S}}} ->
			wait_for_exit(eol_port_data(S, State));
		Other ->
			?LOG_DEBUG(wait_for_exit, [{info, Other}, State]),
			wait_for_exit(State)
	end.

code_change(_Old, State, _Extra) ->
	{ok, State}.


% Helper functions.

% Messages from the Lua Node program are accumulated and finally
% logged as info messages.

% We accumulate the output line by line; potentially having to assemble
% each line from pieces. Everything is accumulated through list cons'ing.
% Thus results have to be reversed before use.
% We don't accumulate forever, flushing regularly.

% We accumulate the line pieces.
noeol_port_data(S, #state{infotext = Text, infoline = []} = State)
		when length(Text) >= ?MAX_INFOTEXT_LINES ->
	noeol_port_data(S, flush_port_data(State));
noeol_port_data(S, #state{infoline = Line} = State) ->
	State#state{infoline = [S | Line]}.

% We accumulate the completed line into the text.
eol_port_data(S, #state{infotext = Text, infoline = []} = State)
		when length(Text) >= ?MAX_INFOTEXT_LINES ->
	eol_port_data(S, flush_port_data(State));
eol_port_data(S, #state{infotext = Text, infoline = Line} = State) ->
	Full_Line = lists:flatten(lists:reverse([S | Line])),
	State#state{infotext = [Full_Line | Text], infoline = []}.

% We write any info report of the completed text.
% If there's any half accumulated line, then process that first.
flush_port_data(#state{infotext = [], infoline = []} = State) ->
	State;
flush_port_data(#state{infoline = [_ | _]} = State) ->
	flush_port_data(eol_port_data("", State));
flush_port_data(#state{infotext = Text} = State) ->
	case lists:reverse(Text) of
		["FATAL: " ++ S | Rest] -> 
			?LOG_FATAL(flush_port_data, [{stdout, [S | Rest]}, State]);
		["ERROR: " ++ S | Rest] -> 
			?LOG_ERROR(flush_port_data, [{stdout, [S | Rest]}, State]);
		["WARN: " ++ S | Rest] -> 
			?LOG_WARNING(flush_port_data, [{stdout, [S | Rest]}, State]);
		["INFO: " ++ S | Rest] -> 
			?LOG_INFO(flush_port_data, [{stdout, [S | Rest]}, State]);
		["DEBUG: " ++ S | Rest] -> 
			?LOG_DEBUG(flush_port_data, [{stdout, [S | Rest]}, State]);
		Other ->
			?LOG_INFO(flush_port_data, [{stdout, Other}, State])
	end,
	State#state{infotext = [], infoline = []}.


mk_node_name(Id) ->
	This_Id = re:replace(atom_to_list(Id), "[^_0-9a-zA-Z]+", "_", [global, {return, list}]),
	This_Host = string:sub_word(atom_to_list(node()), 2, $@),
	{This_Id, This_Host, list_to_atom(lists:flatten([This_Id, "@", This_Host]))}.

quote(S) ->
	case ostype() of
		win32 -> [" \"", S, "\""];
		unix -> [" '", S, "'"]
	end.

ostype() ->
	case os:type() of
		{Type, _} -> Type;
		Type -> Type
	end.


% Friendly log message formatting
format_log([{level, Level}, {module, _Module}, {file, _File}, {line, _Line}, {function, _Function}], Report) ->
	Date = format_date(os:timestamp()),
	lists:flatten([
		io_lib:format("~s ~s ~ts~n", [Date, Level, format_log(Report)])
	]).

format_date({_Megasecs, _Secs, Microsecs} = Now) ->
	{{Y, Mo, D}, {H, Mi, S}} = calendar:now_to_universal_time(Now),
	io_lib:format("~w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0wZ",
		[Y, Mo, D, H, Mi, S, Microsecs div 1000]).

format_log([{lua_node, Clean_Id}, {start, Cmd}]) ->
	io_lib:format("ELua '~s' starting using command:~n~s", [Clean_Id, Cmd]);
format_log([{startup_failure, {exit_status, N}}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' failed to start; exit status code ~B.", [Id, N]);
format_log([ready, #state{id=Id}]) ->
	io_lib:format("ELua '~s' is ready to accept Lua code.", [Id]);
format_log([{startup, S}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' startup message:~n~s", [Id, S]);
format_log([{exec, Code}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' executing:~n~s", [Id, Code]);
format_log([{call, Fun, Args}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' calling '~s' with argument list:~n~p", [Id, Fun, Args]);
format_log([stop, #state{id=Id}]) ->
	io_lib:format("ELua '~s' is being asked to stop.", [Id]);
format_log([{busy, Request}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' is busy; ignoring request:~n~p", [Id, Request]);
format_log([{'EXIT', {exit_status, 0}}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' stopped normally.", [Id]);
format_log([{'EXIT', {exit_status, N}}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' stopped abnormally; exit status code ~B.", [Id, N]);
format_log([{'EXIT', Reason}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' stopped abnormally; exit reason:~n~p.", [Id, Reason]);
format_log([{info, Info}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' received an out of band message:~n~p", [Id, Info]);
format_log([{terminate, Reason}, #state{id=Id}]) ->
	io_lib:format("ELua '~s' terminating: ~p", [Id, Reason]);
format_log([{stdout, Text}, #state{id=Id}]) ->
	io_lib:format("ELua '~s':~n~s", [Id, string:join(Text, "\n")]).

