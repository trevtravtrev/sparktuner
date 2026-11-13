#!/usr/bin/env bash
# tests/fixtures/make_sysfs.sh — builds a fake cpufreq tree at $1 (idempotent)
set -eu
ROOT=${1:?usage: make_sysfs.sh DIR}
rm -rf "$ROOT"; mkdir -p "$ROOT"
mk() { # mk NAME MAXFREQ [MINFREQ]
  local d=$ROOT/$1 max=$2 min=${3:-1378000}
  mkdir -p "$d"
  printf '%s' "$max" > "$d/cpuinfo_max_freq"
  printf '%s' "$min" > "$d/cpuinfo_min_freq"
  printf '%s' "$max" > "$d/scaling_max_freq"
  printf '%s' "$min" > "$d/scaling_min_freq"
  printf '%s' "$max" > "$d/scaling_cur_freq"
  printf '%s' "$((max / 2))" > "$d/cpuinfo_avg_freq"
  printf 'performance' > "$d/scaling_governor"
  printf 'conservative ondemand userspace powersave performance schedutil' > "$d/scaling_available_governors"
  printf '5 6 7' > "$d/affected_cpus"
}
for e in 0 1 2 3 4 10 11 12 13 14; do mk "policy$e" 2808000; done
for p in 5 6 7 8 9 15 16 17 18 19; do mk "policy$p" 3900000; done
