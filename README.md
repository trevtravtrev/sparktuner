# sparktuner

Cap the GPU **and** CPU clocks on your NVIDIA DGX Spark (GB10) fleet, keep the caps
across reboots, and verify the result with live numbers — one command, one file, no
dependencies. The CPU-side companion to
[sparkLimiter](https://github.com/MiaAI-Lab/sparkLimiter) (whose GPU job it adopts).

```
$ ./sparktuner.sh
Discovering DGX Sparks (ssh config, known_hosts, mDNS, neighbours)...
Target Sparks (2):
  spark-f301-ts
  spark-bdfd-ts
Apply to [Enter=all, numbers e.g. '1 2', q=quit]:
=== spark-f301-ts ===
ADOPTED sparkLimiter (its unit disabled, file kept)
INSTALLED gpu+cpu units (conf: /etc/sparktuner.conf)
...
Done. OK: 2  Failed: 0
```

## What it does

| Domain | Action | Default |
|---|---|---|
| GPU | `nvidia-smi -lgc MIN,MAX` | `0,2200` MHz |
| CPU P-cores (10× Cortex-X925) | `scaling_max_freq` cap, rediscovered at every boot | `3000` MHz |
| CPU governor (all 20 cores) | `schedutil` (clocks sag at idle) | `schedutil` |
| CPU E-cores (10× Cortex-A725) | **never touched** | — |
| Fans / firmware | **never touched** | — |

`auto_select` is deliberately not written: on DGX OS 7.2.3 / kernel 7.0 caps are
honored without it (verified live: requested 3000000 kHz, delivered 2987384 kHz).

## Why 3000 / 2200

Measured receipts (full table: see the research thread
[t/387929](https://forums.developer.nvidia.com/t/lets-optimize-dgx-spark/387929),
[t/383939](https://forums.developer.nvidia.com/t/7-0-0-1019-nvidia-cpu-overheating/383939/2)):

- X925 @3000: hottest zone **84 → 67 °C**, identical benchmark scores and wall
  time, 8–12 % less energy (2026-11-03, 2× GB10, agentic sweep)
- X925 @2600: zone0 **86 → 56 °C** during decode, flat tok/s across 2600–3600
- All-core @2400: **92 → 84 °C**, "zero performance cost", stopped hard locks
- GPU 2200 sits just under the ~2197 MHz thermal-throttle floor seen on hot units

Below 2808 MHz (the E-core max) the scheduler can migrate hot threads to E-cores
(0–4.5 % cost, workload-dependent) — sparktuner warns and requires `--force`.

## Usage

```bash
./sparktuner.sh                     # discover → confirm → apply → done
./sparktuner.sh -n                  # list Sparks only
./sparktuner.sh --dry-run           # show the exact plan, write nothing
./sparktuner.sh --verify            # read-only PASS/FAIL report (no sudo)
./sparktuner.sh --gpu 0,2100 --cpu-p 2808
./sparktuner.sh --uninstall         # restore stock clocks + governor, remove units
```

`--verify` re-checks every number on every host: GPU SM clock vs cap, each P-policy's
`scaling_max_freq` vs target, **delivered** `cpuinfo_avg_freq` under a 5-second load
(the metric NVIDIA recommends), E-cores untouched, governor in place, units
enabled+active, hottest thermal zone. Any FAIL line → non-zero exit.

## Reboot persistence

Both caps live in enabled systemd oneshots (`WantedBy=multi-user.target`,
`Restart=on-failure`, no start-limit window) that re-apply at every boot; the CPU
helper re-discovers which policies are P-cores at run time, so kernel updates that
renumber cores can't misfire onto E-cores. Units live in `/etc/systemd/system/`
(admin space), which DGX OS OTA updates don't overwrite. After any DGX OS update,
run `./sparktuner.sh --verify` (30 seconds, read-only).

## sparkLimiter users

If `spark-gpu-clock-limit.service` is enabled on a host, sparktuner **disables it**
(same value, its own unit takes over — one owner per job, file kept). `--uninstall`
prints the one-liner to re-enable sparkLimiter.

## Requirements

DGX Spark (GB10) with DGX OS + systemd + NVIDIA driver; key-based ssh from the
machine you run it on; sudo on each Spark (password prompts fine — it goes over
`ssh -t`). Linux or macOS on the controller.

## Credits & license

- Discovery pattern adapted from [MiaAI-Lab/sparkLimiter](https://github.com/MiaAI-Lab/sparkLimiter) (MIT)
- CPU-cap recipe + receipts: jetspark ([t/387929](https://forums.developer.nvidia.com/t/lets-optimize-dgx-spark/387929)),
  see_spot_ruminate ([t/383939](https://forums.developer.nvidia.com/t/7-0-0-1019-nvidia-cpu-overheating/383939/2))
- Verification methodology: NVIDIA ([t/367604](https://forums.developer.nvidia.com/t/how-to-fix-cpu-frequency-in-dgx-spark/367604))

MIT — see [LICENSE](LICENSE). No warranty; this writes clock limits and a governor,
not firmware. `--uninstall` returns the box to stock.
