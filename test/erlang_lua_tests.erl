-module(erlang_lua_tests).

-include_lib("eunit/include/eunit.hrl").

%-compile([export_all]).

%test(Opts) ->
%	eunit:test(?MODULE, Opts).

all_test_() ->
	net_kernel:start(['test@127.0.0.1', longnames]),
	[	{"Erlang-Lua Node",
			foreach, setup(), teardown(), all_test_cases()
		}
	].

setup() ->
	fun () ->
		{ok, Pid} = erlang_lua:start_link(eunit_testing),
		Pid
	end.

teardown() ->
	fun (Pid) ->
		case whereis(eunit_testing) of
			Pid -> ok = erlang_lua:stop(eunit_testing);
			undefined -> ok
		end
	end.

all_test_cases() ->
	[ 	fun startstop_test_cases/1
	, 	fun string_or_binary_arg_test_cases/1
	, 	fun return_type_test_cases/1
	,	fun call_test_cases/1
	,	fun erl_rpc_test_cases/1
	].

startstop_test_cases(Pid) ->
	{ "Start and Stop",
	[	?_assert( is_pid(Pid) )
	,	?_assertEqual( Pid, whereis(eunit_testing) )
	,	?_assertEqual( ok, erlang_lua:stop(eunit_testing) )
	,	?_assertEqual( undefined, whereis(eunit_testing) )
	]
	}.

string_or_binary_arg_test_cases(_Pid) ->
	{ "Lua code as string or binary",
	[	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, "") )
	,	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, " ") )
	,	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, "TESTING = 42") )
	,	?_assertEqual( {lua, [42]}, erlang_lua:lua(eunit_testing, "return TESTING") )
	,	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, <<"">>) )
	,	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, <<" ">>) )
	,	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, <<"TESTING = 42">>) )
	,	?_assertEqual( {lua, [42]}, erlang_lua:lua(eunit_testing, <<"return TESTING">>) )
	]
	}.

return_type_test_cases(_Pid) ->
	{ "Return type conversions",
	[	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, <<"return">>) )
	,	{ "Nil", 
		[	?_assertEqual( {lua, [nil]}, erlang_lua:lua(eunit_testing, <<"return nil">>) )
		,	?_assertEqual( {lua, [nil]}, erlang_lua:lua(eunit_testing, <<"return does_not_exist">>) )
		] }
	,	{ "Integer", 
		[	?_assertEqual( {lua, [0]}, erlang_lua:lua(eunit_testing, <<"return 0">>) )
		,	?_assertEqual( {lua, [1]}, erlang_lua:lua(eunit_testing, <<"return 1">>) )
		,	?_assertEqual( {lua, [-1]}, erlang_lua:lua(eunit_testing, <<"return -1">>) )
		,	?_assertEqual( {lua, [1234]}, erlang_lua:lua(eunit_testing, <<"return 1234">>) )
		,	?_assertEqual( {lua, [-1234]}, erlang_lua:lua(eunit_testing, <<"return -1234">>) )
		,	?_assertEqual( {lua, [1234567890]}, erlang_lua:lua(eunit_testing, <<"return 1234567890">>) )
		,	?_assertEqual( {lua, [-1234567890]}, erlang_lua:lua(eunit_testing, <<"return -1234567890">>) )
		,	?_assertEqual( {lua, [trunc(math:pow(2, 31)-1)]},
					erlang_lua:lua(eunit_testing, <<"return math.pow(2, 31)-1">>) )
		,	?_assertEqual( {lua, [trunc(-math:pow(2, 31))]},
					erlang_lua:lua(eunit_testing, <<"return -math.pow(2, 31)">>) )
		,	?_assertNotEqual( {lua, [12345678901234567890]},
					erlang_lua:lua(eunit_testing, <<"return 12345678901234567890">>) )
		,	?_assertNotEqual( {lua, [-12345678901234567890]},
					erlang_lua:lua(eunit_testing, <<"return -12345678901234567890">>) )
		] }
	,	{ "Float", 
		[	?_assertEqual( {lua, [0]}, erlang_lua:lua(eunit_testing, <<"return 0.0">>) )
		,	?_assertEqual( {lua, [0.1]}, erlang_lua:lua(eunit_testing, <<"return 0.1">>) )
		,	?_assertEqual( {lua, [-0.1]}, erlang_lua:lua(eunit_testing, <<"return -0.1">>) )
		,	?_assertEqual( {lua, [12.34]}, erlang_lua:lua(eunit_testing, <<"return 12.34">>) )
		,	?_assertEqual( {lua, [-12.34]}, erlang_lua:lua(eunit_testing, <<"return -12.34">>) )
		,	?_assertEqual( {lua, [1.234E19]}, erlang_lua:lua(eunit_testing, <<"return 1.234E19">>) )
		,	?_assertEqual( {lua, [-1.234E19]}, erlang_lua:lua(eunit_testing, <<"return -1.234E19">>) )
		,	?_assertEqual( {lua, [1.234E-19]}, erlang_lua:lua(eunit_testing, <<"return 1.234E-19">>) )
		,	?_assertEqual( {lua, [-1.234E-19]}, erlang_lua:lua(eunit_testing, <<"return -1.234E-19">>) )
		,	?_assertEqual( {lua, [trunc(math:pow(2, 31))]},
						erlang_lua:lua(eunit_testing, <<"return math.pow(2, 31)">>) )
		,	?_assertEqual( {lua, [trunc(-(math:pow(2, 31)+1))]},
						erlang_lua:lua(eunit_testing, <<"return -(math.pow(2, 31)+1)">>) )
		] }
	,	{ "String", 
		[	?_assertEqual( {lua, [<<"">>]}, erlang_lua:lua(eunit_testing, <<"return [[]] ">>) )
		,	?_assertEqual( {lua, [<<"abc">>]}, erlang_lua:lua(eunit_testing, <<"return 'abc' ">>) )
		,	?_assertEqual( {lua, [binary:copy(<<"abc">>, 1000)]},
					erlang_lua:lua(eunit_testing, <<"return string.rep('abc', 1000)">>) )
		,	?_assertEqual( {lua, [binary:copy(<<"abc">>, 1000000)]},
					erlang_lua:lua(eunit_testing, <<"return string.rep('abc', 1000000)">>) )
		,	?_assertEqual( {lua, [binary:copy(<<"0123456789">>, 10000000)]},
					erlang_lua:lua(eunit_testing, <<"return string.rep('0123456789', 10000000)">>) )
		] }
	,	{ "Boolean", 
		[	?_assertEqual( {lua, [true]}, erlang_lua:lua(eunit_testing, <<"return true">>) )
		,	?_assertEqual( {lua, [true]}, erlang_lua:lua(eunit_testing, <<"return 1 < 2">>) )
		,	?_assertEqual( {lua, [false]}, erlang_lua:lua(eunit_testing, <<"return false">>) )
		,	?_assertEqual( {lua, [false]}, erlang_lua:lua(eunit_testing, <<"return 1 > 2">>) )
		] }
	,	{ "Table", 
		[	?_assertEqual(
				{lua, [ [1234, 12.34, <<"abc">>, false] ]},
				erlang_lua:lua(eunit_testing, <<"return {1234, 12.34, 'abc', 1 > 2}">>)
			)
		,	?_test( begin
				{lua, [ PL ]} = erlang_lua:lua(eunit_testing,
						<<"return {int=1234, float=12.34, string='abc', bool=1 > 2}">>),
				1234 = proplists:get_value(int, PL),
				12.34 = proplists:get_value(float, PL),
				<<"abc">> = proplists:get_value(string, PL),
				false = proplists:get_value(bool, PL)
			end )
		,	?_test( begin
				{lua, [ [1, 2, 3 | PL] ]} = erlang_lua:lua(eunit_testing,
						<<"return {1, 2, 3, int=1234, float=12.34, string='abc', bool=1 > 2}">>),
				1234 = proplists:get_value(int, PL),
				12.34 = proplists:get_value(float, PL),
				<<"abc">> = proplists:get_value(string, PL),
				false = proplists:get_value(bool, PL)
			end )
		,	?_test( begin
				{lua, [ [1, 2, 3, 4, 5 | PL] ]} = erlang_lua:lua(eunit_testing,
						<<"return {1, int=1234, 2, float=12.34, 3, string='abc', 4, bool=1 > 2, 5}">>),
				1234 = proplists:get_value(int, PL),
				12.34 = proplists:get_value(float, PL),
				<<"abc">> = proplists:get_value(string, PL),
				false = proplists:get_value(bool, PL)
			end )
		] }
	,	{ "Erlang Atom", 
		[	?_assertEqual( {lua, [foobar]}, erlang_lua:lua(eunit_testing, <<"return erl_atom'foobar' ">>) )
		,	?_assertEqual( {lua, ['']}, erlang_lua:lua(eunit_testing, <<"return erl_atom'' ">>) )
		,	?_assertEqual( {lua, ['123 456']}, erlang_lua:lua(eunit_testing, <<"return erl_atom'123 456' ">>) )
		] }
	,	{ "Erlang String", 
		[	?_assertEqual( {lua, ["foobar"]}, erlang_lua:lua(eunit_testing, <<"return erl_string'foobar' ">>) )
		,	?_assertEqual( {lua, [""]}, erlang_lua:lua(eunit_testing, <<"return erl_string'' ">>) )
		,	?_assertEqual( {lua, ["123 456"]}, erlang_lua:lua(eunit_testing, <<"return erl_string'123 456' ">>) )
		] }
	,	{ "Erlang Tuple", 
		[	?_assertEqual( {lua, [{65, 66, 67}]}, erlang_lua:lua(eunit_testing, <<"return erl_tuple{65, 66, 67}">>) )
		,	?_assertEqual( {lua, [{65, foobar, "123 456"}]},
				erlang_lua:lua(eunit_testing, <<"return erl_tuple{65, erl_atom'foobar', erl_string'123 456'}">>) )
		] }
	,	{ "Multi Result", 
		[	?_assertEqual( {lua, [65, 66, 67]}, erlang_lua:lua(eunit_testing, <<"return 65, 66, 67">>) )
		,	?_assertEqual(
				{lua, [1234, 12.34, <<"abc">>, false]},
				erlang_lua:lua(eunit_testing, <<"return 1234, 12.34, 'abc', 1 > 2">>)
			)
		,	?_assertEqual(
				{lua, [ [1234, 12.34, <<"abc">>, false], 1234, 12.34, <<"abc">>, false ]},
				erlang_lua:lua(eunit_testing,
						<<"return {1234, 12.34, 'abc', 1 > 2}, 1234, 12.34, 'abc', 1 > 2">>)
			)
		] }
	,	{ "Unsupported", 
		[	?_assertEqual( {lua, [function]},
					erlang_lua:lua(eunit_testing, <<"return function () end">>) )
		,	?_assertEqual( {lua, [thread]},
					erlang_lua:lua(eunit_testing, <<"return coroutine.create(function () end)">>) )
		% ,	?_assertEqual( {lua, [userdata]}, erlang_lua:lua(eunit_testing, <<"require 'lpeg' return lpeg.R()">>) )
		] }
	]
	}.

call_test_cases(_Pid) ->
	{ "Call Lua functions",
	[	?_assertEqual( {lua, ok}, erlang_lua:lua(eunit_testing, <<"dofile '../test/some_functions.lua' ">>) )
	,	?_assertEqual( {lua, [<<"42">>]}, erlang_lua:call(eunit_testing, stringify, [42]) )
	,	?_assertMatch( {error, _}, erlang_lua:call(eunit_testing, upper, ["foobar"]) )
	,	?_assertEqual(
			{lua, [<<"FOOBAR">>]},
			erlang_lua:call(eunit_testing, upper, [<<"foobar">>])
		)
	,	?_assertEqual(
			{lua, [<<"foobar">>, 42]},
			erlang_lua:call(eunit_testing, unpack, [ [<<"foobar">>, 42] ])
		)
	,	?_assertEqual(
			{lua, [<<"foobar">>, 42]},
			erlang_lua:call(eunit_testing, unpack, [ {<<"foobar">>, 42} ])
		)
	,	?_assertEqual(
			{lua, [3, 5]},
			erlang_lua:call(eunit_testing, find, [<<"foobar">>, <<"oba">>])
		)
	,	?_assertEqual(
			{lua, [3, 5, <<"o">>, <<"a">>]},
			erlang_lua:call(eunit_testing, find, [<<"foobar">>, <<"(o)b(a)">>])
		)
	,	?_assertEqual(
			{lua, [ <<"{[1] = 42,}">> ]},
			erlang_lua:call(eunit_testing, stringify_flat, [ [42] ])
		)
	,	?_assertEqual(
			{lua, [ <<"{[1] = 1234,[2] = 12.34,[3] = \"abc\",[4] = false,}">> ]},
			erlang_lua:call(eunit_testing, stringify_flat, [ [1234, 12.34, <<"abc">>, false] ])
		)
	,	?_assertEqual(
			{lua, [ <<"{[1] = {[1] = 1234,[2] = 12.34,[3] = \"abc\",[4] = false,},"
					"[2] = 1234,[3] = 12.34,[4] = \"abc\",[5] = false,}">> ]},
			erlang_lua:call(eunit_testing, stringify_flat, [
					[[1234, 12.34, <<"abc">>, false], 1234, 12.34, <<"abc">>, false]
			])
		)
	,	?_assertEqual(
			{lua, [ <<"{foobar = 42,}">> ]},
			erlang_lua:call(eunit_testing, stringify_flat, [ [{foobar, 42}] ])
		)
	,	?_test( begin
			{lua, [ PL ]} = erlang_lua:call(eunit_testing, identity, [
					[{int, 1234}, {float, 12.34}, {string, <<"abc">>}, {bool, 1 > 2}]
			]),
			1234 = proplists:get_value(int, PL),
			12.34 = proplists:get_value(float, PL),
			<<"abc">> = proplists:get_value(string, PL),
			false = proplists:get_value(bool, PL)
		end )
	,	?_test( begin
			{lua, [ [1, 2, 3, 4 | PL] ]} = erlang_lua:call(eunit_testing, identity, [
					[1, {int, 1234}, 2, {float, 12.34}, 3, {string, <<"abc">>}, 4, {bool, 1 > 2}]
			]),
			1234 = proplists:get_value(int, PL),
			12.34 = proplists:get_value(float, PL),
			<<"abc">> = proplists:get_value(string, PL),
			false = proplists:get_value(bool, PL)
		end )
	,	?_test( begin
			{lua, ok} = erlang_lua:lua(eunit_testing,
					"function xxx(a, b, c) return a, b, c end"),
			{lua, [65, 66, 67]} = erlang_lua:call(eunit_testing, xxx, [65, 66, 67]) 
		end )
	]
	}.

erl_rpc_test_cases(_Pid) ->
	{ "Callback into Erlang from Lua using RPC",
	[	?_assertEqual( {lua, [true]}, erlang_lua:lua(eunit_testing, <<"return erl_rpc()">>) )
	,	?_assertEqual(
			{lua, [tuple_to_list(date())]},
			erlang_lua:lua(eunit_testing, <<"return erl_rpc('date')">>)
		)
	,	?_assertEqual(
			{lua, [atom_to_binary(node(), utf8)]},
			erlang_lua:lua(eunit_testing, <<"return erl_rpc('node')">>)
		)
	,	?_assertEqual(
			{lua, [tuple_to_list(date())]},
			erlang_lua:lua(eunit_testing, <<"return erl_rpc('erlang', 'date')">>)
		)
	,	?_assertEqual(
			{lua, [atom_to_binary(node(), utf8)]},
			erlang_lua:lua(eunit_testing, <<"return erl_rpc('erlang', 'node')">>)
		)
	,	?_assertEqual(
			{lua, [atom_to_binary(node(), utf8)]},
			erlang_lua:call(eunit_testing, erl_rpc, [erlang, node])
		)
	,	?_assertEqual(
			{lua, [ [2,5,8,11,14] ]},
			erlang_lua:lua(eunit_testing, <<"return erl_rpc('lists', 'seq', 2, 15, 3)">>)
		)
	,	?_assertEqual(
			{lua, [<<"axios">>]},
			erlang_lua:lua(eunit_testing,
					<<"return erl_rpc('base64', 'decode', erl_rpc('base64', 'encode', 'axios'))">>)
		)
	,	?_test( begin
			S = <<"axios">>,
			{lua, [ R ]} = erlang_lua:call(eunit_testing, erl_rpc, [base64, encode, S]),
			{lua, [ S ]} = erlang_lua:call(eunit_testing, erl_rpc, [base64, decode, R])
		end )
	]
	}.

%error_test_cases(_Pid) ->
%	[	{"Syntax error", ?_assertEqual( {error, "stdin:1: unexpected symbol near '1'"}, <<"foo = {} 1">> )}
%	].

