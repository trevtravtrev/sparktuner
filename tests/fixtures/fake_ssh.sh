#!/usr/bin/env bash
# tests/fixtures/fake_ssh — records invocation, simulates success (or failure via FAKE_SSH_RC)
LOG="$(dirname "$0")/../ssh_calls.log"
echo "ssh $*" >> "$LOG"
exit "${FAKE_SSH_RC:-0}"
