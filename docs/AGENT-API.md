# Agent API

Yap can speak for other programs and listen for them. Anything on your Mac
(an AI agent, a script, a desktop companion) can ask Yap to say a sentence in
your chosen voice, or to open dictation and hand back what you said. Both run
through Yap's own player and capture, so the menu bar's pause and stop still
work, and the dictation HUD still shows whenever the microphone is open.

It is local only: HTTP over a Unix-domain socket. There is no network port, no
account and no token.

```
~/Library/Application Support/Yap/yap.sock
```

Set `YAP_API_SOCKET` to use another path (tests, or two builds side by side).
The API version is `1`; every response carries `X-Yap-API: 1`, and `GET /status`
reports it as `api_version`. A breaking change to a route or field bumps it.

## Security model

- **The socket is the access control.** It is created `0600`, in a folder that
  is not writable by group or others (Yap tightens `Application Support/Yap` if
  it is). Other macOS users cannot connect. A web page cannot either: a browser
  can reach any `127.0.0.1` port, but it cannot open a file. That is why this is
  a socket and not a loopback port, and why there is no token to leak.
- **It does not stop other programs running as you.** Any process you run can
  talk to Yap. For speaking that is harmless. For listening it is not: Yap holds
  your Microphone permission, and through the API any program you run could use
  it without macOS ever asking that program. So:
  - `/listen` is **off by default** (`agentListenEnabled`, default `false`) and
    answers `403` until you turn it on.
  - The dictation HUD always appears while the microphone is open. No request
    parameter can hide it. The start and stop chimes play as for the hotkey.
  - Listening ends when the caller hangs up, when the API is switched off, or
    when `agentListenEnabled` is switched off while it runs. The words are
    discarded then.
  - The text goes back to the caller. It is pasted at the cursor only when the
    request says `"insert": true`.
- **Two preferences control it.** `agentAPIEnabled` (default on) runs the
  server at all; switching it off removes the socket immediately.
  `agentListenEnabled` (default off) allows `/listen`. Both are switches in
  **Settings ▸ Agents** (*Let agents use Yap*, *Allow agents to listen*).
- **What lands on disk.** Text an agent has Yap speak appears in History marked
  "agent". Dictation from `/listen` also appears there: with `"insert": false`,
  it is marked `Agent API`; with `"insert": true`, it is recorded under the
  target app's name, like other inserted dictation. Audio is never saved.
- **Nothing leaves the machine.** The socket is a file. The API makes no network
  call and adds none (see `PRIVACY.md`).

## How requests behave

- One request per connection, JSON in and out, `Connection: close`. Bodies need
  `Content-Length` (no chunked), at most 1 MiB. `curl --data` does this for you.
- The parser is strict. A misspelt field (`"speeed"`), a wrong type (`"speed":
  "2"`), or a value out of range is a `400`, never silently ignored.
- Errors are `{"error": "<message>", "code": "<stable_code>"}`. Programs should
  match on `code`; the message is for people.
- **Hanging up cancels.** If the client closes the connection (or is killed)
  while a `wait` or a `/listen` is pending, Yap stops that speech or closes the
  microphone and drops the words. Keep the connection open while you wait.
  (A half-close counts as hanging up.)
- One voice at a time. A request replaces what is playing, unless it asks to
  queue (`"interrupt": false`).

## Endpoints

### `GET /status`

```
curl -s --unix-socket ~/Library/Application\ Support/Yap/yap.sock http://yap/status
```

```json
{"api_version":1,"app":"Yap","version":"0.9.4","listen_allowed":false,
 "voice":{"state":"idle","engine":"kokoro","voice":"am_puck","id":"kokoro:am_puck",
          "speed":1,"queued":0,"enabled":true,"backend_ready":true},
 "dictation":{"state":"idle","enabled":true,"model_ready":true,"api_session":false}}
```

`voice.state` is `idle`, `reading`, `paused`, `loading` (starting up) or `error`
(with `voice.error`). `dictation.state` is `idle`, `loading_model`, `listening`,
`finishing`, `transcribing` or `error`. `listen_allowed` is true when `/listen`
would be accepted. `voice.speed`/`engine`/`voice` are the user's own selection,
not the last request's.

### `GET /voices`

The voices the menu offers. `id` is `engine:voice`, the form `/speak` accepts.

```json
{"current":"kokoro:am_puck","voices":[
  {"id":"kokoro:am_puck","engine":"kokoro","voice":"am_puck","name":"puck",
   "group":"American English","available":true,"current":true}]}
```

`available` is false for a voice that is listed but cannot speak yet (a cloned
Pocket voice while cloning is not ready).

### `POST /speak`

| field | meaning |
|---|---|
| `text` | required, at most 200,000 characters |
| `voice` | `am_puck` (current engine) or `kokoro:am_puck`; defaults to the user's voice |
| `engine` | `kokoro` or `pocket`; defaults to the user's engine |
| `speed` | 0.25 to 4; defaults to the user's speed |
| `interrupt` | default `true`: replace what is playing and empty the line. `false`: wait your turn (up to 20 waiting) |
| `clean` | default `true`: the normal cleanup (links, markdown, your custom rules). `false`: speak the text as written |
| `wait` | default `false`. `true`: respond only when this speech has finished or been stopped |

`voice`, `engine` and `speed` apply to this request only. They never change the
user's settings.

```
curl -s --unix-socket "$SOCK" http://yap/speak -d '{"text":"Build finished.","speed":1.3}'
curl -s --unix-socket "$SOCK" http://yap/speak -d '{"text":"Done.","wait":true}'
```

```json
{"id":"7","queued":false}
{"id":"8","queued":false,"outcome":"finished"}
```

`outcome` (with `wait`) is `finished`, `stopped` (stop, pause-then-stop, or
replaced by another read) or `error` (with `error`). A queued request returns
`"queued":true,"position":1`. Errors: `400` bad field or unknown voice, `403`
reading is switched off in Settings, `409` voice needs cloning that is not
ready, `429` the line is full, `503` models are being changed or the voice list
has not loaded.

### `POST /stop`, `POST /pause`, `POST /resume`

No body. Each returns `{"state":"idle|reading|paused|…"}`; `/pause` and
`/resume` add `"changed": true|false` (false when there was nothing to pause or
resume). `/stop` adds `"was"`, the state it interrupted, and also empties the line.

### `POST /listen`

Opens dictation: the HUD shows, the mic opens, and the call returns when you
stop talking.

| field | meaning |
|---|---|
| `max_seconds` | default 60, 1 to 170 |
| `silence_seconds` | default 1.5, 0.3 to 10. Quiet this long after you spoke ends it |
| `insert` | default `false`. `true` also pastes the text at the cursor |

```
curl -s --unix-socket "$SOCK" http://yap/listen -d '{"max_seconds":30}'
curl -s --unix-socket "$SOCK" -H 'Accept: text/plain' http://yap/listen -d '{}'
```

```json
{"text":"Remind me to call Sam at three.","reason":"silence","seconds":6.1,"inserted":false}
```

`reason` is `silence`, `max_seconds` or `stopped` (`POST /listen/stop`, the
dictation shortcut, or something else closed the session). With
`Accept: text/plain` the body is just the text and the reason is in the
`X-Yap-Reason` header. The text is the accurate final pass, the same as a
hotkey stop: stopping keeps capturing for a moment and decodes through the
last frame, so a quiet final word is not lost. Empty `text` means nothing was
heard. `inserted` is true only if the text was actually pasted; with `insert: true`
but no Accessibility permission it is false and the text is left on the clipboard.

Silence ends a listen only after speech was heard. When the room is too noisy
for Yap to tell speech from background, it never guesses; `max_seconds` ends it.

Errors: `403 listen_disabled` (the default), `403 dictation_disabled`,
`409 already_listening` (a listen or your own dictation is running),
`503 model_loading` or `model_unavailable`. The first listen may show macOS's
Microphone prompt for Yap.

### `POST /listen/stop`

Ends a running listen now; that `/listen` call returns with `reason: "stopped"`
and the words so far. `409 not_listening` if none is running. It works even when
listening is switched off, since stopping is always allowed.

## Command line

`yap` is a bash script over `curl --unix-socket`. It ships in the app at
`Yap.app/Contents/Resources/bin/yap` (and as `scripts/yap` in the repo). To put
it on your PATH:

```
ln -s /Applications/Yap.app/Contents/Resources/bin/yap /usr/local/bin/yap
```

```
yap say "The build is done."          # or: echo "..." | yap say
yap say --voice af_heart --speed 1.4 --wait "Tests passed."
yap say --no-interrupt "After this one."
yap stop | yap pause | yap resume
yap status | yap voices
yap listen --max 30 --silence 1.2     # prints the transcript
yap listen --insert                   # also pastes it at the cursor
yap listen --json                     # full result
```

Exit codes: `0` ok, `1` error, `2` bad usage, `3` Yap is not running (it says
so, with the socket path), `10` for `say --wait` when the speech was stopped
before it finished.

## Python (standard library only)

```python
import http.client, json, os, socket

SOCK = os.path.expanduser("~/Library/Application Support/Yap/yap.sock")

class Yap(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("yap", timeout=None)
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)

def call(method, path, body=None):
    c = Yap()                       # one request per connection
    c.request(method, path, json.dumps(body) if body is not None else None,
              {"Content-Type": "application/json"})
    r = c.getresponse()
    data = json.loads(r.read() or b"{}")
    c.close()
    if r.status >= 400:
        raise RuntimeError(f'{r.status} {data.get("code")}: {data.get("error")}')
    return data

call("POST", "/speak", {"text": "Say something, and I will write it down.", "wait": True})
heard = call("POST", "/listen", {"max_seconds": 20})   # needs agentListenEnabled
print(heard["text"], "|", heard["reason"])
```

## For people changing this code

- Wire format and validation: `AgentAPI.swift` (pure; covered by `--selftest`).
  Socket server: `AgentServer.swift`. Routes: `AgentAPIController.swift`.
- Speaking is `AppState.speak`, which shares the hotkey's player and `stream`.
  A request's voice, engine and speed travel as `ReadParams`; they are never
  written to `Prefs`. Every start or stop of a read goes through
  `bumpGeneration`, which is also what settles a request's outcome.
- Listening is `DictationController.listenForAgent`, which reuses
  `Dictation.startListening` and `stopAndTranscribe` unchanged. Only the stop
  *trigger* is new (`SpeechGate.endedBySilence`); the stop path is not.
- `--apitest` runs the whole thing against a real sidecar on a spare port with a
  private socket, History file and volume 0, and feeds `/listen` from a speech
  file. It never touches a running Yap. See `AgentProbe.swift`.
- SIGPIPE is ignored process-wide when the server starts. A client that hangs up
  early cannot take the app down (the per-socket option cannot be set once the
  peer is gone).
