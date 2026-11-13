# tests/test_policies.sh — P/E policy discovery (sourced by run.sh)
FX=$ROOT/tests/fixtures/sysfs
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
t_eq "P policies found" \
  "policy15 policy16 policy17 policy18 policy19 policy5 policy6 policy7 policy8 policy9" \
  "$(discover_policies "$FX" | sort | tr '\n' ' ' | sed 's/ $//')"
t_eq "E policies found" \
  "policy0 policy1 policy10 policy11 policy12 policy13 policy14 policy2 policy3 policy4" \
  "$(discover_e_policies "$FX" | sort | tr '\n' ' ' | sed 's/ $//')"
FX2=$ROOT/tests/fixtures/sysfs_broken
rm -rf "$FX2"; mkdir -p "$FX2/policy9"   # cpuinfo_max_freq missing
t_eq "broken policy skipped by P" "" "$(discover_policies "$FX2")"
t_eq "broken policy skipped by E" "" "$(discover_e_policies "$FX2")"
