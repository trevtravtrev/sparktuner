#!/usr/bin/env bash
# sparktuner — cap GPU + CPU P-core clocks on NVIDIA DGX Spark (GB10) fleets,
# persist them across reboots, and verify with live numbers. See SPEC.md.
#
# Usage:
#   ./sparktuner.sh                    # discover Sparks, confirm, apply, verify
#   ./sparktuner.sh host [host...]     # skip discovery, use these hosts
#   ./sparktuner.sh -n [host...]       # list Sparks only, change nothing
#   ./sparktuner.sh --verify [host..]  # read-only PASS/FAIL report, no sudo
#   ./sparktuner.sh --dry-run [...]    # show the plan, write nothing
#   ./sparktuner.sh --uninstall [...]  # remove units, restore stock clocks
#   ./sparktuner.sh --gpu 0,2200 --cpu-p 3000 [...]
#   ./sparktuner.sh -y -s -l USER      # no prompts / subnet sweep / ssh user
#
# Defaults: GPU 0,2200 MHz (nvidia-smi -lgc), CPU P-cores 3000 MHz.
# Never touches E-cores, fans, or firmware. MIT. Discovery pattern adapted
# from MiaAI-Lab/sparkLimiter (MIT).

set -u
set -f   # host lists come from files and the network; never glob-expand them

VERSION="1.0.0"
GPU_CLOCKS="0,2200"
CPU_P_MAX_MHZ=3000
GOVERNOR="schedutil"
FORCE=0; LIST_ONLY=0; VERIFY_ONLY=0; UNINSTALL=0; DRY_RUN=0; YES=0; SCAN=0; SSH_USER=""
INTERNAL_LOCAL=0
HOSTS=()

SERVICE_GPU="sparktuner-gpu-cap"; SERVICE_CPU="sparktuner-cpu-cap"
CONF_FILE="/etc/sparktuner.conf"; ORIG_FILE="/var/lib/sparktuner/orig.conf"
LIBEXEC_DIR="/usr/libexec/sparktuner"; NVSMI=/usr/bin/nvidia-smi

log() { printf '%s\n' "$*" >&2; }
die() { log "sparktuner: $*"; exit 2; }

usage() { sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'; }

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
  case "$GOVERNOR" in
    schedutil|performance|powersave|conservative|ondemand|userspace) ;;
    *) die "invalid governor '$GOVERNOR' (known: schedutil performance powersave conservative ondemand userspace)" ;;
  esac
  if [ -n "$SSH_USER" ] && ! [[ "$SSH_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
    die "invalid --user '$SSH_USER'"
  fi
  return 0
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --gpu)      GPU_CLOCKS="${2:?"$1 needs a value"}"; shift 2 ;;
      --cpu-p)    CPU_P_MAX_MHZ="${2:?"$1 needs a value"}"; shift 2 ;;
      -f|--force) FORCE=1; shift ;;
      -n|--list)  LIST_ONLY=1; shift ;;
      --verify)   VERIFY_ONLY=1; shift ;;
      --dry-run)  DRY_RUN=1; shift ;;
      -u|--uninstall) UNINSTALL=1; shift ;;
      -y|--yes)   YES=1; shift ;;
      -s|--scan)  SCAN=1; shift ;;
      -l|--user)  SSH_USER="${2:?"$1 needs a value"}"; shift 2 ;;
      --internal-local) INTERNAL_LOCAL=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      -V|--version) echo "sparktuner $VERSION"; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do HOSTS+=("$1"); shift; done ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *)  HOSTS+=("$1"); shift ;;
    esac
  done
  return 0
}

P_THRESHOLD_KHZ=3000000   # P-cores (X925) report 3900000; E-cores (A725) 2808000
discover_policies() { # ROOT -> P-core policy names on stdout (the ones we cap)
  ( set +f; local p max
    for p in "$1"/policy*; do
      [ -r "$p/cpuinfo_max_freq" ] || continue
      max=$(cat "$p/cpuinfo_max_freq")
      [ "$max" -gt "$P_THRESHOLD_KHZ" ] && printf '%s\n' "${p##*/}"
    done
    return 0 )
}
discover_e_policies() { # ROOT -> E-core policy names on stdout (never written)
  ( set +f; local p max
    for p in "$1"/policy*; do
      [ -r "$p/cpuinfo_max_freq" ] || continue
      max=$(cat "$p/cpuinfo_max_freq")
      [ "$max" -le "$P_THRESHOLD_KHZ" ] && printf '%s\n' "${p##*/}"
    done
    return 0 )
}

emit_cpu_apply() { cat <<'EOF'
#!/usr/bin/env bash
# /usr/libexec/sparktuner/cpu-apply — cap P-cores + set governor; rediscover at runtime.
# Never writes E-core min/max frequencies. Governor is set on ALL policies.
set -u
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu/cpufreq}
CONF_FILE=${CONF_FILE:-/etc/sparktuner.conf}
ORIG_FILE=${ORIG_FILE:-/var/lib/sparktuner/orig.conf}
CPU_P_MAX_MHZ=${CPU_P_MAX_MHZ:-3000}
GOVERNOR=${GOVERNOR:-schedutil}
[ -r "$CONF_FILE" ] && . "$CONF_FILE"
target=$((CPU_P_MAX_MHZ * 1000))
mkdir -p "$(dirname "$ORIG_FILE")"
umask 077; : > "$ORIG_FILE"
applied=0; goved=0
for p in "$CPU_SYSFS"/policy*; do
  [ -r "$p/cpuinfo_max_freq" ] && [ -r "$p/scaling_governor" ] || continue
  name=${p##*/}
  hwmax=$(cat "$p/cpuinfo_max_freq"); omin=$(cat "$p/scaling_min_freq")
  curgov=$(cat "$p/scaling_governor")
  printf '%s %s %s %s\n' "$name" "$omin" "$hwmax" "$curgov" >> "$ORIG_FILE"
  if [ "$hwmax" -gt 3000000 ]; then
    if [ "$omin" -gt "$target" ]; then
      printf '%s' "$(cat "$p/cpuinfo_min_freq")" > "$p/scaling_min_freq"
    fi
    printf '%s' "$target" > "$p/scaling_max_freq"
    applied=$((applied + 1))
  fi
  if [ "$curgov" != "$GOVERNOR" ]; then
    if printf '%s\n' "$GOVERNOR" \
       | grep -qxf <(tr ' ' '\n' < "$p/scaling_available_governors" 2>/dev/null); then
      printf '%s' "$GOVERNOR" > "$p/scaling_governor"
      goved=$((goved + 1))
    fi
  fi
done
echo "cpu-apply: capped $applied P-policies at ${target} kHz; governor=$GOVERNOR set on $goved policies"
[ "$applied" -gt 0 ]
EOF
}
emit_cpu_restore() { cat <<'EOF'
#!/usr/bin/env bash
# /usr/libexec/sparktuner/cpu-restore — undo cpu-apply using saved originals.
# Writes only what actually differs from the saved state.
set -u
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu/cpufreq}
ORIG_FILE=${ORIG_FILE:-/var/lib/sparktuner/orig.conf}
[ -r "$ORIG_FILE" ] || { echo "cpu-restore: no originals at $ORIG_FILE (nothing to do)"; exit 0; }
n=0
while read -r name omin omax ogov; do
  [ -n "$name" ] || continue
  d=$CPU_SYSFS/$name
  [ -d "$d" ] || continue
  [ "$(cat "$d/scaling_min_freq")" = "$omin" ] || printf '%s' "$omin" > "$d/scaling_min_freq"
  [ "$(cat "$d/scaling_max_freq")" = "$omax" ] || printf '%s' "$omax" > "$d/scaling_max_freq"
  [ "$(cat "$d/scaling_governor")" = "$ogov" ] || printf '%s' "$ogov" > "$d/scaling_governor"
  n=$((n + 1))
done < "$ORIG_FILE"
echo "cpu-restore: restored $n policies"
EOF
}

emit_conf() {
  printf 'GPU_CLOCKS="%s"\nCPU_P_MAX_MHZ="%s"\nGOVERNOR="%s"\n' \
    "$GPU_CLOCKS" "$CPU_P_MAX_MHZ" "$GOVERNOR"
}
emit_gpu_unit() { cat <<EOF
[Unit]
Description=sparktuner: cap GPU graphics clock (\${GPU_CLOCKS} MHz)
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
Description=sparktuner: cap CPU P-cores + set governor (via /etc/sparktuner.conf)
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
printf '%s' "$apl"  | base64 -d > $LIBEXEC_DIR/cpu-apply;   chmod 755 $LIBEXEC_DIR/cpu-apply
printf '%s' "$rst"  | base64 -d > $LIBEXEC_DIR/cpu-restore; chmod 755 $LIBEXEC_DIR/cpu-restore
systemctl daemon-reload
if [ "\$(systemctl is-enabled spark-gpu-clock-limit.service 2>/dev/null)" = enabled ]; then
  systemctl disable spark-gpu-clock-limit.service \\
    && echo "ADOPTED sparkLimiter (its unit disabled, file kept)"
fi
systemctl enable ${SERVICE_GPU}.service ${SERVICE_CPU}.service
systemctl start ${SERVICE_GPU}.service || exit 1
systemctl start ${SERVICE_CPU}.service || exit 1
echo "INSTALLED gpu+cpu units (conf: $CONF_FILE)"
EOF
}
uninstall_payload() {
  cat <<EOF | b64
set -u
systemctl disable --now ${SERVICE_GPU}.service ${SERVICE_CPU}.service 2>/dev/null
if [ -x $LIBEXEC_DIR/cpu-restore ]; then $LIBEXEC_DIR/cpu-restore; fi
$NVSMI -rgc 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE_GPU}.service /etc/systemd/system/${SERVICE_CPU}.service
rm -f $CONF_FILE $ORIG_FILE $LIBEXEC_DIR/cpu-apply $LIBEXEC_DIR/cpu-restore
rmdir $LIBEXEC_DIR 2>/dev/null || true
systemctl daemon-reload
if [ -f /etc/systemd/system/spark-gpu-clock-limit.service ]; then
  echo "sparkLimiter unit present; to re-enable: sudo systemctl enable --now spark-gpu-clock-limit"
fi
echo "UNINSTALLED (stock clocks + performance governor restored)"
EOF
}

# --- discovery ----------------------------------------------------------------
# Adapted from MiaAI-Lab/sparkLimiter (MIT). A host counts as a Spark if it
# answers over key-based ssh and reports a GB10 / DGX Spark product name.
# Probes are read-only, BatchMode (never a password), no agent/forwarding.

valid_host() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._:%@-]*$ ]]; }

is_lan_name() { # private/link-local/CGNAT addresses and LAN-style names only
  local h=$1 a b
  case "$h" in *.local|*.lan|*.home|*.internal|*.home.arpa) return 0 ;; esac
  if [[ "$h" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    { [ "$a" -eq 10 ] \
      || { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
      || { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } \
      || { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; } \
      || { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }; } && return 0
    return 1
  fi
  [[ "$h" != *.* && "$h" != *:* ]]
}

is_addr() { # bare IPv4/IPv6 target (optionally user@), not a host name
  local h=${1##*@}
  [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$h" == *:* ]]
}

unicast_only() { grep -Ev '^(22[4-9]|23[0-9])\.|\.255$'; }

src_ssh_config() { # [file] -> non-wildcard Host entries, deduped (default ~/.ssh/config)
  local f=${1:-$HOME/.ssh/config}
  [ -r "$f" ] || return 0
  awk 'tolower($1)=="host" {for (i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i}' "$f" | awk '!seen[$0]++'
}

src_known_hosts() { # plain names on port 22 only, LAN-looking only
  [ -r "$HOME/.ssh/known_hosts" ] || return 0
  awk '$1 !~ /^\|/ && $1 !~ /^@/ {print $1}' "$HOME/.ssh/known_hosts" | tr ',' '\n' \
    | grep -Ev '^\[|[*?!]' | while read -r h; do is_lan_name "$h" && echo "$h"; done
}

src_mdns() { # addresses, not advertised names (those are attacker-controlled)
  command -v avahi-browse >/dev/null 2>&1 || return 0
  avahi-browse -rtp _ssh._tcp 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4" {print $8}' | unicast_only
}

src_neighbors() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 neigh show 2>/dev/null | awk '$NF!="FAILED" && $NF!="INCOMPLETE" {print $1}' | unicast_only
  elif command -v arp >/dev/null 2>&1; then
    arp -an 2>/dev/null | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p' | unicast_only
  fi
}

local_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null \
      | awk '$2 !~ /^(docker|br-|veth|virbr|lo|tailscale|zt)/ {split($4,a,"/"); print a[1]}'
  else
    ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}'
  fi
}

src_subnets() { # the /24 around each local address, minus our own addresses
  local ip base seen=" " mine i
  mine=" $(local_ipv4 | tr '\n' ' ') "
  for ip in $(local_ipv4); do
    base=${ip%.*}
    case "$seen" in *" $base "*) continue ;; esac
    seen="$seen$base "
    for i in $(seq 1 254); do
      case "$mine" in *" $base.$i "*) ;; *) echo "$base.$i" ;; esac
    done
  done
}

# shellcheck disable=SC2016 — single quotes are intentional: this must expand on the REMOTE host, not here
PROBE_CMD='info="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)|$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"; if printf "%s" "$info" | grep -qiE "GB10|DGX[ _-]?Spark"; then echo "SPARK $(cat /etc/machine-id 2>/dev/null || echo none) $(hostname)"; fi'
parse_probe_line() { # LINE -> "machine-id hostname" (nothing if malformed)
  local id host
  read -r _ id host _ <<<"$1"
  if [[ "$1" =~ ^SPARK\ [A-Za-z0-9._-]+\ [A-Za-z0-9._-]+$ ]]; then
    printf '%s %s' "$id" "$host"
    return 0
  fi
  return 1
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
CANDS=()
PROBED=" "
FOUND_T=(); FOUND_N=(); FOUND_IDS=(); SEEN_IDS=" "
DENIED=0

add_cand() { # NAME [raw] -- "raw" names (IPs, mDNS) get --user prepended
  local n=$1
  valid_host "$n" || return 0
  case "$PROBED" in *" $n "*) return 0 ;; esac
  PROBED="$PROBED$n "
  if [ "${2:-}" = raw ] && [ -n "$SSH_USER" ] && [[ "$n" != *@* ]]; then n="$SSH_USER@$n"; fi
  CANDS+=("$n")
}

probe_one() { # target index
  local out rc
  out=$($TO ssh -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=1 \
            -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
            -- "$1" "$PROBE_CMD" 2>"$TMP/$2.err" | grep -m1 -E '^SPARK [A-Za-z0-9._-]+ [A-Za-z0-9._-]+$') || rc=$?
  if [ -n "${out:-}" ]; then printf '%s\t%s\n' "$1" "$out" > "$TMP/$2.res"
  elif grep -q 'Permission denied' "$TMP/$2.err" 2>/dev/null; then : > "$TMP/$2.denied"; fi
  return 0
}

PROBE_N=0
run_probes() {
  local t running=0 start=$PROBE_N i j line id name cand
  [ ${#CANDS[@]} -eq 0 ] && return 0
  for t in "${CANDS[@]}"; do
    probe_one "$t" "$PROBE_N" &
    PROBE_N=$((PROBE_N + 1)); running=$((running + 1))
    if [ "$running" -ge 32 ]; then wait; running=0; fi
  done
  wait
  CANDS=()
  for ((i = start; i < PROBE_N; i++)); do
    [ -e "$TMP/$i.denied" ] && DENIED=$((DENIED + 1))
    [ -r "$TMP/$i.res" ] || continue
    line=$(cat "$TMP/$i.res")
    name=$(printf '%s' "$line" | awk '{print $4}')
    id="$(printf '%s' "$line" | awk '{print $3}'):$name"
    cand=$(printf '%s' "$line" | cut -f1)
    case "$SEEN_IDS" in
      *" $id "*)
        if ! is_addr "$cand"; then
          for ((j = 0; j < ${#FOUND_IDS[@]}; j++)); do
            [ "${FOUND_IDS[j]}" = "$id" ] || continue
            is_addr "${FOUND_T[j]}" && FOUND_T[j]=$cand
            break
          done
        fi
        continue ;;
    esac
    SEEN_IDS="$SEEN_IDS$id "
    FOUND_T+=("$cand"); FOUND_N+=("$name"); FOUND_IDS+=("$id")
  done
}

probe_local() { # is this machine itself a Spark?
  local me id name
  me=$(bash -c "$PROBE_CMD" 2>/dev/null | grep -m1 '^SPARK [^ ]* [^ ]*$')
  [ -n "$me" ] || return 0
  name=$(printf '%s' "$me" | awk '{print $3}')
  id="$(printf '%s' "$me" | awk '{print $2}'):$name"
  case "$SEEN_IDS" in *" $id "*) return 0 ;; esac
  SEEN_IDS="$SEEN_IDS$id "
  FOUND_T+=("localhost"); FOUND_N+=("$name"); FOUND_IDS+=("$id")
}

discover() {
  log "Discovering DGX Sparks (ssh config, known_hosts, mDNS, neighbours$([ $SCAN -eq 1 ] && echo ', subnet sweep'))..."
  local h
  probe_local
  for h in $(src_ssh_config);  do add_cand "$h"; done
  for h in $(src_known_hosts); do add_cand "$h" raw; done
  for h in $(src_mdns);        do add_cand "$h" raw; done
  for h in $(src_neighbors);   do add_cand "$h" raw; done
  [ "$SCAN" -eq 1 ] && for h in $(src_subnets); do add_cand "$h" raw; done
  run_probes
}

verify_host() { # LABEL -> PASS/FAIL report lines; rc 0 = all PASS
  local label=$1 target=$((CPU_P_MAX_MHZ * 1000)) fail=0 p line hw sm avg hot core
  V_SYSFS=${V_SYSFS:-/sys/devices/system/cpu/cpufreq}
  V_THERMAL=${V_THERMAL:-/sys/class/thermal}
  V_GPU_QUERY=${V_GPU_QUERY:-"$NVSMI --query-gpu=clocks.sm --format=csv,noheader"}
  V_UNIT_STATE=${V_UNIT_STATE:-systemctl}
  V_LOADTEST=${V_LOADTEST:-1}; V_SLEEP=${V_SLEEP:-3}
  echo "host: $label"

  sm=$($V_GPU_QUERY 2>/dev/null | grep -oE '[0-9]+' | head -n1); sm=${sm:-0}
  if [ "$sm" -le "${GPU_CLOCKS#*,}" ]; then
    echo "  GPU  sm_clock=${sm}MHz <= ${GPU_CLOCKS#*,}MHz cap      PASS"
  else
    echo "  GPU  sm_clock=${sm}MHz > ${GPU_CLOCKS#*,}MHz cap       FAIL"; fail=1
  fi

  for p in $(discover_policies "$V_SYSFS" | sort); do
    line=$(cat "$V_SYSFS/$p/scaling_max_freq" 2>/dev/null)
    if [ "$line" = "$target" ]; then
      echo "  CPU  $p max=${line} target=${target}            PASS"
    else
      echo "  CPU  $p max=${line:-none} target=${target}      FAIL"; fail=1
    fi
  done

  if [ "$V_LOADTEST" = 1 ]; then
    p=$(discover_policies "$V_SYSFS" | sort | head -n1)
    core=$(awk '{print $1}' "$V_SYSFS/$p/affected_cpus" 2>/dev/null)
    if [ -n "${core:-}" ]; then
      nice -n 10 taskset -c "$core" timeout 5 sha1sum /dev/zero >/dev/null 2>&1 &
      sleep "$V_SLEEP"
      avg=$(cat "$V_SYSFS/$p/cpuinfo_avg_freq" 2>/dev/null); avg=${avg:-0}
      if [ $((avg < target ? target - avg : avg - target)) -le $((target / 20)) ]; then
        echo "  CPU  $p delivered_avg=${avg} under 5s load   PASS"
      else
        echo "  CPU  $p delivered_avg=${avg} under 5s load   FAIL"; fail=1
      fi
      wait
    fi
  fi

  for p in $(discover_policies "$V_SYSFS"; discover_e_policies "$V_SYSFS") ; do
    line=$(cat "$V_SYSFS/$p/scaling_governor" 2>/dev/null)
    if [ "$line" = "$GOVERNOR" ]; then
      echo "  CPU  $p governor=$GOVERNOR                  PASS"
    else
      echo "  CPU  $p governor=${line:-none} want=$GOVERNOR    FAIL"; fail=1
    fi
  done

  for p in $(discover_e_policies "$V_SYSFS" | sort); do
    line=$(cat "$V_SYSFS/$p/scaling_max_freq" 2>/dev/null)
    hw=$(cat "$V_SYSFS/$p/cpuinfo_max_freq" 2>/dev/null)
    if [ "$line" = "$hw" ]; then
      echo "  CPU  $p (E) max=${line} untouched           PASS"
    else
      echo "  CPU  $p (E) max=${line:-none} hw=${hw}         FAIL"; fail=1
    fi
  done

  hot=$( (set +f; sort -n "$V_THERMAL"/thermal_zone*/temp 2>/dev/null) | tail -n1)
  [ -n "${hot:-}" ] && echo "  TEMP hottest_zone=$((hot / 1000))C critical=104.8C      info"
  return "$fail"
}

# --- main flow ----------------------------------------------------------------
SSH_BIN=${SSH_BIN:-ssh}

b64self() { base64 "$0" | tr -d '\n'; }

have_tty() { { : < /dev/tty; } 2>/dev/null; }
ask() { # prompt -> answer on stdout; fails without a terminal
  local a=""
  have_tty || return 1
  read -r -p "$1" a < /dev/tty || return 1
  printf '%s' "$a"
}

run_on_host() { # HOST B64PAYLOAD -> privileged apply via sudo (password prompts on tty)
  local host=$1 payload=$2
  if [ "$host" = localhost ] || [ "$host" = 127.0.0.1 ]; then
    printf '%s' "$payload" | base64 -d | sudo bash
  else
    # payload travels as an ARGUMENT: stdin must stay the user's terminal for -t
    "$SSH_BIN" -t -o ConnectTimeout=10 -- "$host" "echo '$payload' | base64 -d | sudo bash"
  fi
}

verify_remote_args() { # flags for the remote bash running our script via stdin
  printf -- "--verify --internal-local --gpu %s --cpu-p %s" "$GPU_CLOCKS" "$CPU_P_MAX_MHZ"
}

run_verify_remote() { # HOST — no sudo needed; script goes via stdin (arg-length safe)
  "$SSH_BIN" -o ConnectTimeout=10 -- "$1" \
    "SPARKTUNER_LIB=0 bash -s -- $(verify_remote_args)" < "$0"
}

print_dry_run() { # HOST
  local host=$1
  cat <<EOF
=== $host (DRY-RUN: nothing is written) ===
  files: $CONF_FILE
         /etc/systemd/system/${SERVICE_GPU}.service
         /etc/systemd/system/${SERVICE_CPU}.service
         $LIBEXEC_DIR/cpu-apply + cpu-restore
  values: gpu=$GPU_CLOCKS MHz  cpu-p=$CPU_P_MAX_MHZ MHz  governor=$GOVERNOR
  order:  GPU cap applied first (abort host on failure), then CPU, then units enabled
  note:   would disable spark-gpu-clock-limit.service if enabled (sparkLimiter adoption)
EOF
}

main() {
  parse_args "$@" || exit 2
  validate_settings || exit 2

  if [ "$INTERNAL_LOCAL" -eq 1 ]; then   # we are ON a Spark, invoked by remote --verify
    verify_host "$(hostname)" || exit 1
    exit 0
  fi

  local targets=() host pick ok=0 failed=0
  if [ ${#HOSTS[@]} -gt 0 ]; then
    targets=("${HOSTS[@]}")
  else
    [ "$VERIFY_ONLY" -eq 1 ] || [ "$LIST_ONLY" -eq 1 ] || log "No hosts given; discovering..."
    discover
    if [ ${#FOUND_T[@]} -eq 0 ]; then
      log "No DGX Sparks found. Give hosts explicitly or see --help."
      [ "$DENIED" -gt 0 ] && log "($DENIED host(s) refused your ssh key)"
      exit 1
    fi
    targets=("${FOUND_T[@]}")
  fi

  if [ "$LIST_ONLY" -eq 1 ]; then
    log "Sparks (${#targets[@]}):"
    for host in "${targets[@]}"; do log "  $host"; done
    exit 0
  fi

  if [ "$VERIFY_ONLY" -eq 1 ]; then
    for host in "${targets[@]}"; do
      echo
      if [ "$host" = localhost ] || [ "$host" = 127.0.0.1 ]; then
        verify_host "$host" && ok=$((ok + 1)) || failed=$((failed + 1))
      else
        run_verify_remote "$host" && ok=$((ok + 1)) || failed=$((failed + 1))
      fi
    done
    echo
    log "Verify done. OK: $ok  Failed: $failed"
    [ "$failed" -eq 0 ] || exit 1
    exit 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    for host in "${targets[@]}"; do print_dry_run "$host"; done
    exit 0
  fi

  if [ "$YES" -ne 1 ]; then
    log "Target Sparks (${#targets[@]}):"
    for host in "${targets[@]}"; do log "  $host"; done
    pick=$(ask "Apply to [Enter=all, numbers e.g. '1 2', q=quit]: ") || exit 1
    if [ "$pick" = q ] || [ "$pick" = Q ]; then log "Aborted."; exit 0; fi
    if [ -n "$pick" ]; then
      local sel=() i
      for i in $pick; do sel+=("${targets[$((i - 1))]:-}"); done
      targets=("${sel[@]}")
    fi
  fi

  local payload
  if [ "$UNINSTALL" -eq 1 ]; then payload=$(uninstall_payload); else payload=$(install_payload); fi
  for host in "${targets[@]}"; do
    echo
    echo "=== $host ==="
    if run_on_host "$host" "$payload"; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
  done

  echo
  log "Done. OK: $ok  Failed: $failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
}

if [ "${SPARKTUNER_LIB:-0}" != "1" ]; then main "$@"; fi
