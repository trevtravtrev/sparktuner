# sparktuner — SPEC (v1.0-draft)

One-file bash tool that caps GPU + CPU-P-core clocks on NVIDIA DGX Spark (GB10)
fleet-wide, persists across reboots, and verifies itself with live numbers.

Approved design 2026-11-12. Amendment: **no fan domain — no fan control, no fan
telemetry, no fan code.** Tool domains = GPU + CPU + verify.

## 1. Context (verified on the two target hosts)

| Fact | Value (both hosts identical) |
|---|---|
| Hosts | spark-f301 (192.168.86.196), spark-bdfd (192.168.86.28), user trevtravtrev, key auth works |
| OS / kernel | DGX OS 7.2.3, `7.0.0-1025-nvidia`, SecureBoot on |
| GPU | GB10; `clocks.max.sm`=3003; sparkLimiter unit `spark-gpu-clock-limit.service` enabled+active, `-lgc 0,2200` holding (SM 2190) |
| CPU | cppc_cpufreq; P-cores = policies 5-9,15-19 (`cpuinfo_max_freq` 3900000); E-cores = 0-4,10-14 (2808000); all governor `performance`; `scaling_min_freq` 1378000; `auto_select`, `scaling_setspeed`, `cpuinfo_avg_freq` present |
| Fan | EC 3.13.7 (`0x03000d07`): stock ACPI cooling-device writes accepted but ignored (verified 2026-11-12: RPM 2012→2009→2010 at state 60). OUT OF SCOPE. |
| Sudo | password required; tool reaches hosts via `ssh -t` |
| Proven on-host | `scaling_max_freq=3000000` → delivered `cpuinfo_avg_freq=2987384` under affinitized load; E-policies untouched; restore clean |

## 2. Goals / Non-goals

**Goals:** single `sparktuner.sh` (bash, no deps); discovers Sparks like sparkLimiter
(credit MIT); applies GPU cap (`nvidia-smi -lgc`) + P-core cap (`scaling_max_freq`) +
**CPU governor `schedutil` on all 20 cores** (idle temps; sysfs write, not the broken
cpupower); persists via systemd oneshots + `/etc/sparktuner.conf`; `--verify` prints
PASS/FAIL live numbers; `--uninstall` restores stock; safe (dry-run, validation, no
firmware).

**Non-goals:** anything fan-related; E-core capping; `auto_select` writes (proven
unnecessary on kernel 7.0); power caps (PL/SPBM); EC/firmware changes; daemon/curves
(static caps + governor only).

## 3. CLI contract

```
./sparktuner.sh                    # wizard: discover -> show state -> apply defaults -> verify
./sparktuner.sh host [host...]     # skip discovery
./sparktuner.sh -n [host...]       # list Sparks only, change nothing
./sparktuner.sh --verify [host..]  # read-only report, no writes, no sudo
./sparktuner.sh --gpu 0,2200 --cpu-p 3000 [host..]
./sparktuner.sh --dry-run ...      # show plan per host, write nothing
./sparktuner.sh --uninstall [host..]
./sparktuner.sh -y                 # no prompts
```

Defaults: `--gpu 0,2200` `--cpu-p 3000`. Exit codes: 0 ok; 1 any host action/verify
failed; 2 usage/validation error. Uninstall removes both units + conf and restores
stock clocks (GPU `-rgc`, P-policies → `cpuinfo_max_freq`).

## 4. Discovery (adapted from sparkLimiter, MIT, credited in README)

Sources: localhost probe, `~/.ssh/config` entries, unhashed LAN-looking
`known_hosts`, mDNS `_ssh._tcp` addresses (if avahi present), ARP/neighbour table;
optional `-s` /24 sweep. A host is a Spark iff key-ssh works and `nvidia-smi
--query-gpu=name` / DMI product matches `GB10|DGX[ _-]?Spark`. Dedupe by
`machine-id:hostname`; prefer named targets over bare IPs. Probes read-only,
BatchMode, no password, skip host-key checks; apply-phase uses normal ssh.

## 5. Per-host install contract

Files written (one privileged payload per host per run, via `ssh -t`, sudo prompts
on the host tty; localhost runs directly):

1. `/etc/sparktuner.conf` — shell-sourceable, `GPU_CLOCKS="0,2200"`,
   `CPU_P_MAX_MHZ="3000"`. Written first; units read it.
2. `/etc/systemd/system/sparktuner-gpu-cap.service` — oneshot,
   `RemainAfterExit=yes`, `After=nvidia-persistenced.service`, `Wants=` same;
   `ExecStart=/usr/bin/nvidia-smi -lgc ${GPU_CLOCKS}`, `ExecStop=-/usr/bin/nvidia-smi -rgc`,
   `Restart=on-failure`. Enable+start.
   **Adoption:** if `spark-gpu-clock-limit.service` exists and is enabled, disable it
   (leave the file), print notice. If GPU domain skipped by user, no adoption.
3. `/etc/systemd/system/sparktuner-cpu-cap.service` — oneshot,
   `RemainAfterExit=yes`, `After=nv-cpu-governor.service` (harmless where that
   service fails, as on 7.0.0-1025); `ExecStart=/usr/libexec/sparktuner-cpu-apply`
   helper installed alongside (see §6); `ExecStop=` restore helper; enable+start.

Install order: apply GPU cap first (fails → skip host, like sparkLimiter), then
CPU helper + unit. Any step failing on a host marks the host failed; partial
installs are recorded in the summary and are safe to re-run (idempotent).

### Persistence guarantees (reboots & updates)

- Both units: `WantedBy=multi-user.target`, enabled → **re-apply at every boot**
  (`-lgc` and sysfs caps never survive reboot on their own; the units are the
  persistence mechanism — the proven sparkLimiter pattern, running on both target
  hosts since before this tool existed).
- `Restart=on-failure` + `StartLimitIntervalSec=0` retry window covers boot-order
  races (nvidia-persistenced not yet up).
- Units live in `/etc/systemd/system/` (admin space) — DGX OS OTA updates don't
  overwrite them; `nv-cpu-governor` ordering (`After=`) covers hosts where that
  service still works; on the target kernel it fails harmlessly before us.
- CPU helper **rediscovers P-policies at every run** — a kernel/DGX update that
  changes CPU numbering can't silently retarget the wrong cores.
- Acceptance (§9): an actual reboot of one Spark with `--verify` all-PASS after
  is required before the release is called done. README advises re-running
  `--verify` after any DGX OS/OTA update (30 seconds, read-only).

## 6. CPU-P cap mechanics (the proven path)

Policy discovery (no hardcoded cpu numbers):
```
P_POLICIES = policies where cpuinfo_max_freq > 3000000   (i.e. 3900000 set)
E_POLICIES = the rest — NEVER touched
```
Apply per policy: if `scaling_min_freq > target`, first write `cpuinfo_min_freq`
to `scaling_min_freq` (guard; not needed on kernel 7.0 but defensive), then write
`scaling_max_freq = target*1000`.

Helper script `/usr/libexec/sparktuner/cpu-apply` (installed by the tool):
sources `/etc/sparktuner.conf`, rediscovers P-policies at run time (never trusts
cached cpu numbers — survives topology/kernel changes), saves originals to
`/var/lib/sparktuner/orig.conf` before first write, applies per above. A sibling
`cpu-restore` reads the originals and reverses. Both are plain bash, shellcheck-clean.

Validation: integer MHz, `1378 ≤ cpu-p ≤ 3900`. If `cpu-p < 2808` (E-core max):
warn "below 2808 can shift hot threads to E-cores (0–4.5% cost, receipts vary)"
and require `--force` (or interactive y/N) to proceed.

Restore (uninstall / ExecStop): `scaling_max_freq = cpuinfo_max_freq`;
`scaling_min_freq` back to its pre-apply value if we changed it (helper persists
originals in `/var/lib/sparktuner/orig.conf`).

## 7. `--verify` contract (the "verify all numbers" requirement)

Runs unprivileged (all reads world-readable). Per host, one line per check with
PASS/FAIL, plus a 5-second affinitized busy load on one P-core (nice +10) to get
delivered frequency:

```
host: spark-f301 (DGX Spark, 7.0.0-1025-nvidia)
  GPU  unit enabled=active sm_clock_now=2190≤2200   PASS   (unit state is the lock's
                                                            proof; idle SM may sit below
                                                            cap — a missing lock shows up
                                                            under any load as sm > cap)
  CPU  policy5  smax=3000000 target=3000000         PASS
  ... (one line per P policy)
  CPU  policy17 delivered avg=2987384 under load    PASS   (within 5% of target)
  CPU  policy0 (E) smax=2808000 untouched           PASS   (must equal cpuinfo_max)
  TEMP hottest_zone=41C trip=104C                   info
  sparktuner.conf values match flags                PASS
```

FAIL examples: smax≠target; delivered avg < 95% of target; E-policy modified;
unit disabled/inactive. Exit 1 if any FAIL on any host. `TEMP` line is zone
telemetry only (informational; the tool never acts on temps).

## 8. Safety requirements

- Never writes EC/firmware/BIOS; never touches E-policies; never stores passwords;
  `--dry-run` prints the exact per-host plan (files + values) and writes nothing.
- Hostname validation before ssh (no option injection), `--` separator, like sparkLimiter.
- Re-runnable; uninstall returns to stock; adoption of sparkLimiter is reversible
  (uninstall prints the one-line `systemctl enable --now spark-gpu-clock-limit` hint).
- Value sanity: GPU max ≤ 3003 MHz (warn above), cpu-p bounds per §6.

## 9. Test plan

1. **Static:** `shellcheck` + `bash -n` clean; CI on GitHub Actions (ubuntu, bash).
2. **Unit (host-runnable, no Spark needed):** arg parsing matrix; GPU-clock string
   validation; policy-set derivation from fixture dirs (fake sysfs tree);
   unit-file generation from templates (golden files); adoption logic given mock
   `systemctl` shims; verify-report PASS/FAIL logic against fixture trees.
   Harness: plain bash test runner (`tests/run.sh`, no bats dependency).
3. **E2E live (acceptance, both Sparks, after user runs install):**
   - `sparktuner.sh -n` finds both hosts by name from ssh config.
   - install with defaults; both units `enabled+active`; sparkLimiter unit disabled;
   - `--verify`: every line PASS; delivered avg within 5% of 3000000; SM ≤ 2200;
   - reboot one Spark → `--verify` all PASS again (persistence proof);
   - `--uninstall` → P-policies at 3900000, GPU `-rgc` (SM can boost), units gone,
     conf gone, sparkLimiter re-enable hint printed;
   - re-install to leave the fleet in the desired state (defaults), final verify PASS.

## 10. Repo / license

`github.com/trevtravtrev/sparktuner`, public, MIT. README: usage, receipts table
(sources from research report), credits: MiaAI-Lab/sparkLimiter (discovery pattern),
jetspark/t/387929 + t/383939#2 (CPU-cap recipe + numbers), NVIDIA t/367604
(verification methodology). Files: `sparktuner.sh`, `LICENSE`, `README.md`,
`tests/`, `.github/workflows/ci.yml`, `SPEC.md`, `.gitattributes` (`* text=auto eol=lf` —
repo is authored on Windows; the script and units must stay LF for the Sparks).

## 11. Out-of-scope notes for the future

If NVIDIA's EC firmware ever restores a working fan path, fan-floor support would
enter as domain #3 behind the same capability-probe pattern (probe → only act if
RPM actually responds). Deliberately omitted now per owner decision 2026-11-12.
