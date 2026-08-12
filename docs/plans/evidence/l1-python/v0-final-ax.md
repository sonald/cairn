# L1 V0 final-bundle AX record

Date: 2026-08-12 Asia/Shanghai
Bundle ID: `dev.cairn.Cairn.l1v0.20260812133706`
App: `.build/l1-distribution-v0-20260812133706/Cairn.app`
Launch: `open -n` through LaunchServices; `launchctl getenv PATH` was empty

The checks below were read from the live AppKit accessibility tree and visible bundle frames, not
from source inspection or the debug binary.

## First launch and explicit language entry

```text
File
  Open Project…
  Open Python Project…
  Quick Open…
```

`Open Python Project…` opened the fixed `mcp-python-sdk` corpus. The Python tree exposed only `.py`
leaves; the live tree reached `src/mcp/shared/memory.py` without exposing config or foreign-language
files.

## Python profile, Reader, and Exact

```text
Project: mcp-python-sdk
Profile menu: Current unit: mcp-python-sdk · Safe
Exact: deps unavailable (offline) · Safe
Provider: pyright
Tool version: pyright 1.1.411
Interpreter: Python 3.14.6
Limitations: dependencies unavailable offline
```

`memory.py` produced the following AX rows and visible Reader state:

```text
OUTLINE
  fn create_client_server_memory_streams
  fn create_connected_server_and_client_session
Reader: Python keywords/strings/comments styled; fold ruler present
```

The visible profile/menu contained no Cargo feature or Rust edition. The Relations segmented control
exposed Callers, Calls, Implements, and References; the final-bundle structured product run supplied
the reproducible provider counts and unsupported-implementations result.

## Snapshot and compare coverage

The live Version popover showed Working Tree plus the repository history. It was changed to
`3abefee` and back to Working Tree while `memory.py`, its Python outline, and the Pyright status
remained present. The same final bundle binary's structured Python product channel separately
verified the deterministic HEAD~1 compare: one non-truncated hunk, right Reader bytes equal to the
commit and different from the worktree.

## Quit, relaunch, and recent identity

The application menu action `Quit Cairn` was used and the process disappeared from the running-app
list. Relaunching the same bundle ID restored:

```text
Project: mcp-python-sdk
Selected file: memory.py
Profile menu: Current unit: mcp-python-sdk · Safe
Exact provider: pyright 1.1.411, ready with offline limitation
Open Recent: mcp-python-sdk
```

This record intentionally contains no copied UserDefaults values from the normal production bundle
ID and no generated theme screenshots: the milestone introduced no untested visible theme delta.
