import base64, json, re, struct, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# --- fixtures ---------------------------------------------------------------
def make_wav(pcm: bytes) -> bytes:
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16)
    hdr += b"data" + struct.pack("<I", len(pcm))
    return hdr + pcm

PCM_CHUNK = b"\x01\x00" * 2400          # 0.1s of 24kHz mono PCM16
WAV = make_wav(PCM_CHUNK * 10)          # 1s wav
MP3 = b"ID3" + b"\x00" * 7 + b"\xff\xfb\x90\x64" + b"\x00" * 400

MODELS = {"mimo-v2.5-tts", "mimo-v2.5-tts-voicedesign", "mimo-v2.5-tts-voiceclone"}


class H(BaseHTTPRequestHandler):
    def _reply(self, code: int, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        print("MOCK got path=%s api-key=%s body=%s" % (
            self.path, self.headers.get("api-key"), body.decode()), flush=True)

        if self.path != "/v1/chat/completions":
            return self._reply(404, b'{"error":{"message":"not found"}}')
        if self.headers.get("api-key") != "test-key":
            return self._reply(401, b'{"error":{"message":"bad api key"}}')

        p = json.loads(body)
        model = p.get("model")
        msgs = p.get("messages") or []
        audio = p.get("audio") or {}
        streaming = bool(p.get("stream"))

        assistant = next((m for m in msgs if m.get("role") == "assistant"), None)
        user = next((m for m in msgs if m.get("role") == "user"), None)

        err = None
        if model not in MODELS:
            err = "unknown model %r" % model
        elif not assistant or not (assistant.get("content") or "").strip():
            err = "assistant message with target text is required"
        elif streaming and audio.get("format") != "pcm16":
            err = "streaming requires audio.format=pcm16"
        elif not streaming and audio.get("format") not in ("mp3", "wav"):
            err = "audio.format must be mp3 or wav"
        elif model == "mimo-v2.5-tts":
            if not audio.get("voice"):
                err = "preset model requires audio.voice"
        elif model == "mimo-v2.5-tts-voicedesign":
            if not user or not (user.get("content") or "").strip():
                err = "voicedesign requires user message with voice description"
            if audio.get("voice"):
                err = "voicedesign must not send audio.voice"
        elif model == "mimo-v2.5-tts-voiceclone":
            if not re.match(r"^data:audio/[a-z0-9+\-.]+;base64,", audio.get("voice") or ""):
                err = "voiceclone requires audio.voice as data URI"
        if err:
            return self._reply(400, json.dumps({"error": {"message": err}}).encode())

        if streaming:
            # SSE: three pcm16 chunks + [DONE]
            payload = b""
            for _ in range(3):
                ev = {"choices": [{"delta": {"audio": {"data": base64.b64encode(PCM_CHUNK).decode()}}}]}
                payload += b"data: " + json.dumps(ev).encode() + b"\n\n"
            payload += b"data: [DONE]\n\n"
            return self._reply(200, payload, "text/event-stream")

        audio_bytes = WAV if audio.get("format") == "wav" else MP3
        resp = {"choices": [{"message": {"audio": {"data": base64.b64encode(audio_bytes).decode()}}}]}
        return self._reply(200, json.dumps(resp).encode())

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18923
    HTTPServer(("127.0.0.1", port), H).serve_forever()
