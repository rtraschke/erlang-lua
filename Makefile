.PHONY: compile test
all: install_prereqs test

install_prereqs:
	@./config/install_prereqs.sh

compile:
	@LUA=config/lua/src ./config/rebar3 compile

clean:
	@pkill -9 epmd
	@rm -rf \
		_build/ \
		doc/ \
		priv/ \
		c_src/*.d \
		c_src/*.o

test:
	@epmd >/dev/null 2>&1 &
	@PATH=`pwd`/priv:$$PATH LUA=config/lua/src ./config/rebar3 eunit

# dialyzer check and generate documents
ck:
	@./config/rebar3 ck

reset:
	@git fetch --all; git reset --hard origin/master