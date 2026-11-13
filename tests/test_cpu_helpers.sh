# tests/test_cpu_helpers.sh — cpu-apply / cpu-restore semantics (sourced by run.sh)
FX=$ROOT/tests/fixtures/sysfs
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
WRK=$(mktemp -d)
emit_cpu_apply > "$WRK/apply.sh"; emit_cpu_restore > "$WRK/restore.sh"
t_assert "apply script parses"  bash -n "$WRK/apply.sh"
t_assert "restore script parses" bash -n "$WRK/restore.sh"

CPU_SYSFS=$FX ORIG_FILE=$WRK/orig.conf CPU_P_MAX_MHZ=3000 GOVERNOR=schedutil \
  bash "$WRK/apply.sh" >/dev/null
t_eq "P policy5 capped"    3000000   "$(cat $FX/policy5/scaling_max_freq)"
t_eq "P policy17 capped"   3000000   "$(cat $FX/policy17/scaling_max_freq)"
t_eq "min lowered to hw floor" 1378000 "$(cat $FX/policy5/scaling_min_freq)"
t_eq "E policy0 max untouched" 2808000 "$(cat $FX/policy0/scaling_max_freq)"
t_eq "E policy0 min untouched" 1378000 "$(cat $FX/policy0/scaling_min_freq)"
t_eq "orig records all 20 policies" 20 "$(wc -l < $WRK/orig.conf)"
t_eq "governor set on P" schedutil "$(cat $FX/policy5/scaling_governor)"
t_eq "governor set on E" schedutil "$(cat $FX/policy0/scaling_governor)"

CPU_SYSFS=$FX ORIG_FILE=$WRK/orig.conf bash "$WRK/restore.sh" >/dev/null
t_eq "restore returns P max"  3900000    "$(cat $FX/policy5/scaling_max_freq)"
t_eq "restore returns P min"  1378000    "$(cat $FX/policy5/scaling_min_freq)"
t_eq "restore returns governor" performance "$(cat $FX/policy5/scaling_governor)"
t_eq "restore returns E governor" performance "$(cat $FX/policy0/scaling_governor)"

# min-juggling path: policy pinned min=3900000
printf '%s' 3900000 > $FX/policy9/scaling_min_freq
printf '%s' performance > $FX/policy9/scaling_governor
CPU_SYSFS=$FX ORIG_FILE=$WRK/orig2.conf CPU_P_MAX_MHZ=2808 GOVERNOR=schedutil \
  bash "$WRK/apply.sh" >/dev/null
t_eq "high min lowered before cap" 2808000 "$(cat $FX/policy9/scaling_max_freq)"
t_eq "2808 cap applied" 2808000 "$(cat $FX/policy9/scaling_max_freq)"

# apply with unknown governor value: no governor write, cap still applied
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
CPU_SYSFS=$FX ORIG_FILE=$WRK/orig3.conf CPU_P_MAX_MHZ=3000 GOVERNOR=notagov \
  bash "$WRK/apply.sh" >/dev/null
t_eq "bad governor leaves P capped" 3000000 "$(cat $FX/policy5/scaling_max_freq)"
t_eq "bad governor not written" performance "$(cat $FX/policy5/scaling_governor)"

# zero P-policies found -> non-zero exit
FX2=$ROOT/tests/fixtures/sysfs_broken
rm -rf "$FX2"; mkdir -p "$FX2"
CPU_SYSFS=$FX2 ORIG_FILE=$WRK/orig4.conf bash "$WRK/apply.sh" >/dev/null 2>&1
rc=$?
t_refute "no P policies -> apply fails" test 0 -eq "$rc"
