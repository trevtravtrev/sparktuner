# tests/test_discovery.sh — pure discovery helpers (network parts tested live in Task 9)
t_assert "plain host valid"       valid_host spark-f301-ts
t_assert "user@ip valid"          valid_host trevtravtrev@10.0.0.5
t_refute "ssh option rejected"    valid_host "-oProxyCommand=evil"
t_refute "space rejected"         valid_host "a b"

t_assert "192.168 is lan"         is_lan_name 192.168.86.28
t_assert "10.x is lan"            is_lan_name 10.1.2.3
t_assert "CGNAT 100.64/10 is lan" is_lan_name 100.107.211.92
t_assert "100.112 is lan"         is_lan_name 100.112.34.84
t_refute "public ip not lan"      is_lan_name 8.8.8.8
t_assert "169.254 is lan"         is_lan_name 169.254.5.5
t_refute "100.128 not lan"        is_lan_name 100.128.0.1
t_assert ".local is lan"          is_lan_name spark-bdfd.local
t_refute "domain not lan"         is_lan_name example.com
t_assert "bare ip is addr"        is_addr 192.168.1.5
t_refute "name is not addr"       is_addr spark-a

t_eq "ssh config hosts parsed+deduped" "spark-a spark-b" \
  "$(src_ssh_config $ROOT/tests/fixtures/ssh_config | tr '\n' ' ' | sed 's/ $//')"

t_eq "probe line parsed" "abc123 spark-x" "$(parse_probe_line 'SPARK abc123 spark-x')"
t_refute "non-spark line rejected"  parse_probe_line "SPARK-with-junk"
t_refute "garbage rejected"         parse_probe_line "hello"
t_refute "trailing junk rejected"   parse_probe_line "SPARK abc123 spark-x extra"
