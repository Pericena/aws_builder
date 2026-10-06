#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly MCP_SERVER="$PROJECT_DIR/scripts/mcp-server.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'SKIP: jq is required for MCP protocol tests.\n'
  exit 77
}

input="$(
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"aws_security_audit","arguments":{"command":"not-allowed"}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"not-a-tool","arguments":{}}}'
)"
output="$(printf '%s\n' "$input" | bash "$MCP_SERVER")"

[[ "$(wc -l <<<"$output" | tr -d ' ')" == "4" ]] || {
  printf 'FAIL: expected four JSON-RPC responses.\n' >&2
  exit 1
}

initialize="$(sed -n '1p' <<<"$output")"
tools="$(sed -n '2p' <<<"$output")"
rejected_args="$(sed -n '3p' <<<"$output")"
rejected_name="$(sed -n '4p' <<<"$output")"

jq -e '.id==1 and .result.serverInfo.name=="aws-cloud-security-lab-auditor" and (.result.capabilities.tools|type=="object")' <<<"$initialize" >/dev/null
jq -e '.id==2 and (.result.tools|length)==1 and .result.tools[0].name=="aws_security_audit" and .result.tools[0].inputSchema.additionalProperties==false' <<<"$tools" >/dev/null
jq -e '.id==3 and .result.isError==true' <<<"$rejected_args" >/dev/null
jq -e '.id==4 and .result.isError==true' <<<"$rejected_name" >/dev/null

printf 'PASS: stdio initialize, discovery and caller-input rejection.\n'
