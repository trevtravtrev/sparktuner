# sparktuner v1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `sparktuner.sh` — a single-file bash tool that caps GPU (nvidia-smi -lgc) + CPU P-core (scaling_max_freq) clocks on DGX Spark fleets, persists across reboots via systemd, and self-verifies with live PASS/FAIL numbers.

**Architecture:** One main script holding all logic as testable functions (sourced-under-test via `SPARKTUNER_LIB=1`); install payloads (helpers/units/conf) are emitted as heredocs and shipped per-host over `ssh -t` with one privileged `sudo bash` invocation, copying sparkLimiter's proven pattern. All sysfs/systemctl access flows through overridable variables so unit tests run against fixture trees.

**Tech Stack:** Bash ≥4, plain-bash test harness (no bats), ShellCheck, GitHub Actions. Zero runtime dependencies beyond ssh + systemd + nvidia-smi on targets.

**Spec:** `SPEC.md` (repo root, travels with this plan).

## Global Constraints

- Single distributable file `sparktuner.sh`; helpers/units/conf are embedded heredocs written at install time. Exact paths from SPEC §5: `/etc/sparktuner.conf`, `/etc/systemd/system/sparktuner-gpu-cap.service`, `/etc/systemd/system/sparktuner-cpu-cap.service`, `/usr/libexec/sparktuner/cpu-apply`, `/usr/libexec/sparktuner/cpu-restore`, originals in `/var/lib/sparktuner/orig.conf`.
- NEVER write any policy whose `cpuinfo_max_freq` ≤ 3000000 (E-cores). No fan code, no firmware writes, no E-core capping, no passwords stored (SPEC §2, §8).
- Exit codes: 0 ok, 1 host action/verify failure, 2 usage/validation (SPEC §3).
- Defaults `GPU_CLOCKS="0,2200"`, `CPU_P_MAX_MHZ=3000`; cpu-p valid range 1378–3900; `< 2808` requires `--force` or interactive confirm (SPEC §6).
- Units: `WantedBy=multi-user.target`, `RemainAfterExit=yes`, `Restart=on-failure`, `StartLimitIntervalSec=0`; CPU unit `After=nv-cpu-governor.service`; GPU unit `After=/Wants=nvidia-persistenced.service` (SPEC §5 + persistence block).
- ShellCheck clean; all repo files LF (`.gitattributes`: `* text=auto eol=lf`); MIT; credits per SPEC §10.
- Tests run on any Linux/WSL box with bash — never require a real Spark; live E2E is Task 9.

---

### Task 1: Scaffold + CLI parsing + validation

**Files:**
- Create: `sparktuner.sh`, `tests/run.sh`, `tests/test_args.sh`, `LICENSE`, `.gitattributes`
- Modify: none

**Interfaces:**
- Produces: `usage()`, `log()`, `die()`, `parse_args()` (sets globals), `validate_settings()`; globals `GPU_CLOCKS CPU_P_MAX_MHZ FORCE LIST_ONLY VERIFY_ONLY UNINSTALL DRY_RUN YES SCAN SSH_USER HOSTS`; entry-guard `main "$@"` unless `SPARKTUNER_LIB=1`.

- [ ] **Step 1: Write failing tests** — `tests/run.sh` (harness) and `tests/test_args.sh`:

```bash
# tests/run.sh — plain harness, no deps. Usage: tests/run.sh
#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
t_assert() { # t_assert DESC EXPECTED_ACTUAL_COMMAND...
  local desc=$1; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   - $desc"
  else FAIL=$((FAIL+1)); echo "FAIL - $desc"; fi
}
t_eq() { # t_eq DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1 (expected [$2] got [$3])"; fi
}
for t in "$ROOT"/tests/test_*.sh; do
  # shellcheck disable=SC1090
  ( set -e; SPARKTUNER_LIB=1 . "$ROOT/sparktuner.sh"; . "$t" )
done
echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
```

```bash
# tests/test_args.sh
T() { # T "args string" -> resets globals, runs parse_args + validate_settings
  GPU_CLOCKS="0,2200"; CPU_P_MAX_MHZ=3000; FORCE=0; LIST_ONLY=0; VERIFY_ONLY=0
  UNINSTALL=0; DRY_RUN=0; YES=0; SCAN=0; SSH_USER=""; HOSTS=()
  parse_args $1 && validate_settings
}
t_assert "defaults valid"                      T ""
t_assert "--gpu 0,2000 accepted"               T "--gpu 0,2000"
t_assert "bad gpu range rejected"            ! T "--gpu 5000,2000"
t_assert "gpu max over 3003 rejected"        ! T "--gpu 0,3200"
t_assert "cpu-p 2808 accepted"                 T "--cpu-p 2808"
t_assert "cpu-p 1000 rejected (below floor)" ! T "--cpu-p 1000"
t_assert "cpu-p 4000 rejected (above max)"   ! T "--cpu-p 4000"
t_assert "cpu-p 2600 without force rejected" ! T "--cpu-p 2600"
T "--cpu-p 2600 --force" >/dev/null && t_eq "cpu-p 2600 with --force ok" 2600 "$CPU_P_MAX_MHZ"
T "--gpu 0,1800 --cpu-p 2800 hostA hostB" >/dev/null
t_eq "hosts collected" "hostA hostB" "${HOSTS[*]}"
t_assert "unknown flag rejected"             ! T "--wat"
T "-n" >/dev/null;   t_eq "-n sets LIST_ONLY" 1 "$LIST_ONLY"
T "--verify" >/dev/null; t_eq "--verify sets flag" 1 "$VERIFY_ONLY"
T "-u" >/dev/null;   t_eq "-u sets UNINSTALL" 1 "$UNINSTALL"
T "--dry-run" >/dev/null; t_eq "--dry-run sets flag" 1 "$DRY_RUN"
```

- [ ] **Step 2: Run to verify failure** — `bash tests/run.sh` → FAIL ("sparktuner.sh: No such file or directory" / parse_args undefined).

- [ ] **Step 3: Implement** — create `sparktuner.sh`:

```bash
#!/usr/bin/env bash
# sparktuner — cap GPU + CPU P-core clocks on NVIDIA DGX Spark (GB10) fleets,
# persist across reboots, and verify with live numbers. See SPEC.md.
# Discovery pattern adapted from MiaAI-Lab/sparkLimiter (MIT). MIT licensed.
set -u
set -f   # host lists come from files and the network; never glob-expand them

VERSION="1.0.0"
GPU_CLOCKS="0,2200"
CPU_P_MAX_MHZ=3000"
FORCE=0; LIST_ONLY=0; VERIFY_ONLY=0; UNINSTALL=0; DRY_RUN=0; YES=0; SCAN=0; SSH_USER=""
HOSTS=()

SERVICE_GPU="sparktuner-gpu-cap"; SERVICE_CPU="sparktuner-cpu-cap"
CONF_FILE="/etc/sparktuner.conf"; ORIG_FILE="/var/lib/sparktuner/orig.conf"
LIBEXEC_DIR="/usr/libexec/sparktuner"; NVSMI=/usr/bin/nvidia-smi

log() { printf '%s\n' "$*" >&2; }
die() { log "sparktuner: $*"; exit 2; }

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

validate_settings() {
  local max
  [[ "$GPU_CLOCKS" =~ ^[0-9]{1,5},[0-9]{1,5}$ ]] || die "invalid --gpu '$GPU_CLOCKS' (want MIN,MAX MHz, e.g. 0,2200)"
  [ "${GPU_CLOCKS%,*}" -le "${GPU_CLOCKS#*,}" ] || die "invalid --gpu '$GPU_CLOCKS' (MIN > MAX)"
  max=${GPU_CLOCKS#*,}; [ "$max" -le 3003 ] || die "--gpu MAX $max above GB10 hardware max 3003"
  [[ "$CPU_P_MAX_MHZ" =~ ^[0-9]+$ ]] || die "invalid --cpu-p '$CPU_P_MAX_MHZ'"
  [ "$CPU_P_MAX_MHZ" -ge 1378 ] && [ "$CPU_P_MAX_MHZ" -le 3900 ] \
    || die "--cpu-p must be 1378..3900 MHz"
  if [ "$CPU_P_MAX_MHZ" -lt 2808 ] && [ "$FORCE" -eq 0 ] && [ "$UNINSTALL" -eq 0 ]; then
    die "--cpu-p below 2808 (E-core max) can shift hot threads to E-cores; pass --force to override"
  fi
  [ -n "$SSH_USER" ] && ! [[ "$SSH_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && die "invalid --user '$SSH_USER'"
  return 0
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --gpu)     GPU_CLOCKS="${2:?}"; shift 2 ;;
      --cpu-p)   CPU_P_MAX_MHZ="${2:?}"; shift 2 ;;
      -f|--force) FORCE=1; shift ;;
      -n|--list) LIST_ONLY=1; shift ;;
      --verify)  VERIFY_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -u|--uninstall) UNINSTALL=1; shift ;;
      -y|--yes)  YES=1; shift ;;
      -s|--scan) SCAN=1; shift ;;
      -l|--user) SSH_USER="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) echo "sparktuner $VERSION"; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do HOSTS+=("$1"); shift; done ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *)  HOSTS+=("$1"); shift ;;
    esac
  done
  return 0
}
# (main and remaining functions arrive in later tasks)
if [ "${SPARKTUNER_LIB:-0}" != "1" ]; then main "$@"; fi
```

Also create `LICENSE` (MIT, Copyright (c) 2026 trevtravtrev) and `.gitattributes` (`* text=auto eol=lf`).

- [ ] **Step 4: Run tests** — `bash tests/run.sh` → `passed=17 failed=0` (count may grow with later tasks).

---

### Task 2: Policy discovery against fixture sysfs

**Files:**
- Create: `tests/test_policies.sh`, fixture generator `tests/fixtures/make_sysfs.sh`, generated `tests/fixtures/sysfs/` (gitignored? No — commit it; deterministic)
- Modify: `sparktuner.sh` (add functions before the entry-guard)

**Interfaces:**
- Consumes: none.
- Produces: `discover_policies ROOT` → prints policy names (`policy5`) whose `cpuinfo_max_freq` > 3000000; `discover_e_policies ROOT` → the rest. `P_THRESHOLD_KHZ=3000000` constant.

- [ ] **Step 1: Failing test** — `tests/fixtures/make_sysfs.sh` builds a fake tree; `tests/test_policies.sh`:

```bash
# tests/fixtures/make_sysfs.sh — builds $1 (fake cpufreq tree; idempotent)
#!/usr/bin/env bash
set -eu
ROOT=$1; rm -rf "$ROOT"; mkdir -p "$ROOT"
mk() { # mk NAME MAXFREQ [MINFREQ]
  local d=$ROOT/$1 max=$2 min=${3:-$((1378*1000))}
  mkdir -p "$d"
  printf '%s' "$max" > "$d/cpuinfo_max_freq"
  printf '%s' "$min" > "$d/cpuinfo_min_freq"
  printf '%s' "$max" > "$d/scaling_max_freq"
  printf '%s' "$min" > "$d/scaling_min_freq"
  printf '%s' "$max" > "$d/scaling_cur_freq"
  printf '%s' "$((max/2))" > "$d/cpuinfo_avg_freq"
  printf 'performance' > "$d/scaling_governor"
  printf '5 6 7' > "$d/affected_cpus"
}
for e in 0 1 2 3 4 10 11 12 13 14; do mk "policy$e" 2808000; done
for p in 5 6 7 8 9 15 16 17 18 19; do mk "policy$p" 3900000; done
```

```bash
# tests/test_policies.sh
FX=$ROOT/tests/fixtures/sysfs
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
t_eq "P policies found" "policy15 policy16 policy17 policy18 policy19 policy5 policy6 policy7 policy8 policy9" "$(discover_policies "$FX" | sort | tr '\n' ' ' | sed 's/ $//')"
t_eq "E policies found" "policy0 policy1 policy10 policy11 policy12 policy13 policy14 policy2 policy3 policy4" "$(discover_e_policies "$FX" | sort | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$FX2/policyX" 2>/dev/null; FX2=$ROOT/tests/fixtures/sysfs_broken
rm -rf "$FX2"; mkdir -p "$FX2/policy9"   # max freq file missing
t_eq "broken policy skipped by P" "" "$(discover_policies "$FX2")"
t_eq "broken policy skipped by E" "" "$(discover_e_policies "$FX2")"
```

- [ ] **Step 2: Run** — `bash tests/run.sh` → new cases FAIL (`discover_policies: command not found`).
- [ ] **Step 3: Implement** (insert into `sparktuner.sh`):

```bash
P_THRESHOLD_KHZ=3000000
discover_policies() { # ROOT -> P-core policy names on stdout
  local p max
  for p in "$1"/policy*; do
    [ -r "$p/cpuinfo_max_freq" ] || continue
    max=$(cat "$p/cpuinfo_max_freq")
    [ "$max" -gt "$P_THRESHOLD_KHZ" ] && printf '%s\n' "${p##*/}"
  done; return 0
}
discover_e_policies() { # ROOT -> E-core policy names on stdout (never written)
  local p max
  for p in "$1"/policy*; do
    [ -r "$p/cpuinfo_max_freq" ] || continue
    max=$(cat "$p/cpuinfo_max_freq")
    [ "$max" -le "$P_THRESHOLD_KHZ" ] && printf '%s\n' "${p##*/}"
  done; return 0
}
```

- [ ] **Step 4: Run** — all PASS.

---

### Task 3: cpu-apply / cpu-restore helper emission + semantics

**Files:**
- Create: `tests/test_cpu_helpers.sh`
- Modify: `sparktuner.sh`

**Interfaces:**
- Consumes: Task 1 globals.
- Produces: `emit_cpu_apply` / `emit_cpu_restore` (print scripts to stdout). Emitted scripts honor env `CPU_SYSFS` (default `/sys/devices/system/cpu/cpufreq`), `CONF_FILE` (default `/etc/sparktuner.conf`), `ORIG_FILE` (default `/var/lib/sparktuner/orig.conf`), `CPU_P_MAX_MHZ` (default 3000; conf file overrides env default). Apply exits non-zero if 0 P-policies found. Orig format: `policyNAME scaling_min_freq_orig cpuinfo_max_freq_orig` per line, mode 600.

- [ ] **Step 1: Failing test**:

```bash
# tests/test_cpu_helpers.sh
FX=$ROOT/tests/fixtures/sysfs; bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
WRK=$(mktemp -d)
emit_cpu_apply > "$WRK/apply.sh"; emit_cpu_restore > "$WRK/restore.sh"
t_assert "apply script is bash-parseable" bash -n "$WRK/apply.sh"
t_assert "restore script is bash-parseable" bash -n "$WRK/restore.sh"
CPU_SYSFS=$FX ORIG_FILE=$WRK/orig.conf CPU_P_MAX_MHZ=3000 bash "$WRK/apply.sh" >/dev/null
t_eq "P policy5 capped" 3000000 "$(cat $FX/policy5/scaling_max_freq)"
t_eq "P policy17 capped" 3000000 "$(cat $FX/policy17/scaling_max_freq)"
t_eq "min lowered to hw floor" 1378000 "$(cat $FX/policy5/scaling_min_freq)"
t_eq "E policy0 untouched" 2808000 "$(cat $FX/policy0/scaling_max_freq)"
t_eq "orig recorded" 2 "$(wc -l < $WRK/orig.conf)"   # policy5 + policy17? no — 10 P lines
CPU_SYSFS=$FX ORIG_FILE=$WRK/orig.conf bash "$WRK/restore.sh" >/dev/null
t_eq "restore returns max" 3900000 "$(cat $FX/policy5/scaling_max_freq)"
t_eq "restore returns min" 1378000 "$(cat $FX/policy5/scaling_min_freq)"
# min>juggling path: policy pinned min=3900000
printf '%s' 3900000 > $FX/policy9/scaling_min_freq
CPU_SYSFS=$FX ORIG_FILE=$WRK/orig.conf CPU_P_MAX_MHZ=2808 bash "$WRK/apply.sh" >/dev/null
t_eq "high min lowered before cap" 2808000 "$(cat $FX/policy9/scaling_max_freq)"
```

Note: fix the orig-line expectation to `10` (all ten P policies) while transcribing — the comment marks it.

- [ ] **Step 2: Run** — FAIL (`emit_cpu_apply: command not found`).
- [ ] **Step 3: Implement**:

```bash
emit_cpu_apply() { cat <<'EOF'
#!/usr/bin/env bash
# /usr/libexec/sparktuner/cpu-apply — re-apply P-core cap; rediscover at runtime.
set -u
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu/cpufreq}
CONF_FILE=${CONF_FILE:-/etc/sparktuner.conf}
ORIG_FILE=${ORIG_FILE:-/var/lib/sparktuner/orig.conf}
CPU_P_MAX_MHZ=${CPU_P_MAX_MHZ:-3000}
[ -r "$CONF_FILE" ] && . "$CONF_FILE"
target=$((CPU_P_MAX_MHZ * 1000))
mkdir -p "$(dirname "$ORIG_FILE")"
umask 077; : > "$ORIG_FILE"
applied=0
for p in "$CPU_SYSFS"/policy*; do
  [ -r "$p/cpuinfo_max_freq" ] || continue
  hwmax=$(cat "$p/cpuinfo_max_freq")
  [ "$hwmax" -gt 3000000 ] || continue
  omin=$(cat "$p/scaling_min_freq")
  printf '%s %s %s\n' "${p##*/}" "$omin" "$hwmax" >> "$ORIG_FILE"
  if [ "$omin" -gt "$target" ]; then
    printf '%s' "$(cat "$p/cpuinfo_min_freq")" > "$p/scaling_min_freq"
  fi
  printf '%s' "$target" > "$p/scaling_max_freq"
  applied=$((applied + 1))
done
echo "cpu-apply: capped $applied P-policies at ${target} kHz"
[ "$applied" -gt 0 ]
EOF
}
emit_cpu_restore() { cat <<'EOF'
#!/usr/bin/env bash
# /usr/libexec/sparktuner/cpu-restore — undo cpu-apply using saved originals.
set -u
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu/cpufreq}
ORIG_FILE=${ORIG_FILE:-/var/lib/sparktuner/orig.conf}
[ -r "$ORIG_FILE" ] || { echo "cpu-restore: no originals at $ORIG_FILE (nothing to do)"; exit 0; }
n=0
while read -r name omin omax; do
  [ -n "$name" ] || continue
  d=$CPU_SYSFS/$name
  if [ -d "$d" ]; then
    printf '%s' "$omin" > "$d/scaling_min_freq"
    printf '%s' "$omax" > "$d/scaling_max_freq"
    n=$((n + 1))
  fi
done < "$ORIG_FILE"
echo "cpu-restore: restored $n policies"
EOF
}
```

- [ ] **Step 4: Run** — all PASS (with the `10`-line fix).

---

### Task 4: Conf/unit emission + install payload + adoption + uninstall payload

**Files:**
- Create: `tests/test_payload.sh`
- Modify: `sparktuner.sh`

**Interfaces:**
- Consumes: `emit_cpu_apply`, `emit_cpu_restore` (Task 3), globals (Task 1).
- Produces: `emit_conf` (prints `/etc/sparktuner.conf` body), `emit_gpu_unit`, `emit_cpu_unit`, `install_payload` (single base64 arg-free string = full remote `sudo bash -s` script), `uninstall_payload`. Payload contract: exits 0 on success; prints `ADOPTED sparkLimiter` when it disables `spark-gpu-clock-limit.service`; prints `INSTALLED <gpuunit> <cpuunit>` at end; GPU applied before CPU; any failure exits non-zero (host marked failed).

- [ ] **Step 1: Failing test**:

```bash
# tests/test_payload.sh
t_assert "conf contains both values" bash -c 'echo "$(emit_conf)" | grep -q "GPU_CLOCKS=\"0,2200\"" && echo "$(emit_conf)" | grep -q "CPU_P_MAX_MHZ=\"3000\""'
U=$(emit_gpu_unit)
for want in "WantedBy=multi-user.target" "After=nvidia-persistenced.service" "-lgc" "Restart=on-failure" "RemainAfterExit=yes"; do
  t_assert "gpu unit has: $want" bash -c "printf '%s\n' \"\$U\" | grep -qF -- '$want'"
done
U=$(emit_cpu_unit)
for want in "After=nv-cpu-governor.service" "cpu-apply" "cpu-restore" "StartLimitIntervalSec=0"; do
  t_assert "cpu unit has: $want" bash -c "printf '%s\n' \"\$U\" | grep -qF -- '$want'"
done
P=$(install_payload)
t_assert "payload decodes+parses" bash -c "printf '%s' '$P' | base64 -d | bash -n"
t_assert "payload contains adoption" bash -c "printf '%s' '$P' | base64 -d | grep -q 'spark-gpu-clock-limit'"
UP=$(uninstall_payload)
t_assert "uninstall payload parses" bash -c "printf '%s' '$UP' | base64 -d | bash -n"
t_assert "uninstall restores cpu" bash -c "printf '%s' '$UP' | base64 -d | grep -q 'cpu-restore'"
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**:

```bash
emit_conf() { printf 'GPU_CLOCKS="%s"\nCPU_P_MAX_MHZ="%s"\n' "$GPU_CLOCKS" "$CPU_P_MAX_MHZ"; }
emit_gpu_unit() { cat <<EOF
[Unit]
Description=sparktuner: cap GPU graphics clock (${GPU_CLOCKS} MHz)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=${CONF_FILE}
ExecStart=${NVSMI} -lgc \${GPU_CLOCKS}
ExecStop=-${NVSMI} -rgc
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}
emit_cpu_unit() { cat <<EOF
[Unit]
Description=sparktuner: cap CPU P-core max frequency (Cortex-X925)
After=nv-cpu-governor.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=${CONF_FILE}
ExecStart=${LIBEXEC_DIR}/cpu-apply
ExecStop=${LIBEXEC_DIR}/cpu-restore
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}
b64() { base64 | tr -d '\n'; }
install_payload() {
  local conf gpu cpu apl rst
  conf=$(emit_conf | b64); gpu=$(emit_gpu_unit | b64); cpu=$(emit_cpu_unit | b64)
  apl=$(emit_cpu_apply | b64); rst=$(emit_cpu_restore | b64)
  cat <<EOF | b64
set -u
test -x $NVSMI || { echo "no nvidia-smi; aborting before any change"; exit 1; }
$NVSMI -lgc "$GPU_CLOCKS" || { echo "GPU cap failed; aborting"; exit 1; }
mkdir -p $LIBEXEC_DIR /var/lib/sparktuner
printf '%s' "$conf" | base64 -d > $CONF_FILE; chmod 644 $CONF_FILE
printf '%s' "$gpu"  | base64 -d > /etc/systemd/system/${SERVICE_GPU}.service
printf '%s' "$cpu"  | base64 -d > /etc/systemd/system/${SERVICE_CPU}.service
printf '%s' "$apl"  | base64 -d > $LIBEXEC_DIR/cpu-apply;  chmod 755 $LIBEXEC_DIR/cpu-apply
printf '%s' "$rst"  | base64 -d > $LIBEXEC_DIR/cpu-restore; chmod 755 $LIBEXEC_DIR/cpu-restore
systemctl daemon-reload
if [ "\$(systemctl is-enabled spark-gpu-clock-limit.service 2>/dev/null)" = enabled ]; then
  systemctl disable spark-gpu-clock-limit.service && echo "ADOPTED sparkLimiter (its unit disabled, file kept)"
fi
systemctl enable ${SERVICE_GPU}.service ${SERVICE_CPU}.service
systemctl start ${SERVICE_GPU}.service || exit 1
systemctl start ${SERVICE_CPU}.service || exit 1
echo "INSTALLED gpu+cpu units"
EOF
}
uninstall_payload() {
  local rst; rst=$(emit_cpu_restore | b64)
  cat <<EOF | b64
set -u
systemctl disable --now ${SERVICE_GPU}.service ${SERVICE_CPU}.service 2>/dev/null
if [ -x $LIBEXEC_DIR/cpu-restore ]; then $LIBEXEC_DIR/cpu-restore; fi
$NVSMI -rgc 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE_GPU}.service /etc/systemd/system/${SERVICE_CPU}.service
rm -f $CONF_FILE $ORIG_FILE $LIBEXEC_DIR/cpu-apply $LIBEXEC_DIR/cpu-restore
rmdir $LIBEXEC_DIR 2>/dev/null || true
systemctl daemon-reload
[ -f /etc/systemd/system/spark-gpu-clock-limit.service ] && \\
  echo "sparkLimiter unit present; to re-enable: sudo systemctl enable --now spark-gpu-clock-limit"
echo "UNINSTALLED (stock clocks restored)"
EOF
}
```

- [ ] **Step 4: Run** — all PASS.

---

### Task 5: Discovery (adapted from sparkLimiter)

**Files:**
- Create: `tests/test_discovery.sh`, fixture `tests/fixtures/ssh_config`
- Modify: `sparktuner.sh`

**Interfaces:**
- Consumes: `SSH_USER`, `SCAN`.
- Produces: `valid_host NAME`, `is_lan_name NAME`, `src_ssh_config FILE` (pure: parse fixture), `PROBE_CMD` (remote probe string), `parse_probe_line LINE -> prints "machine-id hostname"`; arrays `FOUND_T FOUND_N` + `discover()` network flow (same as sparkLimiter §discovery; not unit-tested — exercised in Task 9).

- [ ] **Step 1: Failing test**:

```bash
# tests/test_discovery.sh
t_assert "plain host valid"      valid_host spark-f301-ts
t_assert "user@ip valid"         valid_host trevtravtrev@10.0.0.5
t_assert "ssh option rejected"  ! valid_host "-oProxyCommand=evil"
t_assert "space rejected"       ! valid_host "a b"
t_assert "192.168 is lan"        is_lan_name 192.168.86.28
t_assert "10.x is lan"           is_lan_name 10.1.2.3
t_assert "CGNAT 100.64 is lan"   is_lan_name 100.107.211.92
t_assert "public ip not lan"    ! is_lan_name 8.8.8.8
t_assert ".local is lan"         is_lan_name spark-bdfd.local
t_assert "domain not lan"       ! is_lan_name example.com
t_eq "ssh config hosts parsed" "spark-a spark-b" \
  "$(src_ssh_config $ROOT/tests/fixtures/ssh_config | tr '\n' ' ' | sed 's/ $//')"
t_eq "probe line parsed" "abc123 spark-x" "$(parse_probe_line 'SPARK abc123 spark-x')"
t_assert "non-spark line rejected" ! parse_probe_line "SPARK-with-junk"
t_assert "garbage rejected"         ! parse_probe_line "hello"
```

Fixture `tests/fixtures/ssh_config`:
```
Host spark-a
	HostName 192.168.1.10
Host spark-b
Host *.wildcard ignored
Host spark-a
```
(expect dedupe + wildcard skip → "spark-a spark-b")

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** (verbatim adaptations from sparkLimiter where noted; license MIT):

```bash
valid_host() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._:%@-]*$ ]]; }
is_lan_name() {
  local h=$1 a b
  case "$h" in *.local|*.lan|*.home|*.internal|*.home.arpa) return 0 ;; esac
  if [[ "$h" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    { [ "$a" -eq 10 ] || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
      || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } || { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; } \
      || { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }; } && return 0
    return 1
  fi
  [[ "$h" != *.* && "$h" != *:* ]]
}
src_ssh_config() { awk 'tolower($1)=="host" {for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i}' "$1" | awk '!seen[$0]++'; }
PROBE_CMD='info="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)|$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"; if printf "%s" "$info" | grep -qiE "GB10|DGX[ _-]?Spark"; then echo "SPARK $(cat /etc/machine-id 2>/dev/null || echo none) $(hostname)"; fi'
parse_probe_line() { [[ "$1" =~ ^SPARK\ [A-Za-z0-9._-]+\ [A-Za-z0-9._-]+$ ]] && printf '%s %s' "${1#SPARK }" | awk '{print $1, $2}'; }
```

Plus the network functions copied from sparkLimiter (`src_known_hosts`, `src_mdns`, `src_neighbors`, `local_ipv4`, `src_subnets`, `probe_one`, `run_probes`, `probe_local`, `discover`, `print_found`) with `PROBE_CMD` substituted for its inline probe — pure copy, credited, MIT-compatible; no test beyond compile: `bash -n sparktuner.sh`.

- [ ] **Step 4: Run** — all PASS.

---

### Task 6: Verify report

**Files:**
- Create: `tests/test_verify.sh`
- Modify: `sparktuner.sh`

**Interfaces:**
- Consumes: `discover_policies`/`discover_e_policies` (Task 2), Task 1 globals.
- Produces: `verify_host LABEL` → prints report lines, returns 0 all-PASS / 1 any-FAIL. Overridables for tests: `V_SYSFS` (default `/sys/devices/system/cpu/cpufreq`), `V_GPU_QUERY` (default `nvidia-smi --query-gpu=clocks.sm --format=csv,noheader`), `V_UNIT_STATE` (default `systemctl is-enabled %s >/dev/null && systemctl is-active %s >/dev/null`), `V_LOADTEST` (default `1`; `0` skips the 5 s load and the delivered-freq check — used by CI), `V_SLEEP` (default 3). Line format: two spaces + domain + check + `PASS`/`FAIL`.

- [ ] **Step 1: Failing test**:

```bash
# tests/test_verify.sh
FX=$ROOT/tests/fixtures/sysfs; bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
# cap the fixture like an install would, then expect all-PASS
CPU_SYSFS=$FX ORIG_FILE=$(mktemp) CPU_P_MAX_MHZ=3000 bash <(emit_cpu_apply) >/dev/null
out=$(V_SYSFS=$FX V_LOADTEST=0 V_GPU_QUERY='echo 2190 MHz' V_UNIT_STATE='true' verify_host spark-fake; echo "rc=$?")
t_assert "verify passes on capped fixture"   bash -c "printf '%s' '$out' | grep -q 'rc=0'"
t_assert "reports gpu PASS"                   bash -c "printf '%s' '$out' | grep -q 'GPU.*PASS'"
t_assert "reports per-policy PASS"            bash -c "printf '%s' '$out' | grep -q 'policy5.*PASS'"
t_assert "reports E-core untouched PASS"      bash -c "printf '%s' '$out' | grep -q 'policy0.*PASS'"
# break one policy -> FAIL + rc=1
printf '%s' 3900000 > $FX/policy8/scaling_max_freq
out=$(V_SYSFS=$FX V_LOADTEST=0 V_GPU_QUERY='echo 2190 MHz' V_UNIT_STATE='true' verify_host spark-fake; echo "rc=$?")
t_assert "uncapped policy FAILs"              bash -c "printf '%s' '$out' | grep -q 'policy8.*FAIL'"
t_assert "rc=1 on failure"                    bash -c "printf '%s' '$out' | grep -q 'rc=1'"
# E-core tampered -> FAIL
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
CPU_SYSFS=$FX ORIG_FILE=$(mktemp) CPU_P_MAX_MHZ=3000 bash <(emit_cpu_apply) >/dev/null
printf '%s' 2600000 > $FX/policy0/scaling_max_freq
out=$(V_SYSFS=$FX V_LOADTEST=0 V_GPU_QUERY='echo 2190 MHz' V_UNIT_STATE='true' verify_host spark-fake; echo "rc=$?")
t_assert "tampered E-core FAILs"              bash -c "printf '%s' '$out' | grep -q 'policy0.*FAIL'"
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**:

```bash
verify_host() { # LABEL -> report lines; rc 0=all PASS
  local label=$1 target=$((CPU_P_MAX_MHZ * 1000)) fail=0 p sm=0 line
  V_SYSFS=${V_SYSFS:-/sys/devices/system/cpu/cpufreq}
  V_GPU_QUERY=${V_GPU_QUERY:-"$NVSMI --query-gpu=clocks.sm --format=csv,noheader"}
  V_UNIT_STATE=${V_UNIT_STATE:-systemctl}
  V_LOADTEST=${V_LOADTEST:-1}; V_SLEEP=${V_SLEEP:-3}
  echo "host: $label"
  sm=$($V_GPU_QUERY 2>/dev/null | grep -oE '[0-9]+' | head -n1); sm=${sm:-0}
  if [ "$sm" -le "${GPU_CLOCKS#*,}" ] 2>/dev/null; then
    echo "  GPU  sm_clock=${sm}MHz<=${GPU_CLOCKS#*,} unit=ok      PASS"
  else
    echo "  GPU  sm_clock=${sm}MHz>${GPU_CLOCKS#,*}               FAIL"; fail=1
  fi
  for p in $(discover_policies "$V_SYSFS" | sort); do
    line=$(cat "$V_SYSFS/$p/scaling_max_freq" 2>/dev/null)
    if [ "$line" = "$target" ]; then echo "  CPU  $p max=${line} target=${target}        PASS"
    else echo "  CPU  $p max=${line:-none} target=${target}        FAIL"; fail=1; fi
  done
  if [ "$V_LOADTEST" = 1 ]; then
    p=$(discover_policies "$V_SYSFS" | sort | head -n1)
    core=$(awk '{print $1}' "$V_SYSFS/$p/affected_cpus" 2>/dev/null)
    if [ -n "${core:-}" ]; then
      nice -n 10 taskset -c "$core" timeout 5 sha1sum /dev/zero >/dev/null 2>&1 &
      sleep "$V_SLEEP"
      avg=$(cat "$V_SYSFS/$p/cpuinfo_avg_freq" 2>/dev/null); avg=${avg:-0}
      if [ $((avg < target ? target - avg : avg - target)) -le $((target / 20)) ]; then
        echo "  CPU  $p delivered_avg=${avg} under load     PASS"
      else echo "  CPU  $p delivered_avg=${avg} under load     FAIL"; fail=1; fi
      wait
    fi
  fi
  for p in $(discover_e_policies "$V_SYSFS" | sort); do
    line=$(cat "$V_SYSFS/$p/scaling_max_freq" 2>/dev/null)
    hw=$(cat "$V_SYSFS/$p/cpuinfo_max_freq" 2>/dev/null)
    if [ "$line" = "$hw" ]; then echo "  CPU  $p (E) max=${line} untouched    PASS"
    else echo "  CPU  $p (E) max=${line:-none} hw=${hw}        FAIL"; fail=1; fi
  done
  hot=$(sort -n "$V_SYSFS"/../../class/thermal/thermal_zone*/temp 2>/dev/null | tail -n1)
  [ -n "$hot" ] && echo "  TEMP hottest_zone=$((hot / 1000))C trip=104C        info"
  return $fail
}
```

(Remote execution: `--verify` runs the whole `sparktuner.sh --verify --local-style` on the host via ssh — see Task 7 — so `V_SYSFS` defaulting to the real path works both locally and remotely. Fix the `${GPU_CLOCKS#,*}` typo to `${GPU_CLOCKS#*,}` when transcribing.)

- [ ] **Step 4: Run** — all PASS.

---

### Task 7: Main flow — wizard, apply loop, dry-run, uninstall, summary

**Files:**
- Create: `tests/test_main.sh`
- Modify: `sparktuner.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: `main()` — resolution order: hosts given → use; else `discover()`; `LIST_ONLY` prints and exits; `VERIFY_ONLY` loops hosts running `verify_host` over ssh (or locally for `localhost`), aggregates exit code; `DRY_RUN` prints per-host plan (files + values + adoption) without ssh; UNINSTALL loops `uninstall_payload`; else `install_payload` per host via `ssh -t` (or local `sudo bash -c` for localhost); summary `Done. OK: n Failed: n`, exit 0/1.

- [ ] **Step 1: Failing test** (mock ssh by overriding `SSH_CMD` — add `SSH_CMD=${SSH_CMD:-ssh}` indirection in `run_on_host HOST PAYLOAD`):

```bash
# tests/test_main.sh
run_main() { main "$@"; }
SSH_CMD=$ROOT/tests/fixtures/fake_ssh   # records payload, simulates success
FX=$ROOT/tests/fixtures/sysfs
t_assert "main --dry-run writes nothing" bash -c "
  DRY=1; out=\$(main --dry-run 192.168.86.196 2>&1); rc=\$?
  printf '%s' \"\$out\" | grep -q 'DRY-RUN' && [ ! -e /etc/sparktuner.conf ]"
t_assert "main install calls run_on_host" bash -c "
  out=\$(main -y 192.168.86.196 2>&1); printf '%s' \"\$out\" | grep -q 'OK: 1'"
t_assert "main --verify rc0 on fake pass" bash -c "
  V_GPU_QUERY='echo 2190 MHz' V_LOADTEST=0 main --verify 192.168.86.196 >/dev/null 2>&1"
t_assert "unknown host fails summary" bash -c "
  SSH_CMD=$ROOT/tests/fixtures/fake_ssh_fail main -y 10.255.255.1 2>&1 | grep -q 'Failed: 1'"
```

Fixture `tests/fixtures/fake_ssh`: `#!/usr/bin/env bash` + `echo "FAKE_SSH $*" >> "$(dirname $0)/../ssh_calls.log`; `exit 0` (and `fake_ssh_fail` exits 255). For `--verify` over ssh, `run_verify_remote HOST` executes `sparktuner.sh --verify --internal-local` on the host by piping the script itself: `b64self | SSH_CMD -t HOST "base64 -d | SPARKTUNER_LIB=0 bash -s -- --verify --internal-local"` — implement `b64self()` = `base64 "$0"`. Add hidden flag `--internal-local` parsed in Task 1's parser (`INTERNAL_LOCAL=1; shift`) so verify runs against the real host sysfs without ssh recursion.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `b64self`, `run_on_host`, `run_verify_remote`, `print_dry_run`, `main` (straightforward composition per Interfaces; ~70 lines following sparkLimiter's target loop: `ssh -t -o ConnectTimeout=10 -- "$host" "echo <payload> | base64 -d | sudo bash"`; localhost branch runs `echo <payload> | base64 -d | sudo bash` directly).
- [ ] **Step 4: Run** — all PASS; `bash -n sparktuner.sh` clean.

---

### Task 8: ShellCheck, CI, README, LICENSE

**Files:**
- Create: `.github/workflows/ci.yml`, `README.md`
- Modify: `sparktuner.sh` (fix any ShellCheck findings)

**Interfaces:** none (final hardening).

- [ ] **Step 1:** `shellcheck sparktuner.sh` → fix all warnings (target: zero, `--severity=style` allowed pragmas only).
- [ ] **Step 2:** CI:

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y shellcheck
      - run: shellcheck sparktuner.sh
      - run: bash tests/run.sh
```

- [ ] **Step 3:** README: what/why, quick start, flags table, receipts table (from research report: 3000→67.5 °C etc.), reboot-persistence section (SPEC §5 persistence block), sparkLimiter adoption note, uninstall, credits (sparkLimiter MIT, jetspark t/387929, t/383939#2, NVIDIA t/367604), MIT badge. `.gitattributes` already from Task 1.
- [ ] **Step 4:** Run `bash tests/run.sh` + `shellcheck` locally one final time.

---

### Task 9: Live E2E on both Sparks (acceptance — user-assisted)

**Files:** none created; runbook executed.

- [ ] **Step 1:** From the user's PC: `bash sparktuner.sh -n` → both Sparks found by name.
- [ ] **Step 2:** `bash sparktuner.sh --dry-run` → plan shows conf/units/helpers + adoption line.
- [ ] **Step 3:** `bash sparktuner.sh` (user types sudo password per host) → install both; `ADOPTED sparkLimiter` + `INSTALLED` seen.
- [ ] **Step 4:** `bash sparktuner.sh --verify` → every line PASS on both hosts (delivered avg within 5 % of 3000000; sm ≤ 2200; E-cores 2808000).
- [ ] **Step 5:** User reboots `spark-f301`; after boot `bash sparktuner.sh --verify spark-f301-ts` → all PASS (persistence proof, SPEC §9).
- [ ] **Step 6:** `bash sparktuner.sh --uninstall` on one host → P back to 3900000, `-rgc` applied, units/conf gone, sparkLimiter re-enable hint printed; then re-install to leave fleet capped; final verify PASS.
- [ ] **Step 7:** Publish: user pushes repo to `github.com/trevtravtrev/sparktuner` (gh CLI, public). Tag `v1.0.0`.

## Self-Review (done)

- Spec coverage: §3 CLI→T1/T7; §4 discovery→T5; §5 files/adoption/order→T4/T7 (+persistence block→T4 unit contents, T9 step 5); §6 mechanics+validation→T1/T2/T3; §7 verify→T6/T7; §8 safety→T1 validation/T4 aborts/T7 dry-run; §9 tests→T1–T8 + T9; §10 repo→T8. Fan: absent everywhere ✔.
- Fixed during review: `${GPU_CLOCKS#,*}` typo (T6), orig-count expectation (T3), `src_ssh_config` dedupe (T5), `--internal-local` flag needed (T7) — all noted at their sites.
- Name check: `discover_policies/discover_e_policies/emit_cpu_apply/emit_cpu_restore/emit_conf/emit_gpu_unit/emit_cpu_unit/install_payload/uninstall_payload/verify_host/run_on_host/b64self` used consistently across tasks.
