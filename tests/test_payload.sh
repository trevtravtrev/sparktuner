# tests/test_payload.sh — conf/unit emission + install/uninstall payloads
assert_contains()     { printf '%s\n' "$1" | grep -qF -- "$2"; }
assert_not_contains() { if printf '%s\n' "$1" | grep -qF -- "$2"; then return 1; fi; return 0; }

C=$(emit_conf)
t_assert "conf has gpu value"    assert_contains "$C" 'GPU_CLOCKS="0,2200"'
t_assert "conf has cpu value"    assert_contains "$C" 'CPU_P_MAX_MHZ="3000"'
t_assert "conf has governor"     assert_contains "$C" 'GOVERNOR="schedutil"'

U=$(emit_gpu_unit)
for want in "WantedBy=multi-user.target" "After=nvidia-persistenced.service" \
            "-lgc" "Restart=on-failure" "RemainAfterExit=yes" \
            "EnvironmentFile=/etc/sparktuner.conf" 'nvidia-smi -lgc ${GPU_CLOCKS}'; do
  t_assert "gpu unit contains: $want" assert_contains "$U" "$want"
done
t_assert "gpu unit does NOT bake clock value" assert_not_contains "$U" "-lgc 0,2200"

U=$(emit_cpu_unit)
for want in "After=nv-cpu-governor.service" "cpu-apply" "cpu-restore" \
            "StartLimitIntervalSec=0" "WantedBy=multi-user.target"; do
  t_assert "cpu unit contains: $want" assert_contains "$U" "$want"
done

P=$(install_payload); PD=$(printf '%s' "$P" | base64 -d)
t_assert "install payload parses"          bash -n <<<"$PD"
t_assert "install contains adoption"       assert_contains "$PD" "spark-gpu-clock-limit"
t_assert "install gpu-first abort guard"   assert_contains "$PD" "GPU cap failed"
t_assert "install enables both units"      assert_contains "$PD" "enable"
t_assert "install writes conf+units+helpers" assert_contains "$PD" "sparktuner-gpu-cap.service"

UP=$(uninstall_payload); UPD=$(printf '%s' "$UP" | base64 -d)
t_assert "uninstall payload parses"        bash -n <<<"$UPD"
t_assert "uninstall restores cpu"          assert_contains "$UPD" "cpu-restore"
t_assert "uninstall resets gpu clocks"     assert_contains "$UPD" "-rgc"
t_assert "uninstall hints sparkLimiter"    assert_contains "$UPD" "spark-gpu-clock-limit"
