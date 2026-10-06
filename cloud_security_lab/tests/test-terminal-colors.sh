#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
TEST_PROJECT_DIR="$TEMP_DIR/project"
TTY_LOG="$TEMP_DIR/terminal.log"
readonly PROJECT_DIR TEMP_DIR TEST_PROJECT_DIR TTY_LOG

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

command -v script >/dev/null 2>&1 || {
  printf 'SKIP: util-linux script is required to test terminal colors.\n'
  exit 77
}

mkdir -m 700 -p "$TEST_PROJECT_DIR/scripts"
cp -- "$PROJECT_DIR/scripts/audit.sh" "$PROJECT_DIR/scripts/load-env.sh" "$TEST_PROJECT_DIR/scripts/"
if (
  cd "$TEST_PROJECT_DIR"
  script -q -c 'bash scripts/audit.sh --local-only' "$TTY_LOG" >/dev/null 2>&1
); then
  audit_status=0
else
  audit_status=$?
fi
[[ "$audit_status" -eq 0 || "$audit_status" -eq 2 ]] || {
  printf 'FAIL: terminal color audit exited unexpectedly with %s.\n' "$audit_status" >&2
  exit 1
}

grep -q $'\033\\[' "$TTY_LOG" || {
  printf 'FAIL: interactive output contains no ANSI colors.\n' >&2
  exit 1
}
report_path="$(tr -d '\r' <"$TTY_LOG" | sed -n 's/^REPORT_JSON=//p' | tail -n 1)"
[[ -f "$report_path" ]] || {
  printf 'FAIL: terminal color audit did not create its report.\n' >&2
  exit 1
}
if grep -q $'\033\\[' "$(dirname "$report_path")/audit.log"; then
  printf 'FAIL: ANSI color codes were persisted in audit.log.\n' >&2
  exit 1
fi

printf 'PASS: interactive output is colored and the saved audit log remains plain text.\n'
