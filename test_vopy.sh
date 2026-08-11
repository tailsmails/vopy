#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

get_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        md5sum "$1" | awk '{print $1}'
    fi
}

cleanup() {
    log_info "Cleaning up temporary test files..."
    rm -f test_src.bin test_dst.bin test_dst.bin.resume test_dst.bin.tmp vopy test_out.log test_err.log
}
trap cleanup EXIT

if [ ! -f "./vopy" ] || [ "vopy.v" -nt "./vopy" ]; then
    log_info "Compiling vopy.v using V compiler..."
    rm -f ./vopy
    if ! v vopy.v; then
        log_error "V compilation failed. Please make sure the V compiler is installed and in your PATH."
        exit 1
    fi
    log_success "vopy compiled successfully."
else
    log_info "Pre-compiled vopy binary is up-to-date. Skipping compilation to test the final release binary."
fi

log_info "Running Test 1: Standard File Copy..."
dd if=/dev/urandom of=test_src.bin bs=1M count=10 2>/dev/null
SRC_HASH=$(get_hash test_src.bin)

./vopy -v test_src.bin test_dst.bin
DST_HASH=$(get_hash test_dst.bin)

if [ "$SRC_HASH" == "$DST_HASH" ]; then
    log_success "Test 1 Passed: Destination file matches source exactly."
else
    log_error "Test 1 Failed: Hash mismatch."
    exit 1
fi

log_info "Running Test 2: Resumable File Copy (Interrupt and Resume)..."
rm -f test_dst.bin test_dst.bin.resume
dd if=/dev/zero of=test_src.bin bs=1M count=500 2>/dev/null
SRC_HASH=$(get_hash test_src.bin)

./vopy -t 0 -v test_src.bin test_dst.bin >test_out.log 2>test_err.log &
VOPY_PID=$!

METADATA_CREATED=false
for i in {1..1000}; do
    if [ -f "test_dst.bin.resume" ]; then
        METADATA_CREATED=true
        break
    fi
    sleep 0.002 2>/dev/null || sleep 0.01
done

if [ "$METADATA_CREATED" = true ]; then
    kill -9 $VOPY_PID 2>/dev/null
    log_success "Resume metadata file (.resume) successfully created and copy interrupted."
else
    log_error "Test 2 Failed: Resume metadata file was not created within timeout."
    if [ -f "test_err.log" ]; then
        echo "--- vopy stderr ---"
        cat test_err.log
    fi
    if [ -f "test_out.log" ]; then
        echo "--- vopy stdout ---"
        cat test_out.log
    fi
    kill -9 $VOPY_PID 2>/dev/null
    exit 1
fi

log_info "Resuming copy process..."
./vopy -v test_src.bin test_dst.bin
DST_HASH=$(get_hash test_dst.bin)

if [ "$SRC_HASH" == "$DST_HASH" ]; then
    log_success "Test 2 Passed: Resumed copy finished and final hash matches source exactly."
else
    log_error "Test 2 Failed: Resumed copy hash mismatch."
    exit 1
fi

log_info "Running Test 3: Smart Overwrite (In-place Substitution)..."
printf "BLOCK_1: This is block number one of our test file.\nBLOCK_2: Unchanged block that should be skipped.\nBLOCK_3: This is block number three.\n" > test_src.bin

./vopy -v test_src.bin test_dst.bin

printf "BLOCK_1: This is block number ONE of our test file.\nBLOCK_2: Unchanged block that should be skipped.\nBLOCK_3: This is block number three.\n" > test_src.bin
SRC_HASH=$(get_hash test_src.bin)

log_info "Copying with smart-overwrite flag (-m)..."
./vopy -m -v test_src.bin test_dst.bin
DST_HASH=$(get_hash test_dst.bin)

if [ "$SRC_HASH" == "$DST_HASH" ]; then
    log_success "Test 3 Passed: Smart-overwrite successfully updated modified block."
else
    log_error "Test 3 Failed: Hash mismatch in smart-overwrite."
    if [ -f "test_src.bin" ]; then
        echo "--- test_src.bin content ---"
        cat test_src.bin
    fi
    if [ -f "test_dst.bin" ]; then
        echo "--- test_dst.bin content ---"
        cat test_dst.bin
    fi
    exit 1
fi

log_info "Running Test 4: Smart Overwrite (Shift Cancellation)..."
printf "[SECTION A]\nAAAAAA\n[SECTION B]\nBBBBBB\n[SECTION C]\nCCCCCC\n" > test_src.bin

./vopy -v test_src.bin test_dst.bin

printf "[SECTION A]\nAAAAAAAA\n[SECTION B]\nBBBB\n[SECTION C]\nCCCCCC\n" > test_src.bin
SRC_HASH=$(get_hash test_src.bin)

log_info "Copying shift-cancelled file with smart-overwrite (-m)..."
./vopy -m -v test_src.bin test_dst.bin
DST_HASH=$(get_hash test_dst.bin)

if [ "$SRC_HASH" == "$DST_HASH" ]; then
    log_success "Test 4 Passed: Shift cancellation successfully handled and synced."
else
    log_error "Test 4 Failed: Hash mismatch in shift cancellation."
    if [ -f "test_src.bin" ]; then
        echo "--- test_src.bin content ---"
        cat test_src.bin
    fi
    if [ -f "test_dst.bin" ]; then
        echo "--- test_dst.bin content ---"
        cat test_dst.bin
    fi
    exit 1
fi

echo ""
log_success "ALL TESTS PASSED SUCCESSFULLY!"
