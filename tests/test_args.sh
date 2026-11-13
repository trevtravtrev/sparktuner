# tests/test_args.sh — CLI parsing + validation (sourced by run.sh)
T() { # T "args" -> reset globals, parse+validate in a sandbox (die must not kill the file)
  (
    GPU_CLOCKS="0,2200"; CPU_P_MAX_MHZ=3000; FORCE=0; LIST_ONLY=0; VERIFY_ONLY=0
    UNINSTALL=0; DRY_RUN=0; YES=0; SCAN=0; SSH_USER=""; INTERNAL_LOCAL=0; HOSTS=()
    parse_args $1 && validate_settings
  ) 2>/dev/null
}
run_direct() { # run_direct ARGS... -> parse at file level (to inspect HOSTS etc.)
  GPU_CLOCKS="0,2200"; CPU_P_MAX_MHZ=3000; FORCE=0; LIST_ONLY=0; VERIFY_ONLY=0
  UNINSTALL=0; DRY_RUN=0; YES=0; SCAN=0; SSH_USER=""; INTERNAL_LOCAL=0; HOSTS=()
  parse_args "$@" && validate_settings
}
t_assert   "defaults valid"                    T ""
t_assert   "--gpu 0,2000 accepted"             T "--gpu 0,2000"
t_refute  "bad gpu range rejected"           T "--gpu 5000,2000"
t_refute  "gpu max over 3003 rejected"       T "--gpu 0,3200"
t_assert   "cpu-p 2808 accepted"               T "--cpu-p 2808"
t_refute  "cpu-p 1000 rejected (below floor)" T "--cpu-p 1000"
t_refute  "cpu-p 4000 rejected (above max)"   T "--cpu-p 4000"
t_refute  "cpu-p 2600 without force rejected" T "--cpu-p 2600"
t_assert   "cpu-p 2600 with --force accepted"  T "--cpu-p 2600 --force"
run_direct --gpu 0,1800 --cpu-p 2808 hostA hostB
t_eq "hosts collected" "hostA hostB" "${HOSTS[*]}"
t_refute "unknown flag rejected" T "--wat"
run_direct -n;    t_eq "-n sets LIST_ONLY"     1 "$LIST_ONLY"
run_direct --verify; t_eq "--verify sets flag" 1 "$VERIFY_ONLY"
run_direct -u;    t_eq "-u sets UNINSTALL"     1 "$UNINSTALL"
run_direct --dry-run; t_eq "--dry-run sets flag" 1 "$DRY_RUN"
run_direct --force; t_eq "--force sets flag"   1 "$FORCE"
