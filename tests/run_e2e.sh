#!/bin/bash
# MiMo TTS plugin end-to-end test against the locally installed KOReader
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E=/tmp/mimottest
HOME_DIR=$E2E/e2e-home
RESULT=$E2E/e2e-result.txt
MOCK_LOG=$E2E/e2e-mock.log
KO_LOG=$E2E/e2e-koreader.log

# ---- fresh state -----------------------------------------------------------
rm -f "$RESULT" "$MOCK_LOG" "$KO_LOG"
rm -rf "$HOME_DIR/cache" "$HOME_DIR/history" "$HOME_DIR/ota"

# e2e-home skeleton: the plugin + the E2E driver user patch
mkdir -p "$HOME_DIR/plugins" "$HOME_DIR/patches"
ln -sfn "$(dirname "$HERE")" "$HOME_DIR/plugins/mimo-tts.koplugin"
cp "$HERE/e2e-driver.lua" "$HOME_DIR/patches/2-mimo-tts-e2e.lua"
pkill -f 'e2e-book.txt' 2>/dev/null
pkill -f 'mock_mimo' 2>/dev/null
sleep 0.3

# fixtures: books + voice sample for the voiceclone phase
python3 "$HERE/fixtures.py" "$E2E" >/dev/null

# mock libOpenSLES.so for the opensles scenario
if [ ! -f "$E2E/mocksl/libOpenSLES.so" ]; then
    mkdir -p "$E2E/mocksl"
    gcc -shared -fPIC -O2 -o "$E2E/mocksl/libOpenSLES.so" "$HERE/mocksl/mock_opensles.c"
fi

# ---- mock MiMo TTS API ----------------------------------------------------
python3 "$HERE/mock_mimo.py" > "$MOCK_LOG" 2>&1 &
MOCK_PID=$!
for i in $(seq 1 20); do
    curl -s -o /dev/null http://127.0.0.1:18923/v1/chat/completions && break
    sleep 0.2
done

# ---- scenario: playback backend under test ---------------------------------
#   SCENARIO=opensles : Android OpenSL ES backend (driven by the mock library)
#   default           : external command backend (sleep-based fake player)
SCENARIO=${SCENARIO:-command}
if [ "$SCENARIO" = "opensles" ]; then
    PLAYER_CMD=""
    PLAYER_BACKEND="opensles"
    KO_EXTRA_ENV="LD_LIBRARY_PATH=/tmp/mimottest/mocksl MOCK_SL_TIMESCALE=0.05"
else
    PLAYER_CMD="sh -c 'sleep 0.4' x"
    PLAYER_BACKEND="auto"
    KO_EXTRA_ENV=""
fi
# (re)write the plugin settings deterministically for this scenario
python3 - "$PLAYER_CMD" "$PLAYER_BACKEND" <<'PY'
import sys
cmd, backend = sys.argv[1], sys.argv[2]
open("/tmp/mimottest/e2e-home/settings.reader.lua", "w").write("""return {
    ["mimo_tts_settings"] = {
        ["base_url"] = "http://127.0.0.1:18923/v1",
        ["api_key"] = "test-key",
        ["model"] = "mimo-v2.5-tts",
        ["voice"] = "mimo_default",
        ["audio_format"] = "mp3",
        ["speed"] = 1.25,
        ["style_prompt"] = "\u6d4b\u8bd5\u98ce\u683c",
        ["style_tag"] = "\u6e29\u67d4",
        ["use_streaming"] = true,
        ["chunk_size"] = 150,
        ["player_cmd"] = [===[%s]===],
        ["player_backend"] = [===[%s]===],
    },
}
""" % (cmd, backend))
PY
echo "=== scenario: $SCENARIO ==="

# ---- run KOReader with the plugin and the e2e user patch -------------------
DISPLAY_MODE=${1:-dummy}
if [ "$DISPLAY_MODE" = "xvfb" ]; then
    env $KO_EXTRA_ENV KO_HOME=$HOME_DIR timeout -k 5 240 \
        xvfb-run -a -s "-screen 0 1024x768x24" /usr/bin/koreader "$E2E/e2e-book.txt" > "$KO_LOG" 2>&1
else
    env $KO_EXTRA_ENV KO_HOME=$HOME_DIR SDL_VIDEODRIVER=dummy timeout -k 5 240 \
        /usr/bin/koreader "$E2E/e2e-book.txt" > "$KO_LOG" 2>&1
fi
KO_EXIT=$?
pkill -f 'e2e-book.txt' 2>/dev/null
kill $MOCK_PID 2>/dev/null

# ---- assertions -----------------------------------------------------------
pass=0; fail=0
check() { # check <description> <actual> <expected-regex>
    if echo "$2" | grep -qE "$3"; then
        echo "PASS: $1 ($2)"; pass=$((pass+1))
    else
        echo "FAIL: $1 (got: '$2', want: $3)"; fail=$((fail+1))
    fi
}
val() { grep -E "^$1=" "$RESULT" 2>/dev/null | head -1 | cut -d= -f2-; }

echo "=== KOReader exit code: $KO_EXIT ==="
check "koreader exited cleanly" "$KO_EXIT" "^0$"
check "result file written" "$(test -f "$RESULT" && echo yes)" "yes"
check "e2e status" "$(val status)" "^PASS$"
check "plugin discovered & instantiated" "$(val plugin_loaded)" "^true$"
check "document opened" "$(val document_loaded)" "^true$"
check "reflowable document" "$(val rolling_doc)" "^true$"
check "player autodetected" "$(val detected_player)" "mpv|ffplay|mpg123|madplay|play|aplay|paplay|OpenSL|命令行"
check "real audio playback started" "$(val real_play_started)" "^true$"
check "real player busy while playing" "$(val real_player_busy)" "^true$"
check "real player stopped" "$(val real_player_stopped)" "^true$"
check "book mode session started" "$(val phase1_started)" "^true$"
check "auto page turns happened" "$(val phase1_auto_page_turn)" "^true$"
check "book mode ran to the end" "$(val phase1_finished)" "^true$"
check "page mode session started" "$(val phase2_started)" "^true$"
check "page mode did not turn pages" "$(val phase2_no_page_turn)" "^true$"
check "page mode stopped at page end" "$(val phase2_finished)" "^true$"
check "multiple chunks played" "$(val plays)" "^([3-9]|[1-9][0-9]+)$"
check "extra: plain preset synth" "$(val extra_plain)" "^true$"
check "extra: streaming synth" "$(val extra_stream)" "^true$"
check "extra: voicedesign synth" "$(val extra_design)" "^true$"
check "extra: voiceclone synth" "$(val extra_clone)" "^true$"
check "reading underline shown while playing" "$(val underline_seen)" "^true$"
check "underline boxes drawn" "$(val underline_boxes)" "^([1-9]|[1-9][0-9]+)$"
check "caching: synth calls == cache files" "$(val synths)" "^$(val cache_files)$"

SYNTHS=$(val synths)
MOCK_REQS=$(grep -c "^MOCK got" "$MOCK_LOG")
check "mock api: every synth + 4 extras hit the api" "$MOCK_REQS" "^$((SYNTHS + 4))$"
check "request uses api-key header" "$(grep -c 'api-key=test-key' "$MOCK_LOG")" "^$MOCK_REQS$"
check "main run uses streaming (pcm16 + stream flag)" "$(grep -c '"stream":true' "$MOCK_LOG")" "^$((SYNTHS + 1))$"
check "main run requests pcm16" "$(grep -c '"format":"pcm16"' "$MOCK_LOG")" "^$((SYNTHS + 1))$"
check "request assistant message" "$(grep -c '"role":"assistant"' "$MOCK_LOG")" "^$MOCK_REQS$"
check "request speed instruction" "$(grep -c '1.25 倍' "$MOCK_LOG")" "^$SYNTHS$"
check "request style prompt" "$(grep -c '测试风格' "$MOCK_LOG")" "^$SYNTHS$"
check "request style tag" "$(grep -c '(温柔)' "$MOCK_LOG")" "^$((SYNTHS + 1))$"
check "preset voice in request" "$(grep -c '"voice":"mimo_default"' "$MOCK_LOG")" "^$((SYNTHS + 2))$"
check "voicedesign request" "$(grep -c '"model":"mimo-v2.5-tts-voicedesign"' "$MOCK_LOG")" "^1$"
check "voicedesign carries voice description" "$(grep -c '一位温和的女声旁白' "$MOCK_LOG")" "^1$"
check "voiceclone request" "$(grep -c '"model":"mimo-v2.5-tts-voiceclone"' "$MOCK_LOG")" "^1$"
check "voiceclone carries data URI sample" "$(grep -c 'data:audio/wav;base64,' "$MOCK_LOG")" "^1$"

echo
check "backend used" "$(val backend_name)" "command|opensles"
check "negotiated audio format" "$(val negotiated_format)" "mp3|wav"
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0 || exit 1
