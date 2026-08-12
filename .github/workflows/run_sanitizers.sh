#!/usr/bin/env bash
export PS4='\033[0;33m+ >>>>> (${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }\033[0m'
set -xe

TEST_SCRIPT="./test.sh"

if [ ! -f "$TEST_SCRIPT" ]; then
    exit 1
fi

chmod +x "$TEST_SCRIPT"

export DEBUG_OPTS="-keepc -cg -cflags -fno-omit-frame-pointer"
export VFLAGS="-cc clang -d no_backtrace -enable-globals -autofree"

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=memory" -o vopy .
touch vopy
MSAN_OPTIONS="halt_on_error=1" "$TEST_SCRIPT"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=undefined" -o vopy .
touch vopy
UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" "$TEST_SCRIPT"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=thread" -o vopy .
touch vopy
TSAN_OPTIONS="halt_on_error=1" "$TEST_SCRIPT"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=address,pointer-compare,pointer-subtract" -o vopy .
touch vopy
ASAN_OPTIONS="detect_leaks=1:halt_on_error=1" UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" "$TEST_SCRIPT"
rm -f vopy
