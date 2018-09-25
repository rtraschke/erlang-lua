/*

Lua -> Erlang

	nil -> 'nil' Atom

	true -> 'true' Atom
	false -> 'false' Atom

	erl_atom"string" -> 'string' Atom

	integer number -> Integer Number
	floating point number -> Float Number

	"string" -> Binary

	erl_string"string" -> "string" String

	erl_tuple{ V1, V2, V3, ..., Vn } -> { V1, V2, V3, ..., Vn }

	{ V1, V2, V3, ..., Vn } -> [ V1, V2, V3, ..., Vn ]

	{ K1=V1, K2=V2, K3=V3, ..., Kn=Vn } -> [ {K1, V1}, {K2, V2}, {K3, V3}, ..., {Kn, Vn} ]
		/ Order of pairs not guaranteed,
		/ If type(K) == "string" and #K < 256 then Erlang K is Atom

	{ V1, V2, ..., Vn, Kn+1=Vn+1, Kn+2=Vn+2, ..., Kn+k=Vn+k  }
			-> [ V1, V2, ..., Vn, {Kn+1, Vn+1}, {Kn+1, Vn+2}, ..., {Kn+1, Vn+n} ]
		/ Order of {K, V} pairs not guaranteed
		/ If type(K) == "string" and #K < 256 then Erlang K is Atom

	Unusable types:
		function -> 'function' Atom
		userdata -> 'userdata' Atom
		thread -> 'thread' Atom
		lightuserdata -> 'lightuserdata' Atom


Erlang -> Lua

	'nil' Atom -> nil
	'true' Atom -> true
	'false' Atom -> false

	Atom -> string

	Integer Number -> number
	Float Number -> number

	Binary -> string
	/ Note: Regular Erlang Strings are Lists: "abc" -> { 97, 98, 99 }

	{ V1, V2, V3, ..., Vn } -> { V1, V2, V3, ..., Vn }
	[ V1, V2, V3, ..., Vn ] -> { V1, V2, V3, ..., Vn }

	[ {K1, V1}, {K2, V2}, {K3, V3}, ..., {Kn, Vn} ] -> { K1=V1, K2=V2, K3=V3, ..., Kn=Vn }
		/ If all Erlang K are Atoms

	[ V1, {K2, V2}, V3, {K4, V4}, V5, ..., Vn, {Kn+1, Vn+1}, ... ] -> { V1, V3, V4, ..., Vn, K2=V2, K4=V4, ..., Kn+1=Vn+1 }
		/ If Erlang K is Atom
		/ Note: All elements that are not a 2-tuple with the first element an Atom, become array elements in Lua
		/      Only the ordering of non 2-tuples is preserved! 

	Unusable types:
		Reference, Fun, Port, Pid -> nil

*/

#ifdef WINDOWS
#	include <winsock2.h>
#	include <shlwapi.h>
#else
#	include <sys/types.h>
#	include <sys/socket.h>
#	include <netdb.h>
#	include <netinet/in.h>
#endif

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#ifdef WINDOWS
#	include <io.h>
#endif
#include <fcntl.h>

#include "ei.h"
extern int ei_tracelevel;
extern void erl_init(void *hp,long heap_size);

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#if LUA_VERSION_NUM==501
#	define lua_objlen lua_rawlen
#endif

#define lua_objlen(L,i)         lua_rawlen(L, (i))


/* WARNING: GLOBAL VARIABLE: EI_LUA_STATE */
struct {
	lua_State *L;
	char *erlang_node;

	int fd;
	ei_cnode ec;
	ei_x_buff x_in;
	ei_x_buff x_out;
	ei_x_buff x_rpc_in;
	ei_x_buff x_rpc_out;
} EI_LUA_STATE;

static int handle_msg(erlang_pid *pid);
static void main_message_loop();
static int start_lua();
static void stop_lua();
static void execute_code(lua_State *L, ei_x_buff *x_out, char *code);
static void execute_call(lua_State *L, ei_x_buff *x_in, ei_x_buff *x_out, char *fun, int arity, unsigned char *args_str);
static int erlang_to_lua(lua_State *L, ei_x_buff *x_buff, int in_list);
static void lua_to_erlang(lua_State *L, ei_x_buff *x_out, int i);

static void
print(char *fmt, ...)
{
	va_list args;

	va_start(args, fmt);
	vprintf(fmt, args);
	printf("\n.\n");
	fflush(stdout);
	va_end(args);
}

int
main(int argc, char *argv[])
{
	char *lua_node;
	char *lua_host;
	char *cookie;
	struct hostent *host;
	struct in_addr *addr;
	char *fullnodeid;

	if (argc != 6) {
		print("Invalid arguments.");
		exit(1);
	}
	lua_node = argv[1];
	lua_host = argv[2];
	EI_LUA_STATE.erlang_node = strdup(argv[3]);
	cookie = argv[4];
	ei_tracelevel = atoi(argv[5]);

#ifdef WINDOWS
	/* Make sure our messages aren't <CR>-mangled */
	_setmode(_fileno(stdout), O_BINARY);
	_setmode(_fileno(stderr), O_BINARY);
#endif
	/* Attempt to turn off buffering on stdout/err. */
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	erl_init(NULL, 0);

	ei_x_new(&EI_LUA_STATE.x_in);
	ei_x_new(&EI_LUA_STATE.x_out);
	ei_x_new(&EI_LUA_STATE.x_rpc_in);
	ei_x_new(&EI_LUA_STATE.x_rpc_out);

#ifdef WINDOWS
	{	/* Yuck! */
		WSADATA wsaData;
		if (WSAStartup(MAKEWORD(2, 0), &wsaData) != 0) {
			print("Cannot initialise WSA.");
			exit(2);
		}
	}
#endif

	if ((host = gethostbyname(lua_host)) == NULL) {
		print("Cannot retrieve host information for %s.", lua_host);
		exit(3);
	}
	fullnodeid = (char *) malloc(strlen(lua_node) + 1 + strlen(lua_host) + 1);
	sprintf(fullnodeid, "%s@%s", lua_node, lua_host);
	addr = (struct in_addr *) host->h_addr;

	if (ei_connect_xinit(&EI_LUA_STATE.ec, lua_host, lua_node, fullnodeid, addr, cookie, 0) < 0) {
		print("EI initialisation failed: %d (%s)", erl_errno, strerror(erl_errno));
		exit(4);
	}
	print("Lua Erlang Node '%s' starting.", ei_thisnodename(&EI_LUA_STATE.ec));
	if ((EI_LUA_STATE.fd = ei_connect(&EI_LUA_STATE.ec, EI_LUA_STATE.erlang_node)) < 0) {
		print("Cannot connect to parent node '%s': %d (%s)",
				EI_LUA_STATE.erlang_node, erl_errno, strerror(erl_errno));
		exit(5);
	}
	if (! start_lua())
		exit(6);

	print("Lua Erlang Node started.");
	printf("READY\n"); fflush(stdout);

	main_message_loop();

	stop_lua();
	print("INFO: Lua Erlang Node stopped.");
	return 0;
}

static void
reconnect()
{
	print("Lua Erlang Node '%s' reconnecting.", ei_thisnodename(&EI_LUA_STATE.ec));
	if ((EI_LUA_STATE.fd = ei_connect(&EI_LUA_STATE.ec, EI_LUA_STATE.erlang_node)) < 0) {
		print("FATAL: Cannot reconnect to parent node '%s': %d (%s)",
				EI_LUA_STATE.erlang_node, erl_errno, strerror(erl_errno));
		exit(7);
	}
	print("INFO: Lua Erlang Node reconnected.");
}

static void
main_message_loop()
{
	erlang_msg msg;

	int running = 1;
	ei_x_buff *x_in = &EI_LUA_STATE.x_in;
	ei_x_buff *x_out = &EI_LUA_STATE.x_out;
	ei_x_buff *x_rpc_in = &EI_LUA_STATE.x_rpc_in;
	ei_x_buff *x_rpc_out = &EI_LUA_STATE.x_rpc_out;

	while (running) {
		x_in->index = 0;
		switch (ei_xreceive_msg(EI_LUA_STATE.fd, &msg, x_in)) {
		case ERL_ERROR:
		default:
			print("DEBUG: Lua Erlang Node error in receive: %d (%s)", erl_errno, strerror(erl_errno));
			reconnect();
			break;
		case ERL_TICK:
			if (ei_tracelevel > 2) print("DEBUG: TICK");
			break;
		case ERL_MSG:
			switch (msg.msgtype) {
			case ERL_LINK:
				print("DEBUG: Lua Erlang Node linked.");
				break;
			case ERL_UNLINK:
			case ERL_EXIT:
				print("DEBUG: Lua Erlang Node unlinked; terminating.");
				running = 0;
				break;
			case ERL_SEND:
			case ERL_REG_SEND:
				{
					erlang_pid pid = {{0}};
					x_in->index = 0;
					running = handle_msg(&pid);
					if (running == -1) {
						/* Ignore messages without a return pid! */
						running = 1;
					} else {
						x_rpc_in->index = x_rpc_out->index = 0;
						ei_x_encode_empty_list(x_rpc_in); /* empty param list for erlang:is_alive() */
						if (ei_rpc(&EI_LUA_STATE.ec, EI_LUA_STATE.fd,
								"erlang", "is_alive",
								x_rpc_in->buff, x_rpc_in->index,
								x_rpc_out) < 0) {
							print("DEBUG: Lua Erlang Node error in 'is alive?' rpc to '%s'.", pid.node);
							reconnect();
						}
						if (x_out->index > 0 && ei_send(EI_LUA_STATE.fd, &pid,
								x_out->buff, x_out->index) < 0) {
							print("FATAL: Lua Erlang Node error in send to '%s'.", pid.node);
							exit(8);
						}
					}
				}
				break;
			}
			break;
		}
	}
}

static void
set_error_msg(ei_x_buff *x_out, const char *reason)
{
	x_out->index = 0;
	ei_x_encode_version(x_out);
	ei_x_encode_tuple_header(x_out, 2);
	ei_x_encode_atom(x_out, "error");
	ei_x_encode_string(x_out, reason);
}

static int
handle_msg(erlang_pid *pid)
{
	/* Incoming message is one of
		{ stop, Caller_Pid, [], [] }
		{ exec, Caller_Pid, Code, [] }
		{ call, Caller_Pid, Function_Name, [Arg, ...] = Args }
	   with
		stop - the atom 'stop'
		exec - the atom 'exec'
		call - the atom 'call'
		Caller_Pid - the Pid of the Erlang process that sent the message
		Code - the Lua code as a binary to 'exec' (ignored on 'stop')
		Function_Name - function name as an atom to 'call' (ignored on 'stop')
		Args - list of arguments to pass when first atom is 'call' (ignored on 'exec' and 'stop')
	*/

	ei_x_buff *x_in = &EI_LUA_STATE.x_in;
	ei_x_buff *x_out = &EI_LUA_STATE.x_out;

	int version;
	int arity;
	int type;
	int len;
	char lua_atom[MAXATOMLEN+1] = {0};
	char *code, *args_str;

	if (ei_decode_version(x_in->buff, &x_in->index, &version) < 0) {
		print("WARNING: Ignoring malformed message (bad version: %d).", version);
		return -1;
	}
	if (ei_decode_tuple_header(x_in->buff, &x_in->index, &arity) < 0) {
		print("WARNING: Ignoring malformed message (not tuple).");
		return -1;
	}
	if (arity != 4) {
		print("WARNING: Ignoring malformed message (not 4-arity tuple).");
		return -1;
	}
	if (ei_decode_atom(x_in->buff, &x_in->index, lua_atom) < 0) {
		print("WARNING: Ignoring malformed message (first tuple element not atom).");
		return -1;
	}
	if (ei_decode_pid(x_in->buff, &x_in->index, pid) < 0) {
		print("WARNING: Ignoring malformed message (second tuple element not pid).");
		return -1;
	}

	if (strcmp(lua_atom, "stop") == 0) {
		print("DEBUG: Lua Erlang Node stopping normally.");
		x_out->index = 0;
		return 0;
	}

	if (strcmp(lua_atom, "exec") == 0) {
		ei_get_type(x_in->buff, &x_in->index, &type, &len);
		code = (char *) calloc(len+1, sizeof(char));
		if (ei_decode_binary(x_in->buff, &x_in->index, code, NULL) < 0) {
			free(code);
			print("WARNING: Ignoring malformed message (third tuple element for 'exec' not binary).");
			set_error_msg(x_out, "Third tuple element is not a binary.");
			return 1;
		}
	} else if (strcmp(lua_atom, "call") == 0) {
		code = (char *) calloc(MAXATOMLEN+1, sizeof(char));
		if (ei_decode_atom(x_in->buff, &x_in->index, code) < 0) {
			free(code);
			print("WARNING: Ignoring malformed message (third tuple element for 'call' not atom).");
			set_error_msg(x_out, "Third tuple element is not an atom.");
			return -1;
		}
		ei_get_type(x_in->buff, &x_in->index, &type, &len);
		args_str = (char *) calloc(len+1, sizeof(char));
		if (ei_decode_list_header(x_in->buff, &x_in->index, &arity) == 0) {
			free(args_str);
			args_str = NULL;
		} else if (ei_decode_string(x_in->buff, &x_in->index, args_str) == 0) {
			arity = len;
		} else {
			free(args_str);
			free(code);
			print("WARNING: Ignoring malformed message (fourth tuple element for 'call' not list).");
			set_error_msg(x_out, "Fourth tuple element is not a list.");
			return 1;
		}
		if (! lua_checkstack(EI_LUA_STATE.L, arity + 1)) {
			free(args_str);
			free(code);
			print("WARNING: Insufficient Lua Stack space (could not reserve %d slots).", arity + 1);
			set_error_msg(x_out, "Insufficient Lua Stack space.");
			return 1;
		}
	} else {
		print("WARNING: Ignoring malformed message (first tuple element not atom 'stop', 'exec'  or 'call').");
		set_error_msg(x_out, "First tuple element is not the atom 'stop', 'exec' or 'call'.");
		return 1;
	}

	x_out->index = 0;
	ei_x_encode_version(x_out);
	ei_x_encode_tuple_header(x_out, 2);
	ei_x_encode_atom(x_out, "lua");
	if (strcmp(lua_atom, "exec") == 0)
		execute_code(EI_LUA_STATE.L, x_out, code);
	else if (strcmp(lua_atom, "call") == 0)
		execute_call(EI_LUA_STATE.L, x_in, x_out, code, arity, (unsigned char*) args_str);

	free(code);
	return 1;
}


static int lerl_rpc(lua_State *L);

/*
 * A few "boxing" constructors and testers for Erlang types not
 * automatically handled by the C lua_enode program.  The function
 * is_erl_marker() in the lua_enode program uses the
 * _ERL_* markers below to decide if special handling needs to be
 * applied when translating a Lua value to Erlang.
 */

static const char *erl_functions_s = ""
" _ERL_ATOM = {}"
" _ERL_STRING = {}"
" _ERL_TUPLE = {}"
" "
" function erl_atom(s)"
"	if type(s) == 'string' then"
"		return { [_ERL_ATOM] = true, s }"
"	else"
"		error[[bad argument #1 to 'erl_atom' (string expected)]]"
"	end"
" end"
" "
" function erl_string(s)"
"	if type(s) == 'string' then"
"		return { [_ERL_STRING] = true, s }"
"	else"
"		error[[bad argument #1 to 'erl_string' (string expected)]]"
"	end"
" end"
" "
" function erl_tuple(t)"
"	if type(t) == 'table' then"
"		return { [_ERL_TUPLE] = true, table.unpack(t) }"
"	else"
"		error[[bad argument #1 to 'erl_table' (table expected)]]"
"	end"
" end";

static int
start_lua()
{
#ifdef WINDOWS
	/* _putenv("LUA_PATH=!\\lib\\?.lc;!\\lib\\?.lua;!\\lib\\?\\?.lc;!\\lib\\?\\?.lua"); */
	/* _putenv("LUA_CPATH=!\\lib\\?.dll;!\\lib\\?\\?.dll"); */
	OleInitialize(NULL);
#endif
	if (!(EI_LUA_STATE.L = luaL_newstate())) {
		print("FATAL: Lua open failure: %s.", lua_tostring(EI_LUA_STATE.L, -1));
		return 0;
	} else {
		luaL_openlibs(EI_LUA_STATE.L);
		if (luaL_dostring(EI_LUA_STATE.L, erl_functions_s) != 0) {
			print("FATAL: Failed to set up boxing constructors: %s.", lua_tostring(EI_LUA_STATE.L, -1));
			return 0;
		}
		lua_register(EI_LUA_STATE.L, "erl_rpc", lerl_rpc);
		return 1;
	}
}

static void
stop_lua()
{
	lua_close(EI_LUA_STATE.L);
#ifdef WINDOWS
	OleUninitialize();
#endif
}

static void
execute_code(lua_State *L, ei_x_buff *x_out, char *code)
{
	int n, i;

	if (luaL_dostring(L, code) != 0) {
		print("WARNING: %s.", lua_tostring(L, -1));
		set_error_msg(x_out, lua_tostring(L, -1));
		lua_pop(L, 1);
		return;
	}
	n = lua_gettop(L);
	if (n == 0) {
		ei_x_encode_atom(x_out, "ok");
	} else {
		for (i = 1; i <= n; i++) {
			ei_x_encode_list_header(x_out, 1);
			lua_to_erlang(L, x_out, i);
		}
		ei_x_encode_empty_list(x_out);
		lua_pop(L, n);
	}
}

static void
execute_call(lua_State *L, ei_x_buff *x_in, ei_x_buff *x_out, char *fun, int arity, unsigned char *args_str)
{
	int n, i;

	lua_getglobal(L, fun);
	if (args_str) {
		for (i = 0; i < arity; i++) {
			lua_pushinteger(L, args_str[i]);
		}
	} else {
		for (i = 0; i < arity; i++) {
			erlang_to_lua(L, x_in, 0);
		}
	}

	if (lua_pcall(L, arity, LUA_MULTRET, 0) != 0) {
		print("WARNING: %s.", lua_tostring(L, -1));
		set_error_msg(x_out, lua_tostring(L, -1));
		lua_pop(L, 1);
		return;
	}
	n = lua_gettop(L);
	if (n == 0) {
		ei_x_encode_atom(x_out, "ok");
	} else {
		for (i = 1; i <= n; i++) {
			ei_x_encode_list_header(x_out, 1);
			lua_to_erlang(L, x_out, i);
		}
		ei_x_encode_empty_list(x_out);
		lua_pop(L, n);
	}
}


static int
is_erl_marker(lua_State *L, int table, const char *box)
{
	int r;

	lua_getglobal(L, box);
	lua_gettable(L, table);
	r = lua_isboolean(L, -1) && lua_toboolean(L, -1);
	lua_pop(L, 1);
	return r;
}

static void encode_key(lua_State *L, ei_x_buff *x_buff, int i);

static void
lua_to_erlang(lua_State *L, ei_x_buff *x_buff, int i)
{
	switch (lua_type(L, i)) {
	case LUA_TNIL:
		ei_x_encode_atom(x_buff, "nil"); break;
	case LUA_TNUMBER:
		if (lua_tointeger(L, i) == lua_tonumber(L, i)) {
			ei_x_encode_long(x_buff, lua_tointeger(L, i));
		} else {
			ei_x_encode_double(x_buff, lua_tonumber(L, i));
		}
		break;
	case LUA_TBOOLEAN:
		ei_x_encode_boolean(x_buff, lua_toboolean(L, i)); break;
	case LUA_TSTRING: {
		size_t len;
		const char *s = lua_tolstring(L, i, &len);
		ei_x_encode_binary(x_buff, s, len);
		break;
	}
	case LUA_TTABLE: {
		/* table is in the stack at index 'i' */
		if (is_erl_marker(L, i, "_ERL_ATOM")) {
			lua_rawgeti(L, i, 1);
			ei_x_encode_atom(x_buff, lua_tostring(L, -1));
			lua_pop(L, 1);
		} else if (is_erl_marker(L, i, "_ERL_STRING")) {
			lua_rawgeti(L, i, 1);
			ei_x_encode_string(x_buff, lua_tostring(L, -1));
			lua_pop(L, 1);
		} else if (is_erl_marker(L, i, "_ERL_TUPLE")) {
			int k;
			int len = lua_objlen(L, i);
			ei_x_encode_tuple_header(x_buff, len);
			for (k = 1; k <= len; k++) {
				lua_rawgeti(L, i, k);
				lua_to_erlang(L, x_buff, lua_gettop(L));
				lua_pop(L, 1);
			}
		} else {
			int k = 1; /* tester for arrays */
			lua_pushnil(L);  /* first key */
			while (lua_next(L, i) != 0) {
				/* uses 'key' (at one below top of stack) and 'value' (at top of stack) */
				int key = lua_gettop(L)-1;
				int val = lua_gettop(L);
				ei_x_encode_list_header(x_buff, 1);
				if (lua_type(L, key) == LUA_TNUMBER && k == lua_tointeger(L, key)) {
					lua_to_erlang(L, x_buff, val);
					k++;
				} else {
					ei_x_encode_tuple_header(x_buff, 2);
					encode_key(L, x_buff, key);
					lua_to_erlang(L, x_buff, val);
				}
				lua_pop(L, 1);	/* remove 'value'; keep 'key' for next iteration */
			}
			ei_x_encode_empty_list(x_buff);
		}
		break;
	}
	case LUA_TFUNCTION:
		ei_x_encode_atom(x_buff, "function"); break;
	case LUA_TUSERDATA:
		ei_x_encode_atom(x_buff, "userdata"); break;
	case LUA_TTHREAD:
		ei_x_encode_atom(x_buff, "thread"); break;
	case LUA_TLIGHTUSERDATA:
		ei_x_encode_atom(x_buff, "lightuserdata"); break;
	default:
		ei_x_encode_atom(x_buff, "unknown"); break;
	}
}

static void
encode_key(lua_State *L, ei_x_buff *x_buff, int i)
{
	switch (lua_type(L, i)) {
	case LUA_TSTRING: {
		size_t len;
		const char *s = lua_tolstring(L, i, &len);
		if (len <= MAXATOMLEN) {
			ei_x_encode_atom_len(x_buff, s, len);
		} else {
			ei_x_encode_binary(x_buff, s, len);
		}
		break;
	}
	default:
		lua_to_erlang(L, x_buff, i);
	}
}



static int
lerl_rpc(lua_State *L)
{
	ei_x_buff *x_rpc_in = &EI_LUA_STATE.x_rpc_in;
	ei_x_buff *x_rpc_out = &EI_LUA_STATE.x_rpc_out;
	int n = lua_gettop(L);    /* number of arguments */
	const char *mod, *fun;

	x_rpc_in->index = 0;
	if (n < 1) {
		mod = "erlang";
		fun = "is_alive";
	} else if (n < 2) {
		mod = "erlang";
		fun = luaL_checkstring(L, 1);
	} else {
		int i;
		mod = luaL_checkstring(L, 1);
		fun = luaL_checkstring(L, 2);
		for (i = 3; i <= n; i++) {
			ei_x_encode_list_header(x_rpc_in, 1);
			lua_to_erlang(L, x_rpc_in, i);
		}
	}
	ei_x_encode_empty_list(x_rpc_in);
	/* the casts to char* are OK here, because EI actually makes them const again, sigh */
	if (ei_rpc(&EI_LUA_STATE.ec, EI_LUA_STATE.fd, (char *) mod, (char *) fun,
			x_rpc_in->buff, x_rpc_in->index, x_rpc_out) < 0) {
		print("Warning: erl_rpc(%s, %s, ...) call error: %s (%d).",
			mod, fun, strerror(erl_errno), erl_errno);
		lua_pushfstring(L, "erl_rpc(%s, %s, ...) call error: %s (%d).",
			mod, fun, strerror(erl_errno), erl_errno);
		lua_error(L);
	}
	x_rpc_out->index = 0;
	erlang_to_lua(L, x_rpc_out, 0);
	return 1;
}


static int
erlang_to_lua(lua_State *L, ei_x_buff *x_buff, int in_list)
{
	ei_term term;

	if (ei_tracelevel > 0) {
		char *s = (char *) calloc(BUFSIZ, sizeof(char));
		int index = x_buff->index;
		ei_s_print_term(&s, x_buff->buff, &x_buff->index);
		print("Debug: erlang_to_lua:\n%s\n.", s);
		x_buff->index = index;
		free(s);
	}

	if (ei_decode_ei_term(x_buff->buff, &x_buff->index, &term) < 0) {
		print("Warning: erlang_to_lua() value error (unable to decode value).");
		lua_pushstring(L, "erlang_to_lua() value error (unable to decode value).");
		lua_error(L);
	} else {
		if (ei_tracelevel > 0) print("Debug: erlang_to_lua: type %d\n.", term.ei_type);
		switch (term.ei_type) {
		case ERL_ATOM_EXT:
		case ERL_ATOM_UTF8_EXT:
		case ERL_SMALL_ATOM_UTF8_EXT:
			if (strcmp(term.value.atom_name, "nil") == 0)
				lua_pushnil(L);
			else if (strcmp(term.value.atom_name, "true") == 0)
				lua_pushboolean(L, 1);
			else if (strcmp(term.value.atom_name, "false") == 0)
				lua_pushboolean(L, 0);
			else
				lua_pushstring(L, term.value.atom_name);
			break;
		case ERL_SMALL_INTEGER_EXT:
		case ERL_INTEGER_EXT:
			lua_pushnumber(L, term.value.i_val);
			break;
		case ERL_FLOAT_EXT:
		case NEW_FLOAT_EXT:
			lua_pushnumber(L, term.value.d_val);
			break;
		case ERL_STRING_EXT: {
			int i;
			char *s = (char *) calloc(term.size + 1, sizeof(char));
			ei_decode_string(x_buff->buff, &x_buff->index, s);
			lua_createtable(L, term.size, 0);
			for (i = 0; i < term.size; i++) {
				lua_pushinteger(L, s[i]);
				lua_rawseti(L, -2, i+1);
			}
			free(s);
			break;
		}
		case ERL_BINARY_EXT: {
			long len;
			char *b = (char *) calloc(term.size, sizeof(char));
			ei_decode_binary(x_buff->buff, &x_buff->index, b, &len);
			lua_pushlstring(L, b, len);
			free(b);
			break;
		}
		case ERL_SMALL_TUPLE_EXT:
		case ERL_LARGE_TUPLE_EXT: {
				if (in_list && term.arity == 2) {
					if (ei_tracelevel > 0) print("Debug: erlang_to_lua: maybe proplists-tuple.");
					erlang_to_lua(L, x_buff, 0);
					if (lua_isstring(L, -1) && lua_objlen(L, -1) <= MAXATOMLEN) {
						if (ei_tracelevel > 0) print("Debug: erlang_to_lua: yes, set proplists-tuple.");
						erlang_to_lua(L, x_buff, 0);
						lua_rawset(L, -3);
						return 0;
					} else {                          /* Stack: Value */
						lua_createtable(L, 2, 0);     /* Stack: Table Value */
						lua_insert(L, -2);            /* Stack: Value Table */
						lua_rawseti(L, -2, 1);        /* Stack: Table */
						erlang_to_lua(L, x_buff, 0);  /* Stack: Value Table */
						lua_rawseti(L, -2, 2);        /* Stack: Table */
					}
				} else {
					int i;
					if (ei_tracelevel > 0) print("Debug: erlang_to_lua: %d-tuple.", term.arity);
					lua_createtable(L, term.arity, 0);
					for (i = 1; i <= term.arity; i++) {
						erlang_to_lua(L, x_buff, 0);
						lua_rawseti(L, -2, i);
					}
				}
			break;
		}
		case ERL_LIST_EXT: {
				int i, k;
				if (ei_tracelevel > 0) print("Debug: erlang_to_lua: %d-element list.", term.arity);
				lua_createtable(L, term.arity, 0);
				for (k = i = 1; i <= term.arity; i++) {
					if (erlang_to_lua(L, x_buff, 1))
						lua_rawseti(L, -2, k++);
				}
				/* handle the tail */
				erlang_to_lua(L, x_buff, 1);
				if (lua_istable(L, -1) && lua_objlen(L, -1) == 0)
					lua_pop(L, 1);  /* ignore proper list tail */
				else
					lua_rawseti(L, -2, k);  /* improper list tail */
			break;
		}
		case ERL_NIL_EXT:
			lua_newtable(L);
			break;
		default:
			lua_pushnil(L);
			break;
		}
	}
	return 1;
}
