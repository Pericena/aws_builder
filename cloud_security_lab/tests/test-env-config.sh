#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
readonly PROJECT_DIR TEMP_DIR

cleanup() {
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -m 700 -p "$TEMP_DIR/scripts"
cp -- "$PROJECT_DIR/scripts/load-env.sh" "$TEMP_DIR/scripts/"
cat >"$TEMP_DIR/.env" <<EOF
# Auditor settings
AWS_REGION="us-east-2"
AWS_EXPECTED_ACCOUNT_ID=123456789012
AWS_PROFILE=
AWS_DEFAULT_REGION=us-west-2
EOF

if (
  unset AWS_REGION AWS_DEFAULT_REGION AWS_EXPECTED_ACCOUNT_ID AWS_PROFILE
  source "$TEMP_DIR/scripts/load-env.sh"
  load_project_env "$TEMP_DIR"
  [[ "$AWS_REGION" == "us-east-2" ]]
  [[ "$AWS_EXPECTED_ACCOUNT_ID" == "123456789012" ]]
  [[ "$AWS_DEFAULT_REGION" == "us-west-2" ]]
  [[ -z "${AWS_PROFILE:-}" ]]
); then
  :
else
  printf 'FAIL: .env values were not loaded as expected.\n' >&2
  exit 1
fi
[[ ! -e "$TEMP_DIR/injected" ]] || {
  printf 'FAIL: .env content was executed as shell code.\n' >&2
  exit 1
}

printf 'AWS_PROFILE=$(touch "%s/injected")\n' "$TEMP_DIR" >"$TEMP_DIR/.env"
if (
  unset AWS_PROFILE
  source "$TEMP_DIR/scripts/load-env.sh"
  load_project_env "$TEMP_DIR"
  [[ "$AWS_PROFILE" == "\$(touch \"$TEMP_DIR/injected\")" ]]
); then
  :
else
  printf 'FAIL: .env command-shaped value was not treated as a literal.\n' >&2
  exit 1
fi
[[ ! -e "$TEMP_DIR/injected" ]] || {
  printf 'FAIL: .env command-shaped value was executed.\n' >&2
  exit 1
}

if (
  export AWS_REGION=eu-west-1
  unset AWS_EXPECTED_ACCOUNT_ID AWS_DEFAULT_REGION AWS_PROFILE
  source "$TEMP_DIR/scripts/load-env.sh"
  load_project_env "$TEMP_DIR"
  [[ "$AWS_REGION" == "eu-west-1" ]]
); then
  :
else
  printf 'FAIL: exported environment did not override .env.\n' >&2
  exit 1
fi

printf 'AWS_SECRET_ACCESS_KEY=not-allowed\n' >"$TEMP_DIR/.env"
if (
  unset AWS_REGION AWS_DEFAULT_REGION AWS_EXPECTED_ACCOUNT_ID AWS_PROFILE
  source "$TEMP_DIR/scripts/load-env.sh"
  load_project_env "$TEMP_DIR"
) 2>/dev/null; then
  printf 'FAIL: .env accepted a credential variable.\n' >&2
  exit 1
fi

printf 'PASS: .env loading, environment precedence, safe parsing, and unsupported-key rejection.\n'
