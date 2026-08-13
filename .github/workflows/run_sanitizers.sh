#!/usr/bin/env bash
export PS4='\033[0;33m+ >>>>> (${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }\033[0m'
set -xe

TEST_SCRIPT="./test_vopy.sh"
RUN_CMD=""

if [ -f "$TEST_SCRIPT" ]; then
    chmod +x "$TEST_SCRIPT"
    RUN_CMD="$TEST_SCRIPT"
elif [ -f "./test.sh" ]; then
    chmod +x "./test.sh"
    RUN_CMD="./test.sh"
elif [ -f "./tests.sh" ]; then
    chmod +x "./tests.sh"
    RUN_CMD="./tests.sh"
else
    RUN_CMD="./vopy_test_fallback.sh" # I will add it later...
    cat << 'EOF' > "$RUN_CMD"
#!/usr/bin/env bash
set -xe
echo "running fallback test"
echo "test payload data block" > src.txt
./vopy src.txt dst.txt
diff src.txt dst.txt
echo "modified test payload data block" > src_mod.txt
./vopy -m src_mod.txt dst.txt
diff src_mod.txt dst.txt
rm -f src.txt src_mod.txt dst.txt
EOF
    chmod +x "$RUN_CMD"
fi

export DEBUG_OPTS="-keepc -cg -cflags -fno-omit-frame-pointer"
export VFLAGS="-cc clang -d no_backtrace -enable-globals -autofree"

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=memory" -o vopy .
touch vopy
MSAN_OPTIONS="halt_on_error=1" "$RUN_CMD"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=undefined" -o vopy .
touch vopy
UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" "$RUN_CMD"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=thread" -o vopy .
touch vopy
TSAN_OPTIONS="halt_on_error=1" "$RUN_CMD"
rm -f vopy

v ${VFLAGS} ${DEBUG_OPTS} -cflags "-fsanitize=address,pointer-compare,pointer-subtract" -o vopy .
touch vopy
ASAN_OPTIONS="detect_leaks=1:halt_on_error=1" UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" "$RUN_CMD"
rm -f vopy

if [ "$RUN_CMD" = "./vopy_test_fallback.sh" ]; then
    rm -f "./vopy_test_fallback.sh"
fi
