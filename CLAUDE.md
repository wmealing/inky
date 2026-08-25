# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Inky is an Erlang/OTP application: a Telegram bot (via `pe4kin`) that forwards user
messages to a local Ollama instance for LLM-driven responses, with a tool-calling
mechanism for dispatching LLM tool requests to local Erlang functions. It's an early-stage
project (single-user validation, mock tools) intended to grow into home automation /
hardware control / server monitoring.

## Commands

```bash
rebar3 compile          # build
rebar3 shell            # run the app (loads config/sys.config, starts gun/pe4kin/inky)
```

There is no test suite, linter, or CI configured yet.

### Running as a release

`rebar.config` defines a `relx` release (`inky`) plus a `prod` profile that bundles ERTS.

```bash
rebar3 release                              # dev-mode release -> _build/default/rel/inky
_build/default/rel/inky/bin/inky console    # foreground, interactive shell
_build/default/rel/inky/bin/inky start      # daemonized
_build/default/rel/inky/bin/inky stop

rebar3 as prod release                      # self-contained release with bundled ERTS
rebar3 as prod tar                          # ship as inky-<vsn>.tar.gz
```

`inky.app.src` must declare `gun` and `pe4kin` in `applications` (not just `hackney`) —
without that, relx has no dependency info to order application startup and will start
`inky` before `gun`'s supervisor exists, crashing on boot.

### Configuration

Two config files are required and are gitignored-by-convention (`.example` versions are
tracked instead):

```bash
cp config/sys.config.example config/sys.config   # bot name/token, weather API key
cp config/bot.config.example config/bot.config
```

`config/sys.config` sets the `inky` app env (`name`, `token`) and the `weather` app env
(OpenWeatherMap prefix/key/city) read by `inky_app:start/2`.

Requires Erlang/OTP 27+, Rebar3, and a local Ollama instance serving `llama3.2` (or
another model) at `http://localhost:11434`.

## Architecture

**Supervision tree** (`inky_sup`): one supervisor with two permanent workers —
- `inky` — the gen_server owning the Telegram bot session.
- `ollama_worker` — the gen_server owning the Ollama HTTP client and conversation history.

**Startup path**: `inky_app:start/2` reads `name`/`token` from app env, builds an
`#auth_state{}`, calls `pe4kin:launch_bot/3` directly (before the supervisor starts),
then starts `inky_sup`, which starts `inky`. `inky:init/1` is the single place that both
subscribes to updates (`pe4kin_receiver:subscribe(BotName, self())`) and starts polling
(`start_polling/1`) — this used to be split across `inky_app:start/2` and `inky:start_link/1`
as well, which caused two real bugs, now fixed:
- `pe4kin_receiver:start_http_poll/2` was called once in `inky_app:start/2` and again in
  `inky:init/1`; the second call hit `pe4kin_receiver`'s internal state guard and returned
  `{error, bad_request, ...}`, which `inky:start_polling/1` logged as "Polling started
  successfully" since it only distinguishes `{'EXIT', _}` from everything else.
- `inky:start_link/1` used to call `pe4kin_receiver:subscribe(Name, ?MODULE)` — passing
  the *module atom* `inky`, not a pid, and before the process was even registered.
  `pe4kin_receiver:subscribe/2` monitors its argument as a pid; monitoring an unregistered
  name delivers an immediate `noproc` DOWN message, which `pe4kin_receiver` treated as the
  subscriber dying and silently dropped it — so updates polled successfully but were never
  delivered to `inky`, and no message-handling logs (`TEXT:`, `USERNAME:`) ever appeared.

If startup/reconnect logic is touched again, keep subscribe+poll-start both inside
`init/1`, using `self()`.

**Message flow**: pe4kin delivers `{pe4kin_update, _, Update}` to `inky` (the gen_server
subscribed to updates). `inky` pulls chat id / text / username out of the raw Telegram
map, calls `validate:for/1` to gate on username (currently hardcoded to allow only
`<<"wmealing">>`), then calls `ollama_worker:ask/1` synchronously and replies via
`pe4kin:send_message/2`. There's no per-chat state — `ollama_worker` keeps a single
shared conversation `history` for the whole bot, and `ask/1` blocks the caller (30s
timeout).

**Ollama tool-calling loop** (`ollama_worker:process_interaction/2`): posts the message
history plus a tool schema to `/api/chat`; if the response contains `tool_calls`, it
dispatches each to `dispatch_local_tool/2`, appends the tool results and assistant
message to history, and recurses until Ollama returns a plain `content` message. Only one
tool exists today (`get_weather`, hardcoded response) — this is the pattern to extend
when adding real tool dispatch (e.g. shelling out, hardware control).

**Sensors** (`inky_sensor` / `inky_sensor_server` / `inky_sensor_sup`): background
pollers, deliberately *not* `inky_tool` modules. Tool dispatch happens inside
`ollama_worker:ask/1`, which blocks the Telegram handler on a 30s timeout, so a sensor
doing slow or flaky I/O there would stall the bot. Instead each sensor polls on its own
timer and caches its last reading; `sensor_tool` (a single `read_sensor` tool exposing
every sensor by name) just serves that cache, so dispatch is instant and always
answerable — worst case it reports a stale reading and its age.

- `inky_sensor` is the behaviour: `name/0`, `description/0`, `interval/0`, `init/0`,
  `read/1`, `format/1`, plus optional `read_timeout/0`, `alerts/2`, `keywords/0`.
- `inky_sensor_server` is one generic gen_server hosting any such module, registered
  under the callback module's own name. It owns the timer, the cached last-good reading
  and its age, the consecutive-failure count, and alert edge detection. It runs
  `Mod:read/1` in a throwaway monitored process under `read_timeout/0`, so a wedged
  device or hung `os:cmd/1` costs one bounded stall rather than jamming the server
  permanently.
- `inky_sensor_sup` auto-discovers sensors by `-behaviour(inky_sensor)` attribute, the
  same trick `inky_tools:all/0` uses for tools — adding a sensor is just adding a module.
  The `sensors` app env overrides the list. It is a *separate* supervisor from `inky_sup`
  on purpose: sensors are `transient` under `{one_for_one, 10, 60}`, so a sensor whose
  hardware is missing crash-loops on its own budget instead of blowing `inky_sup`'s
  `{one_for_one, 3, 5}` and taking the bot and `ollama_worker` with it.
- **Alerts are edge-triggered.** `alerts/2` returns one `{Key, Message}` per condition
  currently true; the server messages the user (via `message_user:send/1`) only when a
  Key appears or disappears. A value hovering on a threshold therefore doesn't spam the
  chat. This is the path by which the bot can talk *first*, with no LLM involved.

Two sensors ship today. `host_sensor` is the simple one: uptime, load average, memory, and free
space per mount, on Linux (`/proc`) and macOS (`sysctl`/`vm_stat`), with `df -kP` parsed
identically on both. Every field is gathered defensively — anything unreadable on this
host comes back `undefined` and is left out of the rendered text rather than failing the
whole reading. Its thresholds are re-read from app env each poll so they can be retuned
live with `application:set_env/3` (see `reload.erl`); `mounts`/`interval` are read once at
`init/0`. Configure under the `inky` app env key `host_sensor` — see
`config/sys.config.example`.

`beam_sensor` watches the VM inky itself runs in: memory by category, the
process/port/atom tables against their hard limits, run queue, scheduler utilisation, and
the mailbox depth of `inky`/`ollama_worker`/`message_user`. Two things to know if you
touch it:

- It is the **stateful** example of the behaviour. Scheduler utilisation only means
  anything as a delta, so `read/1` carries the previous `scheduler_wall_time` sample
  forward in its state and the first reading after start reports `undefined`. It also
  filters that sample down to normal schedulers (`Id =< erlang:system_info(schedulers)`)
  — the raw list includes idle dirty-CPU schedulers, which halved the figure and made a
  fully pegged 8-core box report 50% busy.
- The **mailbox depth of `inky` is the metric worth watching**. `ollama_worker:ask/1`
  blocks its caller for up to 30s, so when Ollama slows down the backlog piles up in
  `inky`'s mailbox — and from Telegram's side a wedged bot just looks quiet. A `{down, _}`
  alert means a watched process was absent *at poll time*, i.e. it exhausted its restart
  intensity rather than merely bouncing between polls.

`inky_fmt` holds the shared byte/duration/percentage formatting both sensors use, so
sensor output reads consistently; sensors return raw numbers and leave spelling to it.

**Health/reconnect logic** in `inky` (`?POLL_HEARTBEAT_INTERVAL` / `?POLL_TIMEOUT`):
a self-rescheduling `check_polling_health` message checks `last_update_time` and casts
`restart_polling_now` if polling looks dead — but `last_update_time` is only ever set at
`init/1` time and is never updated on subsequent messages, so this restart trigger will
currently fire after `?POLL_TIMEOUT` regardless of live traffic. Note this if asked to
fix or extend the reconnect behavior.

**Two identical record definitions**: `#auth_state{}` is defined in both `src/bot.hrl`
and `src/records.hrl`. `bot.hrl` also defines `#bot_message{}` (currently unused). Check
which header a module includes before assuming both are kept in sync.

## Known rough edges worth flagging if touched

- `config/bot.config.example` (tracked in git) contains what appears to be a real
  Telegram bot token rather than a placeholder — flag this to the user rather than
  assuming it's safe to reuse or ignore.
- `src/validate.beam` (a compiled artifact) is checked into `src/` alongside the source.
- Access control (`validate:for/1`) is a hardcoded single-username allowlist, not
  config-driven.
