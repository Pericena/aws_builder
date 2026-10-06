#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_DIR
readonly AUDIT_SCRIPT="$SCRIPT_DIR/audit.sh"
readonly SUPPORTED_PROTOCOLS='["2024-11-05","2025-03-26"]'
initialized=false
RESPONSE_JSON=""

source "$SCRIPT_DIR/load-env.sh"
load_project_env "$PROJECT_DIR" || exit 1

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required by the stdio MCP server.\n' >&2
  exit 1
fi

send_json() {
  printf '%s\n' "$1"
}

rpc_error() {
  local request_id="$1"
  local code="$2"
  local message="$3"
  jq -cn --argjson id "$request_id" --argjson code "$code" --arg message "$message" \
    '{jsonrpc:"2.0",id:$id,error:{code:$code,message:$message}}'
}

tool_result() {
  local request_id="$1"
  local text="$2"
  local is_error="$3"
  jq -cn --argjson id "$request_id" --arg text "$text" --argjson is_error "$is_error" \
    '{jsonrpc:"2.0",id:$id,result:{content:[{type:"text",text:$text}],isError:$is_error}}'
}

handle_request() {
  local request="$1"
  local request_id
  local method
  local params
  local protocol
  local requested_protocol
  local tool_name
  local arguments
  local audit_output
  local audit_status=0
  local report_path
  local report_text

  if ! jq -e 'type=="object" and .jsonrpc=="2.0" and (.method|type=="string")' >/dev/null 2>&1 <<<"$request"; then
    RESPONSE_JSON="$(rpc_error "null" "-32600" "Invalid Request")"
    return
  fi
  request_id="$(jq -c '.id // null' <<<"$request")"
  method="$(jq -r '.method' <<<"$request")"
  params="$(jq -c '.params // {}' <<<"$request")"

  if [[ "$method" == "notifications/initialized" || "$method" == "notifications/cancelled" ]]; then
    return
  fi

  case "$method" in
    initialize)
      if [[ "$request_id" == "null" ]]; then
        return
      fi
      requested_protocol="$(jq -r '.protocolVersion // empty' <<<"$params")"
      if [[ -z "$requested_protocol" ]]; then
        RESPONSE_JSON="$(rpc_error "$request_id" "-32602" "Missing protocolVersion")"
        return
      fi
      if jq -e --arg version "$requested_protocol" 'index($version) != null' <<<"$SUPPORTED_PROTOCOLS" >/dev/null; then
        protocol="$requested_protocol"
      else
        protocol="2025-03-26"
      fi
      initialized=true
      RESPONSE_JSON="$(jq -cn --argjson id "$request_id" --arg protocol "$protocol" \
        '{jsonrpc:"2.0",id:$id,result:{protocolVersion:$protocol,capabilities:{tools:{}},serverInfo:{name:"aws-cloud-security-lab-auditor",version:"1.0.0"}}}'
      )"
      ;;
    ping)
      if [[ "$request_id" != "null" ]]; then
        RESPONSE_JSON="$(jq -cn --argjson id "$request_id" '{jsonrpc:"2.0",id:$id,result:{}}')"
      fi
      ;;
    tools/list)
      [[ "$request_id" != "null" ]] || return
      if [[ "$initialized" != "true" ]]; then
        RESPONSE_JSON="$(rpc_error "$request_id" "-32002" "Server not initialized")"
        return
      fi
      RESPONSE_JSON="$(jq -cn --argjson id "$request_id" \
        '{jsonrpc:"2.0",id:$id,result:{tools:[{name:"aws_security_audit",description:"Ejecuta la auditoría interna de hardening Linux y AWS en modo de solo lectura; devuelve el reporte JSON.",inputSchema:{type:"object",properties:{},additionalProperties:false}}]}}'
      )"
      ;;
    tools/call)
      [[ "$request_id" != "null" ]] || return
      if [[ "$initialized" != "true" ]]; then
        RESPONSE_JSON="$(rpc_error "$request_id" "-32002" "Server not initialized")"
        return
      fi
      tool_name="$(jq -r '.name // empty' <<<"$params")"
      arguments="$(jq -c '.arguments // {}' <<<"$params")"
      if [[ "$tool_name" != "aws_security_audit" ]]; then
        RESPONSE_JSON="$(tool_result "$request_id" "Herramienta desconocida." true)"
        return
      fi
      if ! jq -e 'type=="object" and length==0' >/dev/null 2>&1 <<<"$arguments"; then
        RESPONSE_JSON="$(tool_result "$request_id" "La herramienta no acepta argumentos. Configura AWS_REGION y la identidad AWS mediante .env o el entorno seguro del servidor." true)"
        return
      fi
      if audit_output="$(bash "$AUDIT_SCRIPT" 2>&1)"; then
        audit_status=0
      else
        audit_status=$?
      fi
      report_path="$(sed -n 's/^REPORT_JSON=//p' <<<"$audit_output" | tail -n 1)"
      case "$report_path" in
        "$PROJECT_DIR"/reports/*/report.json) ;;
        *)
          printf 'MCP auditor: audit script did not return an expected report path (exit=%s).\n' "$audit_status" >&2
          RESPONSE_JSON="$(tool_result "$request_id" "No se pudo generar el informe. Revisa identidad AWS, región, dependencias y logs del servidor." true)"
          return
          ;;
      esac
      if [[ ! -f "$report_path" || -L "$report_path" ]] || ! jq -e '.tool=="AWS Cloud Security Lab Internal Auditor" and .read_only==true' "$report_path" >/dev/null 2>&1; then
        printf 'MCP auditor: report validation failed (exit=%s).\n' "$audit_status" >&2
        RESPONSE_JSON="$(tool_result "$request_id" "El informe no existe o no pasó la validación de solo lectura." true)"
        return
      fi
      report_text="$(jq -c . "$report_path")"
      if [[ "$audit_status" -eq 0 ]]; then
        RESPONSE_JSON="$(tool_result "$request_id" "$report_text" false)"
      elif [[ "$audit_status" -eq 2 ]]; then
        RESPONSE_JSON="$(tool_result "$request_id" "AUDITORÍA INCOMPLETA: hay controles sin verificar. ${report_text}" true)"
      else
        printf 'MCP auditor: audit script failed (exit=%s).\n' "$audit_status" >&2
        RESPONSE_JSON="$(tool_result "$request_id" "La auditoría terminó con error. Revisa el log del servidor." true)"
      fi
      ;;
    *)
      if [[ "$request_id" != "null" ]]; then
        RESPONSE_JSON="$(rpc_error "$request_id" "-32601" "Method not found")"
      fi
      ;;
  esac
}

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
    send_json "$(rpc_error "null" "-32700" "Parse error")"
    continue
  fi
  RESPONSE_JSON=""
  handle_request "$line"
  [[ -n "$RESPONSE_JSON" ]] && send_json "$RESPONSE_JSON"
done
