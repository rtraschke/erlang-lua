#!/bin/bash
REBAR_VER=3.6.2
LUA_VER=5.3.5

cd config
if [ ! -f "./rebar3" ]; then
    wget https://github.com/erlang/rebar3/releases/download/${REBAR_VER}/rebar3
    chmod +x rebar3
fi

if [ ! -f "./lua/src/lua.h" ]; then
    curl -R -O http://www.lua.org/ftp/lua-${LUA_VER}.tar.gz
    tar zxf lua-${LUA_VER}.tar.gz
    rm -f lua-${LUA_VER}.tar.gz
    mv lua-${LUA_VER} lua
    cd lua
    make linux test
fi

cd ..