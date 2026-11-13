# tests/test_main.sh — main flow wiring (fake ssh; no real hosts touched)
export SSH_BIN=$ROOT/tests/fixtures/fake_ssh.sh
chmod +x "$SSH_BIN"
LOG=$ROOT/tests/ssh_calls.log
FX=$ROOT/tests/fixtures/sysfs
bash "$ROOT/tests/fixtures/make_sysfs.sh" "$FX" >/dev/null
CPU_SYSFS=$FX ORIG_FILE=$(mktemp) CPU_P_MAX_MHZ=3000 GOVERNOR=schedutil \
  bash <(emit_cpu_apply) >/dev/null

: > "$LOG"
out=$(main --dry-run 192.168.86.196 2>&1); rc=$?
t_assert "dry-run exits 0"              test "$rc" -eq 0
t_assert "dry-run shows plan"           assert_contains "$out" "DRY-RUN"
t_assert "dry-run mentions conf path"   assert_contains "$out" "/etc/sparktuner.conf"
t_eq   "dry-run calls no ssh" 0 "$(wc -l < "$LOG" | tr -d ' ')"

: > "$LOG"
out=$(main -y 192.168.86.196 2>&1); rc=$?
t_assert "install exits 0"              test "$rc" -eq 0
t_assert "install summary OK: 1"        assert_contains "$out" "OK: 1"
t_eq   "install called ssh once" 1 "$(wc -l < "$LOG" | tr -d ' ')"
t_assert "install payload via sudo bash" assert_contains "$(cat "$LOG")" "sudo bash"

: > "$LOG"
out=$(main -u -y 192.168.86.196 2>&1); rc=$?
t_assert "uninstall exits 0"            test "$rc" -eq 0
t_assert "uninstall summary OK: 1"      assert_contains "$out" "OK: 1"

: > "$LOG"
out=$(FAKE_SSH_RC=255 main -y 192.168.86.196 2>&1); rc=$?
t_assert "failed host -> exit 1"        test "$rc" -eq 1
t_assert "failed host -> Failed: 1"     assert_contains "$out" "Failed: 1"

cmd=$(verify_remote_args)
t_assert "remote verify args exist"       test -n "$cmd"
t_assert "remote verify has internal-local" assert_contains "$cmd" "--internal-local"
t_assert "remote verify carries gpu value"  assert_contains "$cmd" "--gpu 0,2200"
t_assert "remote verify carries cpu value"  assert_contains "$cmd" "--cpu-p 3000"

out=$(V_SYSFS=$FX V_LOADTEST=0 V_THERMAL=$FX/thermal \
  V_GPU_QUERY='echo 2190 MHz' V_UNIT_STATE=true main --verify localhost 2>&1); rc=$?
t_assert "verify localhost exits 0"     test "$rc" -eq 0
t_assert "verify prints host report"    assert_contains "$out" "PASS"
