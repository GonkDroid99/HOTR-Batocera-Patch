# HOTR quick wins, user features and an FAQ

## Context

Two real defects and one missing document came out of the wiki work:

1. **The Sinden broker log grows without bound.** `scripts/hotr-service` rotates only the HOTR log
   (`rotate_log()`, `MAX_LOG_BYTES=1048576`, called on `start`), and the broker opens its own log
   append-only in `payload/system/hotr-sinden-broker.py:906-908`. A machine that stays up for weeks
   accumulates every serial frame line (`player 1: serial … (…)`).
   (The debug-report history is *not* a problem: `start_capture()` deliberately deletes older
   `hotr-debug-*.txt` at `scripts/hotr-debug-report.sh:253`.)
2. **The installer has no preflight.** `install.sh` fails late and cryptically when a tool is
   missing (it only checks root/arch at `:61-63`, the series at `:65-80`, and
   `batocera-save-overlay` at `:504`). `bootstrap.sh` and `update.sh` need `curl`/`python3`/`unzip`
   even earlier and check nothing.
3. **There is no FAQ.** Answers to the recurring questions live scattered across
   `README.md`, `openwiki/reference-troubleshooting.md` and `openwiki/known-limitations.md`.

The user also asked for new user-facing features and their quick wins, plus a plain-language
explanation of broker fan-out; both are out of scope for this plan (see the decisions at the end).

## Approach

### A. Broker log rotation (quick win)

Make the broker own its log and rotate it while running, and teach the service the same policy for
existing files:

- `payload/system/hotr-sinden-broker.py`: replace `logging.basicConfig(filename=…)` at `:906` with a
  `logging.handlers.RotatingFileHandler(args.log, maxBytes=SINDEN_LOG_MAX_BYTES, backupCount=1)`
  (default 1 MiB, override via env `HOTR_SINDEN_LOG_MAX_BYTES`), keeping the existing format
  `"%(asctime)s hotr-sinden-broker: %(message)s"`. Without `--log` keep the current
  `basicConfig()` console behaviour.
- `scripts/hotr-service`: extend `rotate_log()` (or add `rotate_file()`), and rotate
  `$SINDEN_LOG` at `start` before launching the broker, so existing oversized logs shrink on the
  next service start. Keep the one `.old` generation naming the HOTR log already uses.

### B. Installer preflight (quick win)

Add one `preflight()` to `install.sh` that runs before the series gate and prints a single summary
block; it checks:

- root, `x86_64`, `/userdata` writable;
- required tools: `python3`, `curl`, `unzip`, `tar`, `tee`, `md5sum`;
- optional tools: `rsync` (fallback exists), `start-stop-daemon`, `setsid`, `batocera-save-overlay`;
- free space on `/userdata` (payloads are ~200 MB compressed: `payload/hotr` 92 MB,
  `payload/emulators` 109 MB, plus extracted emulator binaries) — fail below 1 GB, warn below 2 GB.

`bootstrap.sh` gets a two-line guard (`curl`, `python3`, `unzip`) before the release download, and
`update.sh` the same before it downloads, so the failure message names the missing tool instead of a
later syntax/`command not found` error.

### C. FAQ page

New `openwiki/faq.md` (hand-written, page-relative links, added to `openwiki/index.md`): one-line
questions with short answers that link to the deep page — how do I know it is working, why does my
gun not kick, why does aiming stop, two guns, which Batocera versions, does it touch my stock
emulators, how do I go back, where are the logs, how do I send a debug report, is my gun supported,
why is there no recoil in ammo games, how do I turn it off, what about 3+ guns.

`README.md` gets a one-line pointer to it in the Sinden section.

### D. User features — skipped this round

The user reviewed the candidates (a unified `hotr-recoil` CLI over the existing tools, single-action
ES ports, `hotr-status --json`, CI checks) and chose to skip them for now. Fan-out is dropped too:
one player driving several guns has no practical use for this setup. Neither is part of this plan.

## Files to modify

- `payload/system/hotr-sinden-broker.py` — rotating log handler
- `scripts/hotr-service` — rotate `$SINDEN_LOG` on start
- `install.sh` — `preflight()`; `update.sh`, `bootstrap.sh` — dependency guards
- `openwiki/faq.md` (new), `openwiki/index.md`, `README.md`
- `scripts/tests/hotr-sinden-broker-selftest.sh`, `scripts/tests/hotr-sinden-tools-selftest.sh`
- `PLAN.md`, `docs/PROJECT_LAYOUT.md`, `openwiki/logs-and-diagnostics.md`

## Reuse

- `scripts/hotr-service:34-38` `rotate_log()` pattern and `MAX_LOG_BYTES` (rotate one `.old` file).
- `install.sh:13-15` `msg/warn/die` helpers for the preflight output; `install.sh:19-31`
  `copy_missing_tree` is the existing add-only copy helper.
- `scripts/tests/hotr-sinden-tools-selftest.sh` `report()` harness for any new assertion.

## Steps

- [x] A1 Rotating handler in the broker + env override
- [x] A2 Service rotates `$SINDEN_LOG` on start
- [x] A3 Broker selftest: assert rotation happens past the cap (or that the handler is configured)
- [x] B1 `preflight()` in `install.sh` (summary block, fail fast, `--infrastructure-only` aware)
- [x] B2 Guards in `update.sh` and `bootstrap.sh`
- [x] C1 `openwiki/faq.md` + index entry + README pointer
- [x] T1 Update `PLAN.md`, `docs/PROJECT_LAYOUT.md`, the wiki pages named above
- [x] T2 Quick check only: `bash -n` on the touched scripts and
      `bash scripts/tests/hotr-sinden-full-selftest.sh`

## Verification (quick)

- `bash -n` on every touched script.
- `bash scripts/tests/hotr-sinden-full-selftest.sh` (hardware-free, about a minute) — 4 suites pass,
  1 root-only skip.
- Two manual minutes: start the service with a >1 MiB `hotr-sinden-broker.log` and confirm it
  becomes `.old` with a fresh file; run `install.sh` with `unzip` hidden from `PATH` and confirm the
  preflight line names it.
- FAQ: link check only (`unresolved link targets: 0`). No VM run, no deep testing.

## Decisions (this round)

1. **No user features, no fan-out** — feature ideas are dropped for this plan (the user found no
   practical use for fan-out); the work is the log rotation, preflight and FAQ only.
2. **Log rotation: broker handler + service start** — a `RotatingFileHandler` inside the broker
   (1 MiB, one `.old` generation) *and* a service-start rotation of an already-oversized
   `hotr-sinden-broker.log`.
3. **Preflight: fail on required, warn on optional** — hard-fail on missing root/x86_64/python3/
   curl/unzip/tar/tee/md5sum, unwritable `/userdata` or <1 GB free; warn only for rsync,
   `start-stop-daemon`, `setsid`, `batocera-save-overlay`.
4. **FAQ: wiki page + README pointer** — `openwiki/faq.md` with one line in the README Sinden
   section; no README FAQ block.
