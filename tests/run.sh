#!/bin/sh
# Local CI: run the full unit/integration battery.
#
#   make test          (or: sh tests/run.sh)
#
# Requirements:
#   - a KOReader installation (auto-detected at /usr/lib/koreader, or set
#     KOREADER_DIR)
#   - luajit (normally shipped with KOReader), python3, gcc, GNU gettext
#
# Scratch files live in /tmp/mimottest (cleared on every run); the plugin is
# exposed there as /tmp/mimottest/plugin so the suites are machine-independent.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(dirname "$HERE")
KOREADER_DIR=${KOREADER_DIR:-/usr/lib/koreader}
T=${T:-/tmp/mimottest}
LUAJIT=${LUAJIT:-"$KOREADER_DIR/luajit"}
[ -x "$LUAJIT" ] || LUAJIT=luajit

if [ ! -f "$KOREADER_DIR/setupkoenv.lua" ]; then
    echo "tests: KOReader not found at $KOREADER_DIR (set KOREADER_DIR)" >&2
    exit 1
fi

echo "tests: scratch dir $T"
rm -rf "$T"
mkdir -p "$T/mocksl" "$T/menu-home" "$T/ko"

# expose the plugin at a fixed path (the suites reference /tmp/mimottest/plugin)
ln -sfn "$REPO" "$T/plugin"

# KOReader shim: symlink its tree so setupkoenv/lualibs work with cwd=$T/ko
for f in "$KOREADER_DIR"/*; do ln -sfn "$f" "$T/ko/"; done
rm -rf "$T/ko/cache" && mkdir -p "$T/ko/cache"   # keep the cache writable

# fixtures + mock libraries
python3 "$HERE/fixtures.py" "$T"
gcc -shared -fPIC -O2 -o "$T/mocksl/libOpenSLES.so" "$HERE/mocksl/mock_opensles.c"
echo "tests: mock libOpenSLES.so built"

# mock MiMo API
python3 "$HERE/mock_mimo.py" > "$T/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
i=0
while [ $i -lt 20 ]; do
    if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',18923))==0 else 1)" 2>/dev/null; then
        break
    fi
    i=$((i+1)); sleep 0.2
done
echo "tests: mock MiMo API on :18923"

LIBS="$T/mocksl:$T/ko/libs"
pass=0; fail=0; failed=""
run_suite() { # run_suite <name> [extra env assignments...]
    name=$1; shift
    echo "== $name =="
    if ( cd "$T/ko" && env LD_LIBRARY_PATH="$LIBS" "$@" "$LUAJIT" "$HERE/$name.lua" ) \
        > "$T/$name.out" 2>&1 && grep -aq "^ALL" "$T/$name.out"; then
        grep -a "ALL" "$T/$name.out" | tail -1
        pass=$((pass+1))
    else
        tail -5 "$T/$name.out"
        fail=$((fail+1)); failed="$failed $name"
    fi
}

run_suite test_basic
run_suite test_features
run_suite test_integration
run_suite test_underline
run_suite test_notrash
run_suite test_backends
run_suite test_i18n
run_suite test_topmenu KO_HOME="$T/menu-home"

echo
echo "tests: $pass passed, $fail failed${failed:+ ($failed)}"
[ $fail -eq 0 ]
