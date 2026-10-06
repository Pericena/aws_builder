#!/usr/bin/env bash

load_project_env() {
  local project_dir="$1"
  local env_file="$project_dir/.env"
  local line
  local key
  local value

  [[ -e "$env_file" || -L "$env_file" ]] || return 0
  if [[ ! -f "$env_file" || -L "$env_file" ]]; then
    printf 'ERROR: .env debe ser un archivo regular, no un enlace simbólico.\n' >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      printf 'ERROR: línea inválida en .env; usa KEY=VALUE sin comandos ni expansiones.\n' >&2
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      AWS_REGION|AWS_DEFAULT_REGION|AWS_EXPECTED_ACCOUNT_ID|AWS_PROFILE) ;;
      *)
        printf 'ERROR: variable no permitida en .env: %s\n' "$key" >&2
        return 1
        ;;
    esac

    value="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$value")"
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \"* || "$value" == \'* ]]; then
      printf 'ERROR: comillas sin cerrar en .env para %s.\n' "$key" >&2
      return 1
    fi

    if [[ -z "${!key:-}" ]]; then
      if [[ "$key" == "AWS_PROFILE" && -z "$value" ]]; then
        unset AWS_PROFILE
      else
        export "$key=$value"
      fi
    fi
  done <"$env_file"
}
