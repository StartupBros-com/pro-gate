# Pass 9/10 — PRODUCTIVE-MEASUREMENT

**Verdict:** PRODUCTIVE-MEASUREMENT. The completed, no-rerun profile passed all eight commands and
records a current 1,385.52s serial wall time. This pass creates a comparable evidence card and
prioritizes exact observed labels; it changes no source, test, workflow, production, prior-artifact,
or progress file.

## Human baseline card

| Field | Current capture |
| --- | --- |
| Status | passed; all 8 command exit statuses are zero |
| Capture interval | 2026-09-01T12:47:56Z to 2026-09-01T13:11:02Z |
| Source revision | `e71d1a2ad7c3df3b0cb140b36f41dac1dc52d25e` |
| Serial wall / CPU | **1,385.52s** / **84.47s** (6.10% CPU-to-wall) |
| Engine result | 825 internal `ok -` checks, zero `not ok`, `ALL PASS` |
| Node result | 298 internal `ok -` checks; node:test 1 pass, 0 fail |
| Other shell results | distribution 133, daemon 74, browser 17, autoupdate 35, release train 58, release assets 23; every suite `ALL PASS` |
| Local fingerprint | Ubuntu 24.04.4 on WSL2, 28 CPUs, Node v24.12.0, Bash 5.2.21, jq 1.8.1, ShellCheck 0.11.0 |
| Preflight | no CI or `PRO_GATE_*` environment names captured; 15 Chrome processes already existed before profiling |

The compact, machine-readable record is `PASS-9-current-profile.json`. Its capture references
name files relative to an explicitly ephemeral capture location rather than retaining scratch paths.

## Ranked top five by current wall time

| Rank | Command | Wall | Share of 1,385.52s | Current evidence |
| ---: | --- | ---: | ---: | --- |
| 1 | `bash tests/engine.test.sh` | **1,143.22s** | 82.51% | 825 checks, `ALL PASS`; 1,137.149s of output-gap time |
| 2 | `node --test tests/cdp-salvage.test.mjs` | **151.09s** | 10.90% | 298 checks; node:test 1/0 pass/fail; 150.735s output-gap time |
| 3 | `bash tests/distribution.test.sh` | **58.79s** | 4.24% | 133 checks, `ALL PASS` |
| 4 | `bash tests/daemon-reload.test.sh` | **14.44s** | 1.04% | 74 checks, `ALL PASS` |
| 5 | `bash tests/browser-launch.test.sh` | **11.06s** | 0.80% | 17 checks, `ALL PASS` |

The five commands account for 1,378.60s (99.50%) of this serial capture. Engine and CDP salvage
therefore remain the only classes that can materially move the end-to-end result.

## Original CI baseline versus current local capture

The original summary is a 20-sample GitHub-hosted `ubuntu-24.04` service-level baseline; this is
one WSL2 local serial capture. GitHub runners are ephemeral, and this local capture began with 15
Chrome processes already present. These deltas are directional evidence, not a runner-equivalent A/B
claim.

| Command | Original mean | Current | Current − original | Directional delta |
| --- | ---: | ---: | ---: | ---: |
| engine | 1,560.969s | 1,143.22s | -417.749s | -26.76% |
| daemon reload | 15.000s | 14.44s | -0.560s | -3.73% |
| autoupdate | 3.063s | 6.23s | +3.167s | +103.39% |
| browser launch | 10.950s | 11.06s | +0.110s | +1.00% |
| CDP salvage | 391.626s | 151.09s | -240.536s | -61.42% |
| distribution | 15.235s | 58.79s | +43.555s | +285.88% |
| release train | 0.981s | 0.55s | -0.431s | -43.93% |
| release assets | 0.240s | 0.14s | -0.100s | -41.67% |
| **CI “Run tests” mean / current serial** | **1,990.400s** | **1,385.52s** | **-604.880s** | **-30.39%** |

The two large apparent regressions are not treated as regressions until reproduced on a comparable
runner. The current distribution timeline contains intentional doctor and hard-kill cases, while the
local pre-existing browser state differs from a clean hosted runner.

## Wait and CPU caveats

- `/usr/bin/time` CPU is only 84.47s, or 6.10% of serial wall time. Engine (4.88% CPU-to-wall) and
  CDP salvage (6.13%) are predominantly blocked or elapsed-time work in this run.
- An output gap is elapsed time between terminal-output events. It can contain deliberate fixture
  deadlines, polling, child-process work, I/O, scheduler delay, or buffered output; it is **not**
  proof of a removable `sleep`.
- Distribution is materially more CPU-active (26.54% CPU-to-wall), so its 58.79s cannot be assigned
  solely to waits. Browser launch is nearly wait-dominated (0.45%), but it is only 0.80% of total wall.
- Pass 8 already rejected indirect generic PATH/process wrappers for engine fixture waits. This pass
  does not reopen that rejected design merely because elapsed gaps remain.

## Hypothesis ledger

| ID | Hypothesis | Evidence in this capture | Status and next safe measurement |
| --- | --- | --- | --- |
| H1 | Engine’s largest gaps are fixture deadline/lifecycle waits. | Top five engine output gaps are 53.481s, 48.728s, 45.156s, 42.986s, and 41.706s; engine CPU-to-wall is 4.88%. | Plausible, not causal. Instrument only fixture-owned transitions; do not use generic command interception. |
| H2 | CDP salvage retains a small set of long classified transitions. | Its top labelled gaps are 10.020s (owned VERDICT), 7.573s (foreign-tab to owned match), and 5.102s (later outage). | Supported. Preserve the pass-7 deadline classification and record state transitions before considering any new bound. |
| H3 | Distribution’s added wall is intentional negative-path safety coverage. | The timeline includes a 7.001s `TERM-ignoring gh is hard-killed within the bounded window` case plus repeated doctor contract checks. | Supported for the named hard-kill case; cross-run comparison is not valid here. |
| H4 | Daemon reload has deterministic lifecycle observation windows. | `reloaded exactly once (no reload-loop; identical stamp is inert)` follows a 4.007s window; `self-reload=0 does not detect/reload` follows 3.728s. | Plausible. A later change needs a fixture-owned event and must retain reload-loop and disabled-reload proof. |
| H5 | Browser launch time is intentional readiness/cleanup coverage. | 2.006s TERM preflight, 2.009s failed-Xvfb, 3.011s CDP readiness, and 4.011s post-close liveness windows; only 0.05 CPU seconds. | Supported, but too small and safety-sensitive for current implementation work. |

## Opportunity matrix

Score = `Impact × Confidence / Effort`, with each input scored 1–5. A score is an evidence-priority
signal, not a permission to weaken a timeout. Only scores at or above 2.0 are eligible for a later
design; no implementation is made or approved in this measurement pass.

| Rank | Area | Exact current label / transition | Observed gap | Impact | Confidence | Effort | Score | Disposition |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | Node | `probe reports complete once an owned VERDICT is present` → `foreign VERDICT never reports complete for our marker` | 10.020s | 4 | 4 | 3 | **5.33** | Later design candidate; retain marker ownership proof. |
| 2 | Engine | `symlinked transcript fails closed` → `intact log capture still refunds the pre-browser failure` | 53.481s | 5 | 4 | 4 | **5.00** | Later fixture-transition design candidate; no generic wrapper. |
| 3 | Engine | `early URL capture + change manifest on a fresh run` → `early-capture run preserves as in-progress (exit 9)` | 48.728s | 5 | 4 | 4 | **5.00** | Later fixture-transition design candidate; retain exit-9 state evidence. |
| 4 | Engine | `watchdog-killed stall after lifecycle never announces a refund` → `hard-cap timeout kill exits 6` | 45.156s | 5 | 4 | 5 | **4.00** | Later safety-bound study only; kill/refund ordering is load-bearing. |
| 5 | Node | `foreign tab left open` → `probe exits 0 on match` | 7.573s | 4 | 3 | 3 | **4.00** | Later design candidate; preserve foreign-tab non-selection. |
| 6 | Engine | `provably-never-landed submission refunds its round` → `never-landed run fails (exit 6)` | 42.986s | 5 | 3 | 5 | **3.00** | Later study; retain refund and failure distinction. |
| 7 | Engine | `refund is named in the status detail` → `landed-but-lost run fails (exit 6)` | 41.706s | 5 | 3 | 5 | **3.00** | Later study; retain lost-run failure semantics. |
| 8 | Node | `review is found regardless of order` → `later CDP outage is not masked by an early successful scan` | 5.102s | 3 | 4 | 4 | **3.00** | Later design candidate; retain success-before-outage ordering. |
| 9 | Daemon | `daemon re-started after reload` → `reloaded exactly once (no reload-loop; identical stamp is inert)` | 4.007s | 2 | 4 | 3 | **2.67** | Eligible only for a fixture-owned reload-loop event design. |
| 10 | Distribution | `TERM-ignoring gh is hard-killed within the bounded window` | 7.001s | 2 | 5 | 5 | **2.00** | Eligible only if the TERM/KILL upper-bound proof remains intact. |
| 11 | Daemon | `self-reload disabled` → `self-reload=0 does not detect/reload` | 3.728s | 2 | 3 | 3 | **2.00** | Eligible only for deterministic disabled-reload observation. |
| — | Distribution | `doctor blocks unknown contract before dispatch` | 4.496s | 2 | 3 | 4 | 1.50 | Do not recommend implementation below 2.0. |
| — | Browser | `Chrome remains alive after Oracle closes the last target` | 4.011s | 1 | 5 | 3 | 1.67 | Do not recommend implementation below 2.0. |
| — | Browser | `missing CDP readiness fails startup` | 3.011s | 1 | 5 | 4 | 1.25 | Do not recommend implementation below 2.0. |

## Scope integrity and follow-up

- The measurement phase ran each exact CI test command once and completed successfully; the recovery/synthesis phase **reran no tests** and read only those completed captures.
- Capture-manifest SHA-256 validation passed for all 32 captured stdout, stderr, time, and timeline
  files. Input and artifact checksums are recorded in `PASS-9-checksums.txt`.
- `git diff --check` passed. The source, test, and workflow path diff check was empty; Pass 9 writes
  only its four new artifacts in this directory and does not stage or commit anything.

Next concrete action: use the score-5.33 to score-3.00 engine/CDP items as fixture-owned transition
instrumentation designs before any implementation; retain the score-2.00 safety candidates as
conditional follow-ups only.
