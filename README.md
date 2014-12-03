# Erlang-Lua

Erlang C Node to run Lua scripts

This library provides a way to run Lua code from within Erlang. It
differs from the other Lua - Erlang integrations available, in that it runs
the Lua VM as an external Node (using Erlang's Port and C Node
capabilities).

It's early days in making this available to the public, so be aware
that some assembly is required.

## Building

The Erlang-Lua C C Node code currently compiles and tests successfully
on Mac OS X (10.9, using XCode command line utilities) and Ubuntu
(Trusty 14.04.1 LTS). It probably works on further Mac OS X versions
and Linux distros, but I've not tried it yet.

A Lua installation (5.1 or 5.2) is required to be on the system.
It's needed for the header files and to link the C Node. You can
get Lua from http://www.lua.org/ . The current 5.1 source package
can be downloaded from http://www.lua.org/ftp/lua-5.1.5.tar.gz ,
and the 5.2 one from http://www.lua.org/ftp/lua-5.2.3.tar.gz . To
build on Mac OS X, you run `make macosx test`, and on Ubuntu run
`make linux test`. You'll need to install it somewhere, run `make
INSTALL_TOP=Path_to_Lua_installation install`.

Building the Erlang-Lua C Node uses `rebar`
(https://github.com/rebar/rebar), and a small `Makefile` is provided
to wrap around the calls to `rebar`. You need to edit the `rebar.config`
file and edit the setting of the Lua path to point to your Lua
installation:

```erlang
{ port_env,[
    {"LUA", "/Path_to_Lua_installation"},
...
]}.
```

After that, `make compile` compiles it all up (expect a warning
about `missing braces around initializer`) and `make test` runs the
Eunit test suite. The latter produces a whole bunch of logging to
standard output and, if all is good, ends with `All 87 tests passed.`
A `make clean` does the obvious.


## What It Can Do

Starting a Lua VM through
```erlang
(rtr@127.0.0.1)1> erlang_lua:start_link(foo).
{ok,<0.40.0>}
```
brings up a `gen_server` that provides the interface to running and
monitoring the Lua VM. It starts a C program to run the Lua VM via
`open_port`, monitors it and receives logging from it. The C program
itself initialises itself as an Erlang C Node and connects to the
Erlang Node that launched it.

Running Lua code on the external Lua VM is accomplished by sending
messages to the C Node and receiving answers back. The Lua results
are converted to Erlang terms.
```erlang
(rtr@127.0.0.1)2> erlang_lua:lua(foo, <<"return {x=1, y='foo'}">>).
{lua,[[{y,<<"foo">>},{x,1}]]}
(rtr@127.0.0.1)3> erlang_lua:lua(foo, <<" x = 42 + 'fourty two' ">>).
{error,"[string \" x = 42 + 'fourty two' \"]:1: attempt to perform
 arithmetic on a string value"}
```

Some support for automatically translating Erlang values to Lua is
available via the `call` interface:
```erlang
(rtr@127.0.0.1)4> erlang_lua:lua(foo, <<"find = string.find">>).
{lua,ok}
(rtr@127.0.0.1)5> erlang_lua:call(foo, find, [<<"foobar">>, <<"(o)b(a)">>]).
{lua,[3,5,<<"o">>,<<"a">>]}
```

It is also possible to call back into Erlang from Lua:
```erlang
(rtr@127.0.0.1)6> erlang_lua:lua(foo, <<"return erl_rpc('date')">>).
{lua,[[2014,12,3]]}
(rtr@127.0.0.1)7> erlang_lua:lua(foo, <<"return erl_rpc('erlang', 'date')">>).
{lua,[[2014,12,3]]}
(rtr@127.0.0.1)8> erlang_lua:lua(foo, <<"return erl_rpc('lists', 'seq', 2, 15, 3)">>).
{lua,[[2,5,8,11,14]]}
(rtr@127.0.0.1)9> S = <<"foobar">>.
<<"foobar">>
(rtr@127.0.0.1)10> {lua, [ R ]} = erlang_lua:call(foo, erl_rpc, [base64, encode, S]).
{lua,[<<"Zm9vYmFy">>]}
(rtr@127.0.0.1)11> {lua, [ S ]} = erlang_lua:call(foo, erl_rpc, [base64, decode, R]).
{lua,[<<"foobar">>]}
```

The Lua VM is stopped using
```erlang
(rtr@127.0.0.1)12> erlang_lua:stop(foo).
ok
```


### Value Translation From Lua To Erlang

```
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
```


### Value Translation From Erlang To Lua

```
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
```
