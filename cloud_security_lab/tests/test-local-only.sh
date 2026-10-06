#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
TEST_PROJECT_DIR="$TEMP_DIR/project"
readonly PROJECT_DIR TEMP_DIR TEST_PROJECT_DIR

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -m 700 -p "$TEST_PROJECT_DIR/scripts"
cp -- "$PROJECT_DIR/scripts/audit.sh" "$PROJECT_DIR/scripts/load-env.sh" "$TEST_PROJECT_DIR/scripts/"

if output="$(cd "$TEST_PROJECT_DIR" && bash scripts/audit.sh --local-only 2>&1)"; then
  audit_status=0
else
  audit_status=$?
fi
[[ "$audit_status" -eq 0 || "$audit_status" -eq 2 ]] || {
  printf '%s\n' "$output" >&2
  printf 'FAIL: local-only audit exited unexpectedly with %s.\n' "$audit_status" >&2
  exit 1
}

report_path="$(sed -n 's/^REPORT_JSON=//p' <<<"$output" | tail -n 1)"
[[ -f "$report_path" ]] || {
  printf '%s\n' "$output" >&2
  printf 'FAIL: local-only audit did not create report.json.\n' >&2
  exit 1
}
run_dir="$(dirname "$report_path")"
[[ "$(stat -c '%a' "$TEST_PROJECT_DIR/reports")" == "700" ]]
[[ "$(stat -c '%a' "$run_dir")" == "700" ]]
[[ "$(stat -c '%a' "$report_path")" == "600" ]]
jq -e '
  .read_only == true
  and .scope.local_linux == true
  and .scope.aws_region == null
  and .scope.aws_s3_scope == "not-audited"
  and ([.checks[] | select(.control=="AWS-SCOPE" and .status=="INFO")] | length) == 1
' "$report_path" >/dev/null
(cd "$run_dir" && sha256sum -c SHA256SUMS) >/dev/null

printf 'PASS: local-only audit report, scope, private permissions and evidence hashes.\n'
