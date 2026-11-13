# tests/test_verify.sh — verify_host report logic (sourced by run.sh)
FX=$ROOT/tests/fixtures/sysfs
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
CPU_SYSFS=$FX ORIG_FILE=$(mktemp) CPU_P_MAX_MHZ=3000 GOVERNOR=schedutil \
  bash <(emit_cpu_apply) >/dev/null

run_v() { # capture output + rc
  V_SYSFS=$FX V_LOADTEST=0 V_THERMAL=$FX/thermal \
    V_GPU_QUERY='echo 2190 MHz' V_UNIT_STATE=true verify_host spark-fake
  echo "rc=$?"
}

out=$(run_v)
t_assert "verify rc=0 on capped fixture"  bash -c "printf '%s' '$out' | grep -q 'rc=0'"
t_assert "gpu line PASS"                   bash -c "printf '%s' '$out' | grep -q 'GPU.*PASS'"
t_assert "policy lines PASS"               bash -c "printf '%s' '$out' | grep -q 'policy5.*PASS'"
t_assert "E-core line PASS"                bash -c "printf '%s' '$out' | grep -q '(E).*PASS'"
t_assert "governor line PASS"              bash -c "printf '%s' '$out' | grep -q 'governor=schedutil.*PASS'"
t_refute "no FAIL lines when healthy"      bash -c "printf '%s' '$out' | grep -q 'FAIL'"

printf '%s' 3900000 > $FX/policy8/scaling_max_freq
out=$(run_v)
t_assert "uncapped policy FAILs"           bash -c "printf '%s' '$out' | grep -q 'policy8.*FAIL'"
t_assert "rc=1 on failure"                 bash -c "printf '%s' '$out' | grep -q 'rc=1'"

bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
CPU_SYSFS=$FX ORIG_FILE=$(mktemp) CPU_P_MAX_MHZ=3000 GOVERNOR=schedutil \
  bash <(emit_cpu_apply) >/dev/null
printf '%s' 2600000 > $FX/policy0/scaling_max_freq
printf '%s' performance > $FX/policy3/scaling_governor
out=$(run_v)
t_assert "tampered E-core FAILs"           bash -c "printf '%s' '$out' | grep -q 'policy0.*(E).*FAIL'"
t_assert "wrong governor FAILs"            bash -c "printf '%s' '$out' | grep -q 'policy3.*governor.*FAIL'"

out=$(V_SYSFS=$FX V_LOADTEST=0 V_THERMAL=$FX/thermal \
  V_GPU_QUERY='echo 2900 MHz' V_UNIT_STATE=true verify_host spark-fake; echo "rc=$?")
t_assert "over-cap GPU clock FAILs"        bash -c "printf '%s' '$out' | grep -q 'GPU.*FAIL'"
