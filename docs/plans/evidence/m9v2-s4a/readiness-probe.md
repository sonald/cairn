# M9 S4a readiness probe (2026-08-06, corrected)

## Decision

`experimental/serverStatus.quiescent=true` is a reliable readiness barrier for
the tested rust-analyzer (`12c3381f0b`) sample: an LSP request **started after**
the signal was non-empty in all ten independent cold runs. S4b therefore uses
this signal; `$/progress` is not selected because it has no similarly clear
terminal event.

The prior 2026-08-05 conclusion is invalid and superseded. Its Tokio samples
were not offline, so all five stopped on `cargo metadata` network resolution;
they did not measure normal readiness. It also counted responses received after
the signal instead of requests started after it, which incorrectly treats an
already in-flight `-32801`/empty result as a post-barrier result.

## Corrected method

- `CARGO_NET_OFFLINE=true`;
- the product's Safe initialization options; Tokio uses `cargo.features=all`
  because its default feature set is empty and `Mutex::lock` requires `sync`;
- declares `experimental.serverStatusNotification`, responds to
  `workspace/configuration`, `workspace/workspaceFolders`, registration, and
  work-done requests; and keeps one `prepareCallHierarchy` request outstanding;
- reports a false result only when the **request start** is at or after the
  first `quiescent=true` notification.

The disposable original probe is `/private/tmp/m9_ra_probe.js`; its old raw
Tokio samples are `/private/tmp/m9-ra-tokio-{1..5}.json` and contain
`Updating crates.io index` / DNS failures.

## Cold samples

All values are milliseconds from process start. `post-q` is the first request
started after quiescence; `false post-q` counts `null` or `array:0` by request
start time.

| sample | quiescent | first nonempty | delta | post-q start | post-q result | false post-q |
|---|---:|---:|---:|---:|---|---:|
| exact 1 | 2273.360 | 2230.324 | -43.036 | 2510.491 | `array:1` at 2511.607 | 0 |
| exact 2 | 2114.331 | 2076.131 | -38.201 | 2261.513 | `array:1` at 2262.012 | 0 |
| exact 3 | 2300.912 | 2248.167 | -52.746 | 2513.067 | `array:1` at 2513.467 | 0 |
| exact 4 | 2171.310 | 2135.876 | -35.435 | 2260.620 | `array:1` at 2261.091 | 0 |
| exact 5 | 2152.701 | 2105.626 | -47.075 | 2261.072 | `array:1` at 2261.606 | 0 |
| Tokio all 1 | 3926.708 | 4139.490 | +212.782 | 4013.855 | `array:1` at 4139.490 | 0 |
| Tokio all 2 | 3948.613 | 4130.397 | +181.784 | 4016.733 | `array:1` at 4130.397 | 0 |
| Tokio all 3 | 3975.667 | 4139.654 | +163.987 | 4016.802 | `array:1` at 4139.654 | 0 |
| Tokio all 4 | 4014.606 | 4336.963 | +322.357 | 4262.525 | `array:1` at 4336.963 | 0 |
| Tokio all 5 | 4321.456 | 4588.253 | +266.797 | 4518.195 | `array:1` at 4588.253 | 0 |

The exact fixture can become usable 35–53ms before quiescence, so this is a
correctness barrier rather than the earliest possible result. Tokio becomes
usable 164–322ms after it. Neither corpus returned a false post-barrier result.

## Product consequence

S4b keeps `quiescent` under the existing `LSPClient` condition, waits outside
`operationLock`, and re-checks readiness at both request start and response.
`ready + null` is a legal immediate empty result; preparing waits; `-32801`
continues to retry. The final implementation and its fake-LSP tests are the
durable proof; this probe remains disposable.
