
.PHONY: compile test clean

compile:
	./rebar compile

clean:
	./rebar clean

test:
	PATH=`pwd`/priv:$$PATH ./rebar eunit
