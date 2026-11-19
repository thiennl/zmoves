# zmove-swift

Swift port of [zmove](../zmove/) — online mailbox move for Zimbra FOSS
(zmmboxmove-compatible, DB+blob level, item IDs preserved).

## Binaries

- `zmove` — full job engine: `move preflight batch query events resume abort
  rollback purge unlock gc`, plus `mboxmove` (NE compat) and `ne-move`
  (NE-faithful server-side move).
- `zmmboxmove` — standalone NE `zmmboxmove` port: asks the destination server
  to move a mailbox (`-a/--account -f/--from -t/--to [--sync] [--force]
  [--ng-migration] [--server] [--authtoken[File]]`).

Exit codes mirror the Python CLI: `0` ok, `1` operational failure,
`2` usage/config error.

## Build / test

Requires Swift 6.1+ and `libsqlite3-dev` (system library target `CSQLite`).

```sh
swift build
swift test          # 15 tests: paths, SQL builders, State journal, config, CLI parsing
./.build/debug/zmove --help
```

## Layout

`Sources/ZMove/` mirrors the Python modules one-to-one:

| Swift | Python | Notes |
|---|---|---|
| CLI.swift (+ `zmove/main.swift`, `zmmboxmove/main.swift`) | `cli.py`, `__main__.py`, `compat_mboxmove.main` | hand-rolled argparse-shaped parser, same flags/exit codes |
| Engine.swift / EngineRun.swift | `engine.py` | durable 15-phase state machine, watchdog, confirm steps |
| Batch.swift | `batch.py` | plan-file moves, parallelism, per-server limits, canary |
| DbMove.swift / Db.swift | `dbmove.py`, `db.py` | stage-schema copy, remap, verify, merge |
| Blobs.swift / Caches.swift | `blobs.py`, `caches.py` | rsync plans, memcache/MTA handling |
| NeServer.swift | `ne_server.py` | NE-faithful full-copy-while-locked move |
| CompatMboxmove.swift | `compat_mboxmove.py` | MoveMailboxRequest via admin SOAP |
| Remote.swift / Soap.swift / Topology.swift | `remote.py`, `soap.py`, `topology.py` | ssh/zmprov/admin-SOAP surface |
| State.swift | `state.py` | SQLite journal (`jobs`, `events`, `purges`), same schema |
| Config.swift / Paths.swift / Util.swift | `config.py`, `paths.py`, shell bits | same `[zmove]` config keys, same layout math |

Deliberate differences from Python (all in code comments where they bite):
- `replaceHostInTransport` always stamps the destination LMTP port (matches NE).
- `State.init` executes the schema on open (Python relied on import-time migrate).
- `zmove move --background` relaunches via `/usr/bin/setsid` when present.
- Fatal `EngineMoveError`/`NeMoveError` instead of `MoveError`; `CLIError` for usage.
