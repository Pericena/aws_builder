#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly AUDIT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_DIR
readonly REPORT_ROOT="$PROJECT_DIR/reports"

source "$SCRIPT_DIR/load-env.sh"
load_project_env "$PROJECT_DIR" || exit 1

LOCAL_ONLY=false
AWS_REGION_SELECTED="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
RUN_DIR=""
REPORT_FILE=""
AUDIT_LOG=""
AWS_OUTPUT=""
AWS_ERROR_CODE=""
CHECKS_JSON='[]'
INVENTORY_JSON='{}'
ACCOUNT_ID=""
COLOR_ENABLED=false
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  COLOR_ENABLED=true
fi

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

paint() {
  local color="$1"
  shift
  if [[ "$COLOR_ENABLED" == "true" ]]; then
    printf '\033[%sm%s\033[0m' "$color" "$*"
  else
    printf '%s' "$*"
  fi
}

print_phase() {
  printf '\n'
  paint '1;36' "$1"
  printf '\n'
}

usage() {
  cat <<'EOF'
Auditor interno de hardening Linux y AWS (solo lectura)

Uso:
  bash scripts/audit.sh [--local-only] [--region REGION]

Configuración:
  Lee AWS_REGION, AWS_DEFAULT_REGION, AWS_EXPECTED_ACCOUNT_ID y AWS_PROFILE
  desde .env si existen. Las variables exportadas en el entorno tienen
  prioridad. Consulta .env.example para ver el formato.

Opciones:
  --local-only       Revisa solo este Ubuntu; no necesita AWS CLI ni región.
  --region REGION   Región AWS para EC2, IAM regional, CloudTrail regional,
                    CloudWatch, Config, GuardDuty, Security Hub y RDS.
  -h, --help        Muestra esta ayuda.

Variables:
  AWS_PROFILE              Perfil AWS CLI opcional.
  AWS_REGION               Región objetivo (preferida).
  AWS_DEFAULT_REGION       Región alternativa.
  AWS_EXPECTED_ACCOUNT_ID  ID de 12 dígitos para impedir revisar otra cuenta.

Alcance:
  - Lee controles locales del servidor donde se ejecuta (Ubuntu/Debian).
  - Revisa buckets S3 de toda la cuenta y servicios regionales solo en la
    región configurada.
  - No instala, cambia, detiene ni elimina recursos o servicios.
  - No lee contraseñas, tokens, claves privadas ni el contenido de archivos
    de configuración sensibles.
  - Genera report.json, audit.log, bundle.tar.gz y SHA256SUMS en reports/<run-id>.
  - Los informes contienen datos internos de seguridad. Conserva el directorio
    con permisos privados y no lo publiques sin revisar/redactar.

Requisitos:
  Bash 4+, jq 1.6+, tar, sha256sum. Para AWS: AWS CLI v2 e identidad
  autorizada de solo lectura. Se recomienda ejecutar como root para obtener
  una revisión local más completa; el script no usa sudo automáticamente.
EOF
}

while (($#)); do
  case "$1" in
    --local-only)
      LOCAL_ONLY=true
      shift
      ;;
    --region)
      (($# >= 2)) || fail "Falta la región después de --region."
      AWS_REGION_SELECTED="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Opción no reconocida: $1. Usa --help."
      ;;
  esac
done

for tool in jq tar sha256sum tee stat find getent awk cut tr grep sed head wc hostname date id sort; do
  command -v "$tool" >/dev/null 2>&1 || fail "No se encuentra '$tool'. Instala las dependencias indicadas en README.md."
done

[[ "$(uname -s)" == "Linux" ]] || fail "La auditoría local requiere Linux; ejecuta el script en Ubuntu/WSL."
[[ -r /etc/os-release ]] || fail "No se encontró /etc/os-release."
if [[ "$LOCAL_ONLY" != "true" ]]; then
  [[ -n "$AWS_REGION_SELECTED" ]] || fail "Define AWS_REGION o AWS_DEFAULT_REGION, o usa --local-only."
  command -v aws >/dev/null 2>&1 || fail "No se encontró AWS CLI v2."
  aws_version_output="$(aws --version 2>&1)" || fail "No se pudo comprobar la versión de AWS CLI."
  [[ "$aws_version_output" == aws-cli/2.* ]] || fail "Se requiere AWS CLI v2; versión detectada: $aws_version_output"
  if [[ -n "${AWS_EXPECTED_ACCOUNT_ID:-}" && ! "$AWS_EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    fail "AWS_EXPECTED_ACCOUNT_ID debe contener exactamente 12 dígitos."
  fi
fi

[[ ! -L "$REPORT_ROOT" ]] || fail "El directorio reports/ no puede ser un enlace simbólico."
mkdir -p -- "$REPORT_ROOT"
[[ -d "$REPORT_ROOT" && ! -L "$REPORT_ROOT" ]] || fail "reports/ no es un directorio local seguro."
chmod 700 "$REPORT_ROOT"
report_root_mode="$(stat -c '%a' "$REPORT_ROOT")"
[[ "$report_root_mode" == "700" ]] || fail "El filesystem no aplica permisos privados a reports/ (modo observado=$report_root_mode). Ejecuta el proyecto desde un filesystem Linux que respete chmod; no guardes evidencia en /mnt/c sin metadatos de permisos."
host_slug="$(hostname -s 2>/dev/null | tr -cd '[:alnum:]._-' | cut -c1-48)"
[[ -n "$host_slug" ]] || host_slug="linux-host"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-${host_slug}-$$"
RUN_DIR="$REPORT_ROOT/$run_id"
mkdir -m 700 -- "$RUN_DIR" || fail "No se pudo crear el directorio de evidencia."
REPORT_FILE="$RUN_DIR/report.json"
AUDIT_LOG="$RUN_DIR/audit.log"
exec 3>&1
exec > >(tee -a "$AUDIT_LOG") 2>&1
tee_pid=$!

record_check() {
  local scope="$1"
  local status="$2"
  local severity="$3"
  local control="$4"
  local resource="$5"
  local evidence="$6"
  local recommendation="$7"

  CHECKS_JSON="$(
    jq \
      --arg scope "$scope" \
      --arg status "$status" \
      --arg severity "$severity" \
      --arg control "$control" \
      --arg resource "$resource" \
      --arg evidence "$evidence" \
      --arg recommendation "$recommendation" \
      '. + [{
        scope: $scope,
        status: $status,
        severity: $severity,
        control: $control,
        resource: $resource,
        evidence: $evidence,
        recommendation: $recommendation
      }]' <<<"$CHECKS_JSON"
  )"

  local status_color="36"
  case "$status" in
    PASS) status_color="32" ;;
    INFO) status_color="36" ;;
    WARN) status_color="33" ;;
    FAIL) status_color="31;1" ;;
    ERROR) status_color="35" ;;
  esac
  printf '['
  paint "$status_color" "$status"
  printf '/%s] %s — %s\n' "$severity" "$control" "$evidence"
}

record_inventory() {
  local key="$1"
  local json_value="$2"
  INVENTORY_JSON="$(jq --arg key "$key" --argjson value "$json_value" '. + {($key): $value}' <<<"$INVENTORY_JSON")"
}

api_error() {
  local control="$1"
  local resource="$2"
  local action="$3"
  local severity="${4:-N/A}"
  record_check \
    "AWS" \
    "ERROR" \
    "$severity" \
    "$control" \
    "$resource" \
    "No se pudo ejecutar $action (código AWS: ${AWS_ERROR_CODE:-AWSCLIError}); control sin verificar." \
    "Verifica sesión, región y permiso de solo lectura requerido; no interpretes el control como PASS."
}

aws_json() {
  local error_file
  local status
  error_file="$(mktemp "$RUN_DIR/.aws-error.XXXXXX")" || fail "No se pudo crear archivo temporal seguro."
  if AWS_OUTPUT="$(aws "$@" --output json 2>"$error_file")"; then
    AWS_ERROR_CODE=""
    rm -f -- "$error_file"
    return 0
  else
    status=$?
    AWS_ERROR_CODE="$(sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' "$error_file" | head -n 1)"
    [[ -n "$AWS_ERROR_CODE" ]] || AWS_ERROR_CODE="AWSCLIError"
    rm -f -- "$error_file"
    return "$status"
  fi
}

aws_region_json() {
  local region="$1"
  shift
  aws_json "$@" --region "$region"
}

check_service_state() {
  local service="$1"
  local active_state="unknown"
  local enabled_state="unknown"
  local status="WARN"
  local severity="MEDIUM"
  local recommendation="Instala y habilita este control si corresponde a la política operativa del servidor."

  if ! command -v systemctl >/dev/null 2>&1; then
    record_check "HOST" "ERROR" "N/A" "HOST-SERVICE-$service" "$service" "systemctl no está disponible; estado del servicio sin verificar." "Revisa el control local manualmente."
    return
  fi

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    active_state="active"
    status="PASS"
    severity="INFO"
    recommendation=""
  elif systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q "^${service}\.service"; then
    active_state="inactive"
  else
    active_state="not-installed"
  fi
  enabled_state="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  [[ -n "$enabled_state" ]] || enabled_state="unknown"

  record_check \
    "HOST" "$status" "$severity" "HOST-SERVICE-$service" "$service" \
    "active=$active_state; enabled=$enabled_state." "$recommendation"
}

check_host() {
  local os_name
  local os_id
  local kernel
  local uid
  local socket_lines
  local package_updates
  local firewall_status=""
  local sshd_effective=""
  local ssh_value
  local ssh_key
  local ssh_severity
  local ssh_status
  local ssh_recommendation
  local file_mode
  local file_owner
  local group_name
  local shadow_mode_bits
  local shadow_permissions_safe
  local journal_errors
  local journal_disk
  local journal_persistent
  local root_fs_type
  local authorized_keys_json='[]'
  local local_users_json
  local sudo_members
  local root_uid_duplicates

  print_phase 'PASO 1/4 — Identificar el servidor Ubuntu/Debian'
  printf 'Se revisan el sistema operativo, el kernel, las cuentas locales y el acceso administrativo.\n'
  os_name="$(awk -F= '$1=="PRETTY_NAME" {sub(/^[^=]*=/,""); gsub(/^["\047]|["\047]$/,""); print; exit}' /etc/os-release)"
  os_id="$(awk -F= '$1=="ID" {gsub(/["\047]/,"",$2); print $2; exit}' /etc/os-release)"
  [[ -n "$os_name" ]] || os_name="Linux"
  [[ -n "$os_id" ]] || os_id="unknown"
  kernel="$(uname -r)"
  uid="$(id -u)"

  record_inventory "host" "$(jq -n \
    --arg hostname "$(hostname -f 2>/dev/null || hostname)" \
    --arg os "$os_name" \
    --arg os_id "$os_id" \
    --arg kernel "$kernel" \
    --arg audited_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg auditor_uid "$uid" \
    '{hostname:$hostname, os:$os, os_id:$os_id, kernel:$kernel, audited_at_utc:$audited_at, auditor_uid:($auditor_uid|tonumber)}')"
  local_users_json="$(getent passwd | awk -F: '$3 == 0 || ($3 >= 1000 && $7 !~ /(nologin|false)$/) {print $1 "\t" $3 "\t" $7}' | jq -Rn '[inputs | select(length>0) | split("\t") | {username:.[0],uid:(.[1]|tonumber),login_shell:.[2]}]')"
  record_inventory "local_accounts" "$local_users_json"
  root_uid_duplicates="$(jq '[.[] | select(.uid==0 and .username!="root")] | length' <<<"$local_users_json")"
  if ((root_uid_duplicates == 0)); then
    record_check "HOST" "PASS" "INFO" "HOST-ROOT-UID-UNIQUENESS" "local accounts" "No se encontraron cuentas adicionales con UID 0." ""
  else
    record_check "HOST" "FAIL" "CRITICAL" "HOST-ROOT-UID-UNIQUENESS" "local accounts" "$root_uid_duplicates cuenta(s) distinta(s) de root tienen UID 0." "Investiga y elimina privilegios UID 0 no aprobados."
  fi
  sudo_members="$(getent group sudo 2>/dev/null | awk -F: '{print $4}' || true)"
  [[ -n "$sudo_members" ]] || sudo_members=""
  record_inventory "sudo_group_members" "$(jq -Rn --arg members "$sudo_members" '($members|split(",")|map(select(length>0)))')"
  record_check "HOST" "INFO" "INFO" "HOST-SUDO-MEMBERS" "sudo group" "Hay $(jq -Rn --arg members "$sudo_members" '($members|split(",")|map(select(length>0))|length)') miembro(s) directos en el grupo sudo; consulta inventory.sudo_group_members." "Valida que cada miembro conserve necesidad y autorización."

  if [[ "$os_id" == "ubuntu" || "$os_id" == "debian" ]]; then
    record_check "HOST" "PASS" "INFO" "HOST-OS" "$os_name" "Sistema identificado como $os_name; kernel $kernel." ""
  else
    record_check "HOST" "WARN" "MEDIUM" "HOST-OS" "$os_name" "Distribución '$os_id' fuera de la validación objetivo Ubuntu/Debian." "Confirma compatibilidad de cada control con esta distribución."
  fi
  if [[ "$uid" == "0" ]]; then
    record_check "HOST" "PASS" "INFO" "HOST-AUDIT-PRIVILEGE" "local" "Auditor ejecutado como root; controles locales pueden consultarse con mayor cobertura." ""
  else
    record_check "HOST" "WARN" "LOW" "HOST-AUDIT-PRIVILEGE" "local" "Auditor ejecutado sin root; algunas comprobaciones locales pueden quedar incompletas." "Ejecuta como root únicamente si la política del servidor lo permite; el script no invoca sudo."
  fi

  print_phase 'PASO 1.2 — Revisar hardening local'
  printf 'Se revisan actualizaciones disponibles en caché, firewall, puertos, SSH y permisos sensibles.\n'
  if command -v apt-get >/dev/null 2>&1; then
    package_updates="$(apt-get -s upgrade 2>/dev/null | awk '$1 == "Inst" {n++} END {print n+0}' || true)"
    if [[ "$package_updates" =~ ^[0-9]+$ ]]; then
      record_inventory "apt_upgradable_package_count" "$package_updates"
      if ((package_updates == 0)); then
        record_check "HOST" "PASS" "INFO" "HOST-PACKAGE-UPDATES" "apt" "La simulación local de apt no identificó paquetes actualizables en la caché disponible." ""
      else
        record_check "HOST" "WARN" "MEDIUM" "HOST-PACKAGE-UPDATES" "apt" "$package_updates paquete(s) aparecen actualizables según la caché local; no se consultó ni instaló nada." "Revisa los avisos de seguridad y aplica actualizaciones en una ventana aprobada."
      fi
    else
      record_check "HOST" "ERROR" "N/A" "HOST-PACKAGE-UPDATES" "apt" "No se pudo interpretar la simulación de paquetes." "Verifica apt manualmente."
    fi
  else
    record_check "HOST" "INFO" "INFO" "HOST-PACKAGE-UPDATES" "packages" "apt-get no está disponible; comprobación de paquetes omitida." ""
  fi

  if command -v ufw >/dev/null 2>&1; then
    firewall_status="$(ufw status 2>/dev/null | awk 'NR == 1 {print $2}' || true)"
  fi
  if [[ "$firewall_status" == "active" ]]; then
    record_check "HOST" "PASS" "INFO" "HOST-FIREWALL" "ufw" "UFW está activo." ""
  elif command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
    local nft_rules
    nft_rules="$(nft list ruleset 2>/dev/null | grep -cE '^[[:space:]]*(ip|ip6|inet|tcp|udp|icmp|ct|counter|limit|jump|drop|reject|accept|policy)' || true)"
    if ((nft_rules > 0)); then
      record_check "HOST" "PASS" "INFO" "HOST-FIREWALL" "nftables" "nftables presenta $nft_rules línea(s) de reglas; revisa que la política sea restrictiva." ""
    else
      record_check "HOST" "WARN" "HIGH" "HOST-FIREWALL" "host" "No se confirmó un firewall de host activo mediante UFW/nftables." "Configura reglas de entrada de mínimo privilegio y valida también el Security Group AWS."
    fi
  else
    record_check "HOST" "WARN" "HIGH" "HOST-FIREWALL" "host" "No se confirmó un firewall de host activo." "Configura un firewall local de entrada y valida también el Security Group AWS."
  fi

  if command -v ss >/dev/null 2>&1; then
    socket_lines="$(ss -H -lntu 2>/dev/null | awk '{print $1 "\t" $5}' | sort -u || true)"
    record_inventory "listening_sockets" "$(jq -Rn '[inputs | select(length > 0) | split("\t") | {protocol:.[0], local_address:.[1]}]' <<<"$socket_lines")"
    socket_count="$(jq -Rn '[inputs | select(length > 0)] | length' <<<"$socket_lines")"
    record_check "HOST" "INFO" "INFO" "HOST-LISTENING-SOCKETS" "$(hostname -s)" "Se inventariaron $socket_count socket(s) TCP/UDP en escucha; revisa inventory.listening_sockets." ""
  else
    record_check "HOST" "ERROR" "N/A" "HOST-LISTENING-SOCKETS" "local" "ss no está disponible; puertos locales sin verificar." "Instala iproute2 o revisa sockets manualmente."
  fi

  if command -v sshd >/dev/null 2>&1; then
    if sshd_effective="$(sshd -T 2>/dev/null)"; then
      for ssh_key in permitrootlogin passwordauthentication pubkeyauthentication x11forwarding maxauthtries; do
        ssh_value="$(awk -v key="$ssh_key" '$1 == key {print $2; exit}' <<<"$sshd_effective")"
        [[ -n "$ssh_value" ]] || ssh_value="unknown"
        ssh_status="PASS"
        ssh_severity="INFO"
        ssh_recommendation=""
        case "$ssh_key:$ssh_value" in
          permitrootlogin:yes|passwordauthentication:yes|x11forwarding:yes)
            ssh_status="FAIL"
            ssh_severity="HIGH"
            ssh_recommendation="Endurece esta directiva de sshd tras validar acceso alternativo y política de administración."
            ;;
          permitrootlogin:prohibit-password|permitrootlogin:no|passwordauthentication:no|pubkeyauthentication:yes|x11forwarding:no)
            ;;
          maxauthtries:*)
            if [[ ! "$ssh_value" =~ ^[0-9]+$ ]] || ((ssh_value > 4)); then
              ssh_status="WARN"
              ssh_severity="MEDIUM"
              ssh_recommendation="Evalúa MaxAuthTries=4 o menor conforme a tu política."
            fi
            ;;
          *)
            ssh_status="WARN"
            ssh_severity="MEDIUM"
            ssh_recommendation="Revisa la directiva SSH efectiva."
            ;;
        esac
        record_check "HOST" "$ssh_status" "$ssh_severity" "HOST-SSH-${ssh_key^^}" "sshd" "$ssh_key=$ssh_value." "$ssh_recommendation"
      done
    else
      record_check "HOST" "ERROR" "N/A" "HOST-SSH-EFFECTIVE-CONFIG" "sshd" "sshd -T falló; configuración efectiva sin verificar." "Revisa la sintaxis del servidor SSH."
    fi
  else
    record_check "HOST" "INFO" "INFO" "HOST-SSH-EFFECTIVE-CONFIG" "sshd" "OpenSSH server no está instalado; control SSH no aplicable." ""
  fi

  if [[ -e /etc/shadow ]]; then
    file_mode="$(stat -c '%a' /etc/shadow 2>/dev/null || printf 'unknown')"
    file_owner="$(stat -c '%U' /etc/shadow 2>/dev/null || printf 'unknown')"
    group_name="$(stat -c '%G' /etc/shadow 2>/dev/null || printf 'unknown')"
    shadow_permissions_safe=false
    if [[ "$file_owner" == "root" && "$file_mode" =~ ^[0-7]{3,4}$ ]]; then
      shadow_mode_bits=$((8#$file_mode))
      if (( (shadow_mode_bits & 07000) == 0 && (shadow_mode_bits & 0030) == 0 && (shadow_mode_bits & 0007) == 0 && (shadow_mode_bits & 0100) == 0 )); then
        if (( (shadow_mode_bits & 0040) == 0 )) || [[ "$group_name" == "shadow" ]]; then
          shadow_permissions_safe=true
        fi
      fi
    fi
    if [[ "$shadow_permissions_safe" == "true" ]]; then
      record_check "HOST" "PASS" "INFO" "HOST-SHADOW-PERMISSIONS" "/etc/shadow" "Propietario root:$group_name; modo $file_mode. Sin acceso para otros ni escritura/ejecución del grupo; lectura de grupo, si existe, limitada al grupo shadow." ""
    else
      record_check "HOST" "FAIL" "HIGH" "HOST-SHADOW-PERMISSIONS" "/etc/shadow" "Propietario=$file_owner:$group_name; modo=$file_mode." "Restringe el acceso a root y al grupo autorizado; nunca compartas el contenido del archivo."
    fi
  else
    record_check "HOST" "ERROR" "N/A" "HOST-SHADOW-PERMISSIONS" "/etc/shadow" "No se pudo inspeccionar el metadato de permisos." "Revisa la configuración de cuentas local."
  fi

  if [[ -d /home ]]; then
    while IFS= read -r -d '' key_file; do
      file_mode="$(stat -c '%a' "$key_file" 2>/dev/null || printf 'unknown')"
      file_owner="$(stat -c '%U' "$key_file" 2>/dev/null || printf 'unknown')"
      if [[ "$file_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$file_mode & 0077) == 0 )); then
        authorized_keys_json="$(jq --arg path "$key_file" --arg mode "$file_mode" --arg owner "$file_owner" '. + [{path:$path, owner:$owner, mode:$mode, permissions_restricted:true}]' <<<"$authorized_keys_json")"
      else
        authorized_keys_json="$(jq --arg path "$key_file" --arg mode "$file_mode" --arg owner "$file_owner" '. + [{path:$path, owner:$owner, mode:$mode, permissions_restricted:false}]' <<<"$authorized_keys_json")"
      fi
    done < <(find /home -xdev -type f -name authorized_keys -print0 2>/dev/null)
    record_inventory "authorized_keys_file_metadata" "$authorized_keys_json"
    if [[ "$(jq '[.[] | select(.permissions_restricted == false)] | length' <<<"$authorized_keys_json")" == "0" ]]; then
      record_check "HOST" "PASS" "INFO" "HOST-AUTHORIZED-KEYS-PERMISSIONS" "/home" "Los archivos authorized_keys encontrados no permiten acceso a grupo/otros; no se leyeron sus claves." ""
    else
      record_check "HOST" "FAIL" "HIGH" "HOST-AUTHORIZED-KEYS-PERMISSIONS" "/home" "Hay archivos authorized_keys con permisos amplios; rutas y modos están en el inventario." "Restringe los archivos a su propietario y verifica también permisos de directorios .ssh."
    fi
  fi

  print_phase 'PASO 1.3 — Revisar servicios, hora y bitácoras'
  printf 'Se consulta el estado de auditd/fail2ban/SSM, la sincronización horaria y metadatos de journald.\n'
  for service in auditd fail2ban amazon-ssm-agent; do
    check_service_state "$service"
  done

  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx "yes"; then
      record_check "HOST" "PASS" "INFO" "HOST-TIME-SYNC" "system clock" "La sincronización NTP del sistema está activa." ""
    else
      record_check "HOST" "WARN" "MEDIUM" "HOST-TIME-SYNC" "system clock" "No se pudo confirmar sincronización NTP." "Habilita un servicio de tiempo confiable para correlacionar eventos y logs."
    fi
  else
    record_check "HOST" "ERROR" "N/A" "HOST-TIME-SYNC" "system clock" "timedatectl no está disponible." "Verifica sincronización horaria manualmente."
  fi

  if command -v journalctl >/dev/null 2>&1; then
    journal_errors="$(journalctl --since '24 hours ago' -p err..alert --no-pager -o cat 2>/dev/null | wc -l | tr -d ' ' || true)"
    journal_disk="$(journalctl --disk-usage 2>/dev/null | sed -n 's/^Archived and active journals take up //p' | head -n 1 || true)"
    journal_persistent="unknown"
    if [[ -d /var/log/journal ]]; then
      journal_persistent="yes"
    elif grep -RhsE '^[[:space:]]*Storage=[[:space:]]*volatile' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null | grep -q .; then
      journal_persistent="no"
    elif grep -RhsE '^[[:space:]]*Storage=[[:space:]]*persistent' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null | grep -q .; then
      journal_persistent="yes"
    fi
    record_inventory "journal" "$(jq -n --arg errors "$journal_errors" --arg disk "$journal_disk" --arg persistent "$journal_persistent" '{errors_or_higher_last_24h:($errors|tonumber), disk_usage:$disk, persistent_storage:$persistent}')"
    if [[ "$journal_persistent" == "yes" ]]; then
      record_check "HOST" "PASS" "INFO" "HOST-JOURNAL-PERSISTENCE" "systemd-journald" "El almacenamiento persistente del journal está disponible; $journal_errors evento(s) de prioridad error o mayor en 24 h; uso=$journal_disk." ""
    else
      record_check "HOST" "WARN" "MEDIUM" "HOST-JOURNAL-PERSISTENCE" "systemd-journald" "Persistencia del journal=$journal_persistent; $journal_errors evento(s) de prioridad error o mayor en 24 h; uso=$journal_disk." "Configura almacenamiento persistente y retención acorde a requisitos de auditoría."
    fi
  else
    record_check "HOST" "ERROR" "N/A" "HOST-JOURNAL-PERSISTENCE" "system logs" "journalctl no está disponible; bitácora local sin verificar." "Verifica almacenamiento y rotación de logs."
  fi

  root_fs_type="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  if [[ "$root_fs_type" == "crypto_LUKS" || "$root_fs_type" == "crypt" ]]; then
    record_check "HOST" "PASS" "INFO" "HOST-ROOT-FILESYSTEM-ENCRYPTION" "/" "El filesystem raíz aparece sobre una capa de cifrado ($root_fs_type)." ""
  else
    record_check "HOST" "INFO" "INFO" "HOST-ROOT-FILESYSTEM-ENCRYPTION" "/" "Tipo de filesystem raíz=$root_fs_type; esto no confirma cifrado del volumen subyacente." "Confirma el cifrado EBS en AWS o cifrado de disco en la plataforma correspondiente."
  fi
}

check_s3_bucket() {
  local bucket="$1"
  local location=""
  local encryption
  local versioning
  local logging
  local bucket_region="us-east-1"
  local bpa_ok="unknown"

  if aws_region_json "us-east-1" s3api get-bucket-location --bucket "$bucket"; then
    location="$(jq -r '.LocationConstraint // "us-east-1"' <<<"$AWS_OUTPUT")"
    if [[ "$location" == "EU" ]]; then
      location="eu-west-1"
    fi
    if [[ -n "$location" && "$location" != "null" ]]; then
      bucket_region="$location"
    fi
  else
    api_error "S3-BUCKET-REGION" "$bucket" "s3:GetBucketLocation"
    bucket_region="unknown"
  fi

  if [[ "$bucket_region" != "unknown" ]] && aws_region_json "$bucket_region" s3api get-public-access-block --bucket "$bucket"; then
    bpa_ok="$(jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls, .PublicAccessBlockConfiguration.IgnorePublicAcls, .PublicAccessBlockConfiguration.BlockPublicPolicy, .PublicAccessBlockConfiguration.RestrictPublicBuckets] | all' <<<"$AWS_OUTPUT")"
    if [[ "$bpa_ok" == "true" ]]; then
      record_check "AWS" "PASS" "INFO" "S3-PUBLIC-ACCESS-BLOCK" "$bucket" "Los cuatro ajustes Block Public Access del bucket están activos." ""
    else
      record_check "AWS" "FAIL" "HIGH" "S3-PUBLIC-ACCESS-BLOCK" "$bucket" "Uno o más ajustes Block Public Access están desactivados." "Activa los cuatro ajustes tras validar dependencias legítimas de acceso."
    fi
  elif [[ "$bucket_region" != "unknown" && "$AWS_ERROR_CODE" == "NoSuchPublicAccessBlockConfiguration" ]]; then
    bpa_ok=false
    record_check "AWS" "FAIL" "HIGH" "S3-PUBLIC-ACCESS-BLOCK" "$bucket" "El bucket no tiene configuración Block Public Access propia." "Activa bloqueo público a nivel de cuenta y bucket."
  elif [[ "$bucket_region" != "unknown" ]]; then
    api_error "S3-PUBLIC-ACCESS-BLOCK" "$bucket" "s3:GetPublicAccessBlock" "HIGH"
  fi

  if [[ "$bucket_region" != "unknown" ]] && aws_region_json "$bucket_region" s3api get-bucket-policy-status --bucket "$bucket"; then
    if [[ "$(jq -r '.PolicyStatus.IsPublic' <<<"$AWS_OUTPUT")" == "true" ]]; then
      record_check "AWS" "FAIL" "CRITICAL" "S3-PUBLIC-POLICY" "$bucket" "AWS informa que la política del bucket es pública." "Retira el acceso público no aprobado y verifica accesos por identidad."
    else
      record_check "AWS" "PASS" "INFO" "S3-PUBLIC-POLICY" "$bucket" "AWS informa que la política del bucket no es pública." ""
    fi
  elif [[ "$bucket_region" != "unknown" && "$AWS_ERROR_CODE" == "NoSuchBucketPolicy" ]]; then
    record_check "AWS" "PASS" "INFO" "S3-PUBLIC-POLICY" "$bucket" "No hay política de bucket; el acceso de política no es público." ""
  elif [[ "$bucket_region" != "unknown" ]]; then
    api_error "S3-PUBLIC-POLICY" "$bucket" "s3:GetBucketPolicyStatus"
  fi

  if [[ "$bucket_region" != "unknown" ]] && aws_region_json "$bucket_region" s3api get-bucket-encryption --bucket "$bucket"; then
    encryption="$(jq -r '[.ServerSideEncryptionConfiguration.Rules[]?.ApplyServerSideEncryptionByDefault.SSEAlgorithm] | unique | join(",")' <<<"$AWS_OUTPUT")"
    if [[ -n "$encryption" ]]; then
      record_check "AWS" "PASS" "INFO" "S3-DEFAULT-ENCRYPTION" "$bucket" "Cifrado predeterminado configurado: $encryption." ""
    else
      record_check "AWS" "WARN" "MEDIUM" "S3-DEFAULT-ENCRYPTION" "$bucket" "No se pudo identificar cifrado predeterminado." "Configura cifrado predeterminado y evalúa cifrar los objetos existentes."
    fi
  elif [[ "$bucket_region" != "unknown" && "$AWS_ERROR_CODE" == "ServerSideEncryptionConfigurationNotFoundError" ]]; then
    record_check "AWS" "WARN" "MEDIUM" "S3-DEFAULT-ENCRYPTION" "$bucket" "No hay regla de cifrado predeterminado configurada." "Configura cifrado predeterminado para nuevos objetos."
  elif [[ "$bucket_region" != "unknown" ]]; then
    api_error "S3-DEFAULT-ENCRYPTION" "$bucket" "s3:GetEncryptionConfiguration" "MEDIUM"
  fi

  if [[ "$bucket_region" != "unknown" ]] && aws_region_json "$bucket_region" s3api get-bucket-versioning --bucket "$bucket"; then
    versioning="$(jq -r '.Status // "Disabled"' <<<"$AWS_OUTPUT")"
    if [[ "$versioning" == "Enabled" ]]; then
      record_check "AWS" "PASS" "INFO" "S3-VERSIONING" "$bucket" "Versioning está Enabled." ""
    else
      record_check "AWS" "WARN" "MEDIUM" "S3-VERSIONING" "$bucket" "Versioning=$versioning." "Habilita versionado si el bucket requiere recuperación frente a borrado o sobrescritura."
    fi
  elif [[ "$bucket_region" != "unknown" ]]; then
    api_error "S3-VERSIONING" "$bucket" "s3:GetBucketVersioning" "MEDIUM"
  fi

  if [[ "$bucket_region" != "unknown" ]] && aws_region_json "$bucket_region" s3api get-bucket-logging --bucket "$bucket"; then
    logging="$(jq -r '.LoggingEnabled.TargetBucket // empty' <<<"$AWS_OUTPUT")"
    if [[ -n "$logging" ]]; then
      record_check "AWS" "PASS" "INFO" "S3-ACCESS-LOGGING" "$bucket" "Server access logging envía logs al bucket '$logging'." ""
    else
      record_check "AWS" "INFO" "LOW" "S3-ACCESS-LOGGING" "$bucket" "Server access logging no está configurado; no se asume que sea obligatorio para todos los buckets." "Evalúa requerimientos de evidencia, acceso y retención."
    fi
  elif [[ "$bucket_region" != "unknown" ]]; then
    api_error "S3-ACCESS-LOGGING" "$bucket" "s3:GetBucketLogging"
  fi

  record_inventory "s3_bucket:$bucket" "$(jq -n --arg bucket "$bucket" --arg region "$bucket_region" --arg bpa "$bpa_ok" '{name:$bucket, region:$region, public_access_block_all_enabled:(if $bpa=="true" then true elif $bpa=="false" then false else null end)}')"
}

check_aws() {
  local instances
  local vpcs
  local subnets
  local route_tables='{"RouteTables":[]}'
  local network_acls
  local instance_id
  local state
  local instance_name
  local metadata_tokens
  local metadata_endpoint
  local public_ip
  local ipv6_addresses
  local ipv6_present
  local volume_ids
  local vpc_id
  local subnet_id
  local private_ip
  local profile_arn
  local security_group_ids
  local route_table
  local internet_route_v4
  local internet_route_v6
  local route_table_id
  local vpc_count
  local subnet_count
  local network_acl_count
  local volume_id
  local encrypted
  local sg_data
  local public_rules
  local bucket_list
  local bucket
  local trails
  local trail_name
  local trail_arn
  local trail_status
  local alarms
  local alarm_count
  local log_groups
  local log_group_name
  local retention
  local config_recorders
  local config_status
  local config_recorder_count
  local detector_ids
  local detector_id
  local rds_data
  local db_id
  local db_encrypted
  local db_public
  local iam_users
  local iam_username
  local iam_mfa_count
  local iam_console
  local iam_user_create_date
  local iam_users_json='[]'

  print_phase 'PASO 2/4 — Confirmar identidad y alcance AWS'
  printf 'Se verifica la sesión activa con STS antes de consultar recursos.\n'
  printf 'Cuenta esperada: %s\n' "${AWS_EXPECTED_ACCOUNT_ID:-no definida}"
  printf 'Región de recursos: %s\n' "$AWS_REGION_SELECTED"

  if ! aws_json sts get-caller-identity; then
    AWS_ERROR_CODE="${AWS_ERROR_CODE:-AWSCLIError}"
    api_error "AWS-IDENTITY" "account" "sts:GetCallerIdentity"
    return
  fi
  ACCOUNT_ID="$(jq -r '.Account' <<<"$AWS_OUTPUT")"
  local caller_arn caller_type
  caller_arn="$(jq -r '.Arn' <<<"$AWS_OUTPUT")"
  caller_type="$(cut -d: -f6 <<<"$caller_arn" | cut -d/ -f1)"
  if [[ -n "${AWS_EXPECTED_ACCOUNT_ID:-}" && "$ACCOUNT_ID" != "$AWS_EXPECTED_ACCOUNT_ID" ]]; then
    record_check "AWS" "FAIL" "CRITICAL" "AWS-EXPECTED-ACCOUNT" "account" "La identidad pertenece a una cuenta distinta de la cuenta esperada; AWS checks omitidos." "Corrige el perfil/rol o AWS_EXPECTED_ACCOUNT_ID antes de continuar."
    return
  fi
  record_check "AWS" "PASS" "INFO" "AWS-IDENTITY" "account ending ${ACCOUNT_ID: -4}" "Identidad confirmada; principal tipo=$caller_type; región=$AWS_REGION_SELECTED." ""
  record_inventory "aws" "$(jq -n --arg account_suffix "${ACCOUNT_ID: -4}" --arg region "$AWS_REGION_SELECTED" --arg principal_type "$caller_type" '{account_id_suffix:$account_suffix, region:$region, principal_type:$principal_type}')"

  print_phase 'PASO 3/4 — Inventariar controles AWS (sin realizar cambios)'
  printf 'La cuenta queda validada. Se revisan red, EC2, IAM, logging, monitoreo y S3.\n'
  print_phase 'PASO 3.1 — Mapear VPC, subredes, rutas y NACL'

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-vpcs; then
    vpcs="$AWS_OUTPUT"
    vpc_count="$(jq '.Vpcs | length' <<<"$vpcs")"
    record_inventory "vpcs" "$(jq '[.Vpcs[]? | {vpc_id:.VpcId,name:([.Tags[]? | select(.Key=="Name") | .Value] | .[0] // null),cidr:.CidrBlock,state:.State,is_default:.IsDefault}]' <<<"$vpcs")"
    record_check "AWS" "INFO" "INFO" "EC2-VPC-INVENTORY" "$AWS_REGION_SELECTED" "$vpc_count VPC(s) visibles en la región." "Confirma que cada carga use la VPC prevista; este inventario no cambia la red."
  else
    api_error "EC2-VPC-INVENTORY" "$AWS_REGION_SELECTED" "ec2:DescribeVpcs"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-subnets; then
    subnets="$AWS_OUTPUT"
    subnet_count="$(jq '.Subnets | length' <<<"$subnets")"
    record_inventory "subnets" "$(jq '[.Subnets[]? | {subnet_id:.SubnetId,name:([.Tags[]? | select(.Key=="Name") | .Value] | .[0] // null),vpc_id:.VpcId,cidr:.CidrBlock,availability_zone:.AvailabilityZone,map_public_ip_on_launch:.MapPublicIpOnLaunch,available_ip_count:.AvailableIpAddressCount}]' <<<"$subnets")"
    record_check "AWS" "INFO" "INFO" "EC2-SUBNET-INVENTORY" "$AWS_REGION_SELECTED" "$subnet_count subred(es) visibles; el atributo de IP pública automática no demuestra accesibilidad desde Internet." "Revisa VPC, rutas, NACL, Security Groups y firewall del host en conjunto."
  else
    api_error "EC2-SUBNET-INVENTORY" "$AWS_REGION_SELECTED" "ec2:DescribeSubnets"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-route-tables; then
    route_tables="$AWS_OUTPUT"
    record_inventory "route_tables" "$(jq '[.RouteTables[]? | {route_table_id:.RouteTableId,vpc_id:.VpcId,main:(any(.Associations[]?; .Main==true)),subnet_ids:[.Associations[]?.SubnetId],default_ipv4_internet_gateway_route:any(.Routes[]?; .DestinationCidrBlock=="0.0.0.0/0" and ((.GatewayId // "")|startswith("igw-")) and .State=="active"),default_ipv6_internet_gateway_route:any(.Routes[]?; .DestinationIpv6CidrBlock=="::/0" and ((.GatewayId // "")|startswith("igw-")) and .State=="active"),routes:[.Routes[]? | {destination_ipv4:.DestinationCidrBlock,destination_ipv6:.DestinationIpv6CidrBlock,gateway_id:.GatewayId,nat_gateway_id:.NatGatewayId,network_interface_id:.NetworkInterfaceId,state:.State}]}]' <<<"$route_tables")"
  else
    api_error "EC2-ROUTE-TABLE-INVENTORY" "$AWS_REGION_SELECTED" "ec2:DescribeRouteTables"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-network-acls; then
    network_acls="$AWS_OUTPUT"
    network_acl_count="$(jq '.NetworkAcls | length' <<<"$network_acls")"
    record_inventory "network_acls" "$(jq '[.NetworkAcls[]? | {network_acl_id:.NetworkAclId,vpc_id:.VpcId,is_default:.IsDefault,subnet_ids:[.Associations[]?.SubnetId],entries:[.Entries[]? | {rule_number:.RuleNumber,protocol:.Protocol,rule_action:.RuleAction,egress:.Egress,cidr_ipv4:.CidrBlock,cidr_ipv6:.Ipv6CidrBlock,port_range:.PortRange}]}]' <<<"$network_acls")"
    record_check "AWS" "INFO" "INFO" "EC2-NETWORK-ACL-INVENTORY" "$AWS_REGION_SELECTED" "$network_acl_count NACL(s) inventariadas; sus reglas son stateless y no se evalúa aquí su efecto completo sobre el tráfico." "Revisa las entradas de NACL y el tráfico de retorno de forma contextual."
  else
    api_error "EC2-NETWORK-ACL-INVENTORY" "$AWS_REGION_SELECTED" "ec2:DescribeNetworkAcls"
  fi

  print_phase 'PASO 3.2 — Revisar bloqueo público de S3 a nivel de cuenta'
  if aws_region_json "$AWS_REGION_SELECTED" s3control get-public-access-block --account-id "$ACCOUNT_ID"; then
    if [[ "$(jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls, .PublicAccessBlockConfiguration.IgnorePublicAcls, .PublicAccessBlockConfiguration.BlockPublicPolicy, .PublicAccessBlockConfiguration.RestrictPublicBuckets] | all' <<<"$AWS_OUTPUT")" == "true" ]]; then
      record_check "AWS" "PASS" "INFO" "S3-ACCOUNT-PUBLIC-ACCESS-BLOCK" "account ending ${ACCOUNT_ID: -4}" "Los cuatro ajustes de bloqueo público de cuenta están activos." ""
    else
      record_check "AWS" "FAIL" "HIGH" "S3-ACCOUNT-PUBLIC-ACCESS-BLOCK" "account ending ${ACCOUNT_ID: -4}" "Uno o más ajustes de bloqueo público de cuenta están desactivados." "Activa el bloqueo público de cuenta tras evaluar dependencias y excepciones autorizadas."
    fi
  elif [[ "$AWS_ERROR_CODE" == "NoSuchPublicAccessBlockConfiguration" ]]; then
    record_check "AWS" "WARN" "HIGH" "S3-ACCOUNT-PUBLIC-ACCESS-BLOCK" "account ending ${ACCOUNT_ID: -4}" "No existe configuración Block Public Access a nivel de cuenta." "Evalúa habilitar los cuatro ajustes globales de S3."
  else
    api_error "S3-ACCOUNT-PUBLIC-ACCESS-BLOCK" "account" "s3control:GetPublicAccessBlock" "HIGH"
  fi

  print_phase 'PASO 3.3 — Revisar instancias EC2, perfil IAM, IMDSv2, red y EBS'
  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-instances; then
    instances="$AWS_OUTPUT"
    while IFS=$'\t' read -r instance_id state metadata_endpoint metadata_tokens public_ip volume_ids vpc_id subnet_id private_ip profile_arn security_group_ids ipv6_addresses; do
      [[ -n "$instance_id" ]] || continue
      ipv6_present=false
      [[ -n "$ipv6_addresses" ]] && ipv6_present=true
      instance_name="$(jq -r --arg id "$instance_id" '[.Reservations[].Instances[] | select(.InstanceId==$id) | .Tags[]? | select(.Key=="Name") | .Value] | .[0] // ""' <<<"$instances")"
      record_inventory "ec2_instance:$instance_id" "$(jq -n --arg id "$instance_id" --arg name "$instance_name" --arg state "$state" --arg endpoint "$metadata_endpoint" --arg tokens "$metadata_tokens" --arg public_ip "$public_ip" --arg private_ip "$private_ip" --arg ipv6 "$ipv6_addresses" --arg volumes "$volume_ids" --arg vpc "$vpc_id" --arg subnet "$subnet_id" --arg profile "$profile_arn" --arg groups "$security_group_ids" '{instance_id:$id,name:(if $name=="" then null else $name end),state:$state,metadata_endpoint:$endpoint,metadata_tokens:$tokens,public_ipv4:(if $public_ip=="" then null else $public_ip end),public_ipv4_present:($public_ip!=""),private_ipv4:$private_ip,ipv6_addresses:($ipv6|split(",")|map(select(length>0))),vpc_id:$vpc,subnet_id:$subnet,iam_instance_profile_arn:(if $profile=="" then null else $profile end),security_group_ids:($groups|split(",")|map(select(length>0))),volume_ids:($volumes|split(",")|map(select(length>0)))}')"
      if [[ -n "$profile_arn" ]]; then
        record_check "AWS" "INFO" "INFO" "EC2-IAM-INSTANCE-PROFILE" "$instance_id" "La instancia tiene asociado un instance profile ($profile_arn); esto no determina por sí solo los permisos efectivos del rol." "Revisa por separado el rol, sus políticas y los límites de permisos."
      else
        record_check "AWS" "INFO" "LOW" "EC2-IAM-INSTANCE-PROFILE" "$instance_id" "No se observa un IAM instance profile asociado a la instancia." "Si los procesos necesitan AWS, evalúa un rol de mínimo privilegio; no guardes Access Keys en el host."
      fi
      if [[ "$metadata_endpoint" == "enabled" && "$metadata_tokens" == "required" ]]; then
        record_check "AWS" "PASS" "INFO" "EC2-IMDSV2" "$instance_id" "La instancia exige tokens IMDSv2." ""
      elif [[ "$metadata_endpoint" == "disabled" ]]; then
        record_check "AWS" "PASS" "INFO" "EC2-IMDSV2" "$instance_id" "El endpoint metadata está deshabilitado." ""
      else
        record_check "AWS" "FAIL" "HIGH" "EC2-IMDSV2" "$instance_id" "Endpoint=$metadata_endpoint; HttpTokens=$metadata_tokens." "Exige IMDSv2 tras validar dependencias del sistema."
      fi
      if [[ -n "$public_ip" ]]; then
        record_check "AWS" "INFO" "INFO" "EC2-PUBLIC-IP" "$instance_id" "La instancia tiene IPv4 pública; esto no prueba reachability." "Revisa rutas, NACL, Security Groups y necesidad de negocio."
      fi
      if [[ "$ipv6_present" == "true" ]]; then
        record_check "AWS" "INFO" "INFO" "EC2-PUBLIC-IPV6" "$instance_id" "La instancia tiene dirección(es) IPv6 global(es); esto no prueba reachability." "Revisa rutas IPv6, NACL, Security Groups y necesidad de negocio."
      fi
      if [[ -n "$subnet_id" ]]; then
        route_table="$(jq -c --arg subnet "$subnet_id" --arg vpc "$vpc_id" '([.RouteTables[]? | select(any(.Associations[]?; .SubnetId==$subnet))] | .[0]) // ([.RouteTables[]? | select(.VpcId==$vpc and any(.Associations[]?; .Main==true))] | .[0]) // null' <<<"$route_tables")"
        route_table_id="$(jq -r '.RouteTableId // empty' <<<"$route_table")"
        internet_route_v4="$(jq -r 'any(.Routes[]?; .DestinationCidrBlock=="0.0.0.0/0" and ((.GatewayId // "")|startswith("igw-")) and .State=="active")' <<<"$route_table")"
        internet_route_v6="$(jq -r 'any(.Routes[]?; .DestinationIpv6CidrBlock=="::/0" and ((.GatewayId // "")|startswith("igw-")) and .State=="active")' <<<"$route_table")"
        if [[ -n "$route_table_id" && ( ( -n "$public_ip" && "$internet_route_v4" == "true" ) || ( "$ipv6_present" == "true" && "$internet_route_v6" == "true" ) ) ]]; then
          record_check "AWS" "WARN" "MEDIUM" "EC2-NETWORK-PATH" "$instance_id" "Hay dirección IP pública y ruta por defecto correspondiente hacia Internet Gateway en $route_table_id (IPv4=$internet_route_v4, IPv6=$internet_route_v6); no se probó acceso externo ni se evaluaron íntegramente NACL/firewall/aplicación." "Valida si la exposición es necesaria y confirma las reglas efectivas antes de cualquier cambio."
        elif [[ -n "$route_table_id" ]]; then
          record_check "AWS" "INFO" "INFO" "EC2-NETWORK-PATH" "$instance_id" "Subred=$subnet_id; tabla=$route_table_id; ruta IGW por defecto IPv4=$internet_route_v4/IPv6=$internet_route_v6; IPv4 pública presente=$([[ -n "$public_ip" ]] && printf true || printf false); IPv6 global presente=$ipv6_present. No se probó acceso externo." "Correlaciona estos datos con las reglas SG, NACL, firewall del host y servicio."
        else
          record_check "AWS" "ERROR" "N/A" "EC2-NETWORK-PATH" "$instance_id" "No se pudo asociar una tabla de rutas a subnet=$subnet_id; el camino de red queda sin verificar." "Confirma permisos de DescribeRouteTables y la asociación de la subred."
        fi
      fi
    done < <(jq -r '.Reservations[].Instances[] | select(.State.Name != "terminated") | [.InstanceId,.State.Name,(.MetadataOptions.HttpEndpoint // "unknown"),(.MetadataOptions.HttpTokens // "unknown"),(.PublicIpAddress // ""),([.BlockDeviceMappings[]?.Ebs.VolumeId] | join(",")),(.VpcId // ""),(.SubnetId // ""),(.PrivateIpAddress // ""),(.IamInstanceProfile.Arn // ""),([.SecurityGroups[]?.GroupId] | join(",")),([.NetworkInterfaces[]?.Ipv6Addresses[]?.Ipv6Address] | join(","))] | @tsv' <<<"$instances")
  else
    api_error "EC2-INVENTORY" "$AWS_REGION_SELECTED" "ec2:DescribeInstances"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-volumes; then
    while IFS=$'\t' read -r volume_id encrypted state; do
      [[ -n "$volume_id" ]] || continue
      record_inventory "ebs_volume:$volume_id" "$(jq -n --arg id "$volume_id" --arg state "$state" --arg encrypted "$encrypted" '{volume_id:$id,state:$state,encrypted:($encrypted=="true")}')"
      if [[ "$encrypted" == "true" ]]; then
        record_check "AWS" "PASS" "INFO" "EC2-EBS-ENCRYPTION" "$volume_id" "EBS informa Encrypted=true ($state)." ""
      else
        record_check "AWS" "FAIL" "HIGH" "EC2-EBS-ENCRYPTION" "$volume_id" "EBS informa Encrypted=false ($state)." "Planifica cifrado mediante snapshot/reemplazo; no modifiques el volumen sin ventana aprobada."
      fi
    done < <(jq -r '.Volumes[] | [.VolumeId,(.Encrypted|tostring),.State] | @tsv' <<<"$AWS_OUTPUT")
  else
    api_error "EC2-EBS-ENCRYPTION" "$AWS_REGION_SELECTED" "ec2:DescribeVolumes"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" ec2 describe-security-groups; then
    sg_data="$AWS_OUTPUT"
    record_inventory "security_groups" "$(jq '[.SecurityGroups[]? | {group_id:.GroupId,group_name:.GroupName,vpc_id:.VpcId,description:.Description,ingress:[.IpPermissions[]? | {protocol:.IpProtocol,from_port:.FromPort,to_port:.ToPort,ipv4_cidrs:[.IpRanges[]?.CidrIp],ipv6_cidrs:[.Ipv6Ranges[]?.CidrIpv6],prefix_list_ids:[.PrefixListIds[]?.PrefixListId],referenced_groups:[.UserIdGroupPairs[]? | {group_id:.GroupId,owner_id:.UserId}]}],egress:[.IpPermissionsEgress[]? | {protocol:.IpProtocol,from_port:.FromPort,to_port:.ToPort,ipv4_cidrs:[.IpRanges[]?.CidrIp],ipv6_cidrs:[.Ipv6Ranges[]?.CidrIpv6],prefix_list_ids:[.PrefixListIds[]?.PrefixListId],referenced_groups:[.UserIdGroupPairs[]? | {group_id:.GroupId,owner_id:.UserId}]}]}]' <<<"$sg_data")"
    public_rules="$(jq -r '.SecurityGroups[] as $sg | $sg.IpPermissions[]? as $p | ($p.IpRanges[]?.CidrIp // empty), ($p.Ipv6Ranges[]?.CidrIpv6 // empty) | select(.=="0.0.0.0/0" or .=="::/0") | [$sg.GroupId,$sg.GroupName,($p.IpProtocol // "unknown"),(($p.FromPort // "all")|tostring),(($p.ToPort // "all")|tostring),.] | @tsv' <<<"$sg_data")"
    if [[ -n "$public_rules" ]]; then
      while IFS=$'\t' read -r group_id group_name protocol from_port to_port cidr; do
        record_check "AWS" "FAIL" "HIGH" "EC2-SG-PUBLIC-INGRESS" "$group_id ($group_name)" "Ingreso desde $cidr; protocolo=$protocol; puertos=$from_port-$to_port." "Limita el origen a CIDR autorizados; confirma dependencias y alcance antes de modificar reglas."
      done <<<"$public_rules"
      record_inventory "public_security_group_rules" "$(jq -Rn '[inputs | split("\t") | {group_id:.[0],group_name:.[1],protocol:.[2],from_port:.[3],to_port:.[4],cidr:.[5]}]' <<<"$public_rules")"
    else
      record_check "AWS" "PASS" "INFO" "EC2-SG-PUBLIC-INGRESS" "$AWS_REGION_SELECTED" "No se encontraron reglas Security Group con origen 0.0.0.0/0 o ::/0." ""
    fi
  else
    api_error "EC2-SG-PUBLIC-INGRESS" "$AWS_REGION_SELECTED" "ec2:DescribeSecurityGroups"
  fi

  print_phase 'PASO 3.4 — Revisar IAM sin cambiar identidades'
  if aws_json iam get-account-summary; then
    local root_mfa root_keys
    root_mfa="$(jq -r '.SummaryMap.AccountMFAEnabled // 0' <<<"$AWS_OUTPUT")"
    root_keys="$(jq -r '.SummaryMap.AccountAccessKeysPresent // 0' <<<"$AWS_OUTPUT")"
    if [[ "$root_mfa" == "1" ]]; then
      record_check "AWS" "PASS" "INFO" "IAM-ROOT-MFA" "account root" "La cuenta informa MFA habilitado para root." ""
    else
      record_check "AWS" "FAIL" "CRITICAL" "IAM-ROOT-MFA" "account root" "La cuenta no informa MFA habilitado para root." "Activa MFA con el proceso administrativo de AWS; nunca compartas el secreto MFA."
    fi
    if [[ "$root_keys" == "0" ]]; then
      record_check "AWS" "PASS" "INFO" "IAM-ROOT-ACCESS-KEYS" "account root" "La cuenta informa cero access keys para root." ""
    else
      record_check "AWS" "FAIL" "CRITICAL" "IAM-ROOT-ACCESS-KEYS" "account root" "La cuenta informa $root_keys access key(s) de root." "Deshabilita/elimina claves de root mediante el proceso aprobado; usa roles."
    fi
  else
    api_error "IAM-ROOT-CONTROLS" "account" "iam:GetAccountSummary"
  fi

  if aws_json iam list-users; then
    iam_users="$AWS_OUTPUT"
    while IFS=$'\t' read -r iam_username iam_user_create_date; do
      [[ -n "$iam_username" ]] || continue
      iam_mfa_count="unknown"
      if aws_json iam list-mfa-devices --user-name "$iam_username"; then
        iam_mfa_count="$(jq '.MFADevices | length' <<<"$AWS_OUTPUT")"
      else
        api_error "IAM-USER-MFA" "$iam_username" "iam:ListMFADevices"
      fi
      iam_console="unknown"
      if aws_json iam get-login-profile --user-name "$iam_username"; then
        iam_console="true"
      elif [[ "$AWS_ERROR_CODE" == "NoSuchEntity" ]]; then
        iam_console="false"
      else
        api_error "IAM-CONSOLE-LOGIN-PROFILE" "$iam_username" "iam:GetLoginProfile"
      fi
      iam_users_json="$(jq --arg username "$iam_username" --arg created "$iam_user_create_date" --arg mfa "$iam_mfa_count" --arg console "$iam_console" '. + [{username:$username,created_at:$created,mfa_devices:($mfa|if test("^[0-9]+$") then tonumber else null end),console_login:($console|if .=="true" then true elif .=="false" then false else null end)}]' <<<"$iam_users_json")"
      if [[ "$iam_console" == "true" && "$iam_mfa_count" == "0" ]]; then
        record_check "AWS" "FAIL" "HIGH" "IAM-CONSOLE-MFA" "$iam_username" "Usuario IAM con perfil de consola y sin dispositivos MFA registrados." "Asigna MFA mediante el proceso corporativo; la auditoría no cambia identidades."
      elif [[ "$iam_console" == "true" && "$iam_mfa_count" =~ ^[1-9][0-9]*$ ]]; then
        record_check "AWS" "PASS" "INFO" "IAM-CONSOLE-MFA" "$iam_username" "Usuario con perfil de consola y $iam_mfa_count dispositivo(s) MFA." ""
      elif [[ "$iam_console" == "false" ]]; then
        record_check "AWS" "INFO" "INFO" "IAM-CONSOLE-MFA" "$iam_username" "No se encontró perfil de consola para el usuario IAM." ""
      else
        record_check "AWS" "ERROR" "N/A" "IAM-CONSOLE-MFA" "$iam_username" "No se pudo verificar el estado de consola/MFA." "Confirma permisos IAM y vuelve a auditar."
      fi
    done < <(jq -r '.Users[]? | [.UserName,(.CreateDate // ""|tostring)] | @tsv' <<<"$iam_users")
    record_inventory "iam_users" "$iam_users_json"
  else
    api_error "IAM-USERS" "account" "iam:ListUsers"
  fi

  print_phase 'PASO 3.5 — Revisar CloudTrail, CloudWatch y servicios de detección'
  if aws_region_json "$AWS_REGION_SELECTED" cloudtrail describe-trails; then
    trails="$AWS_OUTPUT"
    if [[ "$(jq '.trailList | length' <<<"$trails")" == "0" ]]; then
      record_check "AWS" "FAIL" "HIGH" "CLOUDTRAIL-EXISTS" "account" "No se encontraron trails visibles." "Configura CloudTrail conforme a la política organizacional; no se crea desde esta auditoría."
    else
      while IFS=$'\t' read -r trail_name trail_arn multi_region validation bucket_name; do
        [[ -n "$trail_name" ]] || continue
        record_inventory "cloudtrail:$trail_name" "$(jq -n --arg name "$trail_name" --arg arn "$trail_arn" --arg multi "$multi_region" --arg validation "$validation" --arg bucket "$bucket_name" '{name:$name,arn:$arn,multi_region:($multi=="true"),log_file_validation:($validation=="true"),s3_bucket:$bucket}')"
        if [[ "$multi_region" == "true" ]]; then
          record_check "AWS" "PASS" "INFO" "CLOUDTRAIL-MULTIREGION" "$trail_name" "Trail multi-región habilitado." ""
        else
          record_check "AWS" "FAIL" "HIGH" "CLOUDTRAIL-MULTIREGION" "$trail_name" "Trail no está configurado multi-región." "Evalúa un trail multi-región con la política de logging aprobada."
        fi
        if [[ "$validation" == "true" ]]; then
          record_check "AWS" "PASS" "INFO" "CLOUDTRAIL-INTEGRITY" "$trail_name" "Validación de archivos de log habilitada." ""
        else
          record_check "AWS" "WARN" "MEDIUM" "CLOUDTRAIL-INTEGRITY" "$trail_name" "Log file validation no está habilitada." "Activa validación de integridad si lo requiere tu política."
        fi
        if aws_region_json "$AWS_REGION_SELECTED" cloudtrail get-trail-status --name "$trail_arn"; then
          trail_status="$AWS_OUTPUT"
          if [[ "$(jq -r '.IsLogging' <<<"$trail_status")" == "true" ]]; then
            record_check "AWS" "PASS" "INFO" "CLOUDTRAIL-LOGGING" "$trail_name" "Trail está registrando eventos." ""
          else
            record_check "AWS" "FAIL" "HIGH" "CLOUDTRAIL-LOGGING" "$trail_name" "Trail no está registrando eventos." "Restaura logging con aprobación del responsable de AWS."
          fi
        else
          api_error "CLOUDTRAIL-LOGGING" "$trail_name" "cloudtrail:GetTrailStatus"
        fi
        [[ -n "$bucket_name" ]] || record_check "AWS" "WARN" "MEDIUM" "CLOUDTRAIL-S3-DESTINATION" "$trail_name" "No aparece bucket S3 de destino." "Valida el destino del trail."
      done < <(jq -r '.trailList[] | [.Name,.TrailARN,(.IsMultiRegionTrail|tostring),(.LogFileValidationEnabled|tostring),(.S3BucketName // "")] | @tsv' <<<"$trails")
      record_check "AWS" "PASS" "INFO" "CLOUDTRAIL-EXISTS" "account" "$(jq '.trailList | length' <<<"$trails") trail(s) visibles." ""
    fi
  else
    api_error "CLOUDTRAIL-EXISTS" "account" "cloudtrail:DescribeTrails"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" cloudwatch describe-alarms; then
    alarms="$AWS_OUTPUT"
    alarm_count="$(jq '.MetricAlarms | length' <<<"$alarms")"
    record_inventory "cloudwatch_alarm_count" "$alarm_count"
    record_inventory "cloudwatch_alarms" "$(jq '[.MetricAlarms[]? | {name:.AlarmName,namespace:.Namespace,metric_name:.MetricName,state:.StateValue,state_reason:.StateReason,threshold:.Threshold,comparison_operator:.ComparisonOperator,evaluation_periods:.EvaluationPeriods,period_seconds:.Period,actions_enabled:.ActionsEnabled,alarm_action_count:(.AlarmActions|length)}]' <<<"$alarms")"
    if ((alarm_count > 0)); then
      record_check "AWS" "INFO" "INFO" "CLOUDWATCH-ALARMS" "$AWS_REGION_SELECTED" "$alarm_count alarma(s) consultadas; nombre, métrica, estado, umbral y acciones resumidas en inventory.cloudwatch_alarms." "Revisa cobertura y notificaciones requeridas para las cargas críticas."
    else
      record_check "AWS" "WARN" "MEDIUM" "CLOUDWATCH-ALARMS" "$AWS_REGION_SELECTED" "No se encontraron alarmas CloudWatch visibles." "Evalúa alarmas de operación/seguridad para cargas críticas."
    fi
  else
    api_error "CLOUDWATCH-ALARMS" "$AWS_REGION_SELECTED" "cloudwatch:DescribeAlarms"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" logs describe-log-groups; then
    log_groups="$AWS_OUTPUT"
    record_inventory "cloudwatch_log_groups" "$(jq '[.logGroups[]? | {name:.logGroupName,retention_days:(.retentionInDays // null),stored_bytes:.storedBytes, kms_key_id:.kmsKeyId}]' <<<"$log_groups")"
    while IFS=$'\t' read -r log_group_name retention; do
      [[ -n "$log_group_name" ]] || continue
      if [[ "$retention" =~ ^[0-9]+$ ]]; then
        record_check "AWS" "PASS" "INFO" "CLOUDWATCH-LOG-RETENTION" "$log_group_name" "Retención configurada a $retention día(s)." ""
      else
        record_check "AWS" "WARN" "LOW" "CLOUDWATCH-LOG-RETENTION" "$log_group_name" "Retención no configurada (retención indefinida)." "Define retención compatible con requisitos de seguridad, legales y costos."
      fi
    done < <(jq -r '.logGroups[]? | [.logGroupName,(.retentionInDays // "never-expire"|tostring)] | @tsv' <<<"$log_groups")
    record_inventory "cloudwatch_log_group_count" "$(jq '.logGroups | length' <<<"$log_groups")"
  else
    api_error "CLOUDWATCH-LOG-GROUPS" "$AWS_REGION_SELECTED" "logs:DescribeLogGroups"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" configservice describe-configuration-recorders; then
    config_recorders="$AWS_OUTPUT"
    config_recorder_count="$(jq '.ConfigurationRecorders | length' <<<"$config_recorders")"
    if ((config_recorder_count == 0)); then
      record_check "AWS" "WARN" "MEDIUM" "AWS-CONFIG-RECORDER" "$AWS_REGION_SELECTED" "No se encontraron configuration recorders de AWS Config." "Evalúa AWS Config, cobertura, retención y costos."
    elif aws_region_json "$AWS_REGION_SELECTED" configservice describe-configuration-recorder-status; then
      config_status="$AWS_OUTPUT"
      if [[ "$(jq '[.ConfigurationRecordersStatus[]? | select(.recording==true)] | length' <<<"$config_status")" -gt 0 ]]; then
        record_check "AWS" "PASS" "INFO" "AWS-CONFIG-RECORDER" "$AWS_REGION_SELECTED" "$config_recorder_count recorder(s) configurado(s); al menos uno está grabando." ""
      else
        record_check "AWS" "WARN" "MEDIUM" "AWS-CONFIG-RECORDER" "$AWS_REGION_SELECTED" "Hay recorder(s), pero ninguno informa recording=true." "Valida el estado de grabación, alcance de recursos, retención y costos."
      fi
    else
      api_error "AWS-CONFIG-RECORDER" "$AWS_REGION_SELECTED" "config:DescribeConfigurationRecorderStatus" "MEDIUM"
    fi
  else
    api_error "AWS-CONFIG-RECORDER" "$AWS_REGION_SELECTED" "config:DescribeConfigurationRecorders" "MEDIUM"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" guardduty list-detectors; then
    detector_ids="$(jq -r '.DetectorIds[]?' <<<"$AWS_OUTPUT")"
    if [[ -z "$detector_ids" ]]; then
      record_check "AWS" "WARN" "MEDIUM" "GUARDDUTY-ENABLED" "$AWS_REGION_SELECTED" "No se encontraron detector(es) de GuardDuty." "Evalúa habilitar GuardDuty según la política y el plan de costos."
    else
      while IFS= read -r detector_id; do
        [[ -n "$detector_id" ]] || continue
        if aws_region_json "$AWS_REGION_SELECTED" guardduty get-detector --detector-id "$detector_id"; then
          if [[ "$(jq -r '.Status' <<<"$AWS_OUTPUT")" == "ENABLED" ]]; then
            record_check "AWS" "PASS" "INFO" "GUARDDUTY-ENABLED" "$AWS_REGION_SELECTED" "GuardDuty detector habilitado." ""
          else
            record_check "AWS" "WARN" "MEDIUM" "GUARDDUTY-ENABLED" "$AWS_REGION_SELECTED" "GuardDuty detector no está habilitado." "Valida la cobertura y estado de GuardDuty."
          fi
        else
          api_error "GUARDDUTY-ENABLED" "$AWS_REGION_SELECTED" "guardduty:GetDetector" "MEDIUM"
        fi
      done <<<"$detector_ids"
    fi
  else
    api_error "GUARDDUTY-ENABLED" "$AWS_REGION_SELECTED" "guardduty:ListDetectors" "MEDIUM"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" securityhub describe-hub; then
    record_check "AWS" "PASS" "INFO" "SECURITYHUB-ENABLED" "$AWS_REGION_SELECTED" "Security Hub está habilitado en la región." ""
  elif [[ "$AWS_ERROR_CODE" == "InvalidAccessException" || "$AWS_ERROR_CODE" == "ResourceNotFoundException" ]]; then
    record_check "AWS" "WARN" "MEDIUM" "SECURITYHUB-ENABLED" "$AWS_REGION_SELECTED" "Security Hub no está habilitado o no está disponible para esta identidad." "Valida configuración, delegación y costos de Security Hub."
  else
    api_error "SECURITYHUB-ENABLED" "$AWS_REGION_SELECTED" "securityhub:DescribeHub" "MEDIUM"
  fi

  if aws_region_json "$AWS_REGION_SELECTED" rds describe-db-instances; then
    rds_data="$AWS_OUTPUT"
    while IFS=$'\t' read -r db_id db_encrypted db_public; do
      [[ -n "$db_id" ]] || continue
      record_inventory "rds_instance:$db_id" "$(jq --arg id "$db_id" --arg encrypted "$db_encrypted" --arg public "$db_public" '.DBInstances[] | select(.DBInstanceIdentifier==$id) | {db_instance_identifier:$id,engine:.Engine,engine_version:.EngineVersion,status:.DBInstanceStatus,storage_encrypted:($encrypted=="true"),publicly_accessible:($public=="true"),vpc_id:.DBSubnetGroup.VpcId}' <<<"$rds_data")"
      if [[ "$db_encrypted" == "true" ]]; then
        record_check "AWS" "PASS" "INFO" "RDS-ENCRYPTION" "$db_id" "Almacenamiento cifrado." ""
      else
        record_check "AWS" "FAIL" "HIGH" "RDS-ENCRYPTION" "$db_id" "Almacenamiento no informa cifrado." "Planifica cifrado mediante snapshot/migración; la auditoría no cambia la instancia."
      fi
      if [[ "$db_public" == "false" ]]; then
        record_check "AWS" "PASS" "INFO" "RDS-PUBLIC-ACCESS" "$db_id" "PubliclyAccessible=false." ""
      else
        record_check "AWS" "FAIL" "HIGH" "RDS-PUBLIC-ACCESS" "$db_id" "PubliclyAccessible=true." "Evalúa deshabilitar acceso público y restringir red tras comprobar dependencias."
      fi
    done < <(jq -r '.DBInstances[]? | [.DBInstanceIdentifier,(.StorageEncrypted|tostring),(.PubliclyAccessible|tostring)] | @tsv' <<<"$rds_data")
  else
    api_error "RDS-INVENTORY" "$AWS_REGION_SELECTED" "rds:DescribeDBInstances"
  fi

  print_phase 'PASO 3.6 — Revisar todos los buckets S3 visibles de la cuenta'
  if aws_region_json "$AWS_REGION_SELECTED" s3api list-buckets; then
    bucket_list="$(jq -r '.Buckets[]?.Name' <<<"$AWS_OUTPUT")"
    if [[ -z "$bucket_list" ]]; then
      record_check "AWS" "INFO" "INFO" "S3-INVENTORY" "account" "No se encontraron buckets S3." ""
    else
      while IFS= read -r bucket; do
        [[ -n "$bucket" ]] && check_s3_bucket "$bucket"
      done <<<"$bucket_list"
      record_check "AWS" "PASS" "INFO" "S3-INVENTORY" "account" "$(printf '%s\n' "$bucket_list" | wc -l | tr -d ' ') bucket(s) examinados globalmente." ""
    fi
  else
    api_error "S3-INVENTORY" "account" "s3:ListAllMyBuckets"
  fi
}

paint '1;36' 'AWS Cloud Security Lab — auditoría interna'
printf ' v%s\n' "$AUDIT_VERSION"
printf 'Run ID: %s\n' "$run_id"
printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
paint '1;32' 'Alcance: solo lectura'
printf '; host local y, salvo --local-only, S3 global + región AWS seleccionada.\n'
if [[ -n "${AWS_PROFILE:-}" ]]; then
  printf 'AWS profile: %s\n' "$AWS_PROFILE"
fi

check_host
if [[ "$LOCAL_ONLY" == "true" ]]; then
  print_phase 'PASO 2/4 y 3/4 — AWS omitido por --local-only'
  printf 'No se consultaron identidad, EC2, IAM, red AWS, CloudTrail ni S3.\n'
  record_check "AWS" "INFO" "INFO" "AWS-SCOPE" "AWS" "Auditoría AWS omitida por --local-only." ""
else
  export AWS_PAGER=""
  check_aws
fi

print_phase 'PASO 4/4 — Guardar evidencia y mostrar cómo revisarla'
printf 'Se genera un informe JSON, una bitácora de esta ejecución, un bundle y sus hashes.\n'
CHECKS_JSON="$(
  jq \
    --arg tool_version "$AUDIT_VERSION" \
    --arg run_id "$run_id" \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg region "$AWS_REGION_SELECTED" \
    --arg account_suffix "${ACCOUNT_ID: -4}" \
    --arg local_only "$LOCAL_ONLY" \
    --argjson inventory "$INVENTORY_JSON" \
    --argjson checks "$CHECKS_JSON" \
    '{
      tool: "AWS Cloud Security Lab Internal Auditor",
      tool_version: $tool_version,
      run_id: $run_id,
      generated_at_utc: $generated_at,
      read_only: true,
      scope: {
        host: $host,
        local_linux: true,
        aws_region: (if $local_only == "true" then null else $region end),
        aws_s3_scope: (if $local_only == "true" then "not-audited" else "all-account-buckets" end),
        aws_account_id_suffix: (if $account_suffix == "" then null else $account_suffix end)
      },
      summary: {
        checks_total: ($checks|length),
        findings_total: ([$checks[] | select(.status=="FAIL" or .status=="WARN" or .status=="ERROR")]|length),
        errors_total: ([$checks[] | select(.status=="ERROR")]|length)
      },
      inventory: $inventory,
      checks: $checks,
      findings: [$checks[] | select(.status=="FAIL" or .status=="WARN" or .status=="ERROR")]
    }' <<<"$CHECKS_JSON"
)"
printf '%s\n' "$CHECKS_JSON" >"$REPORT_FILE"
chmod 600 "$REPORT_FILE" "$AUDIT_LOG"

printf '\n'
paint '1;36' '== Resultado =='
printf '\n'
IFS=$'\t' read -r checks_total findings_total pass_count warn_count fail_count error_count < <(
  jq -r '[
    .summary.checks_total,
    .summary.findings_total,
    ([.checks[] | select(.status=="PASS")] | length),
    ([.checks[] | select(.status=="WARN")] | length),
    ([.checks[] | select(.status=="FAIL")] | length),
    .summary.errors_total
  ] | @tsv' "$REPORT_FILE"
)
printf '  Controles: %s  |  Hallazgos que requieren revisión: %s\n' "$checks_total" "$findings_total"
printf '  '
paint '32;1' "PASS $pass_count"
printf '    '
paint '33;1' "WARN $warn_count"
printf '    '
paint '31;1' "FAIL $fail_count"
printf '    '
paint '35;1' "ERROR/sin verificar $error_count"
printf '\n'
printf '  Informe:    %s/report.json\n' "$run_id"
printf '  Respaldo:   %s/bundle.tar.gz\n' "$run_id"
printf '  Integridad: %s/SHA256SUMS\n' "$run_id"
printf 'REPORT_JSON=%s\n' "$REPORT_FILE"
printf 'Nota: evidencia interna sensible; revisa permisos y contenido antes de compartir.\n'
printf '\nPara ver hallazgos y recomendaciones:\n'
printf 'jq -r '\''.findings[] | [.severity,.status,.control,.resource,.evidence,.recommendation] | @tsv'\'' "%s"\n' "$REPORT_FILE"
printf 'Para comprobar integridad del respaldo:\n'
printf 'sha256sum -c "%s/SHA256SUMS"\n' "$RUN_DIR"

exec 1>&3 2>&3
wait "$tee_pid"
sed -i 's/\x1B\[[0-9;]*m//g' "$AUDIT_LOG"
tar -C "$RUN_DIR" -czf "$RUN_DIR/bundle.tar.gz" report.json audit.log
chmod 600 "$RUN_DIR/bundle.tar.gz"
(
  cd -- "$RUN_DIR"
  sha256sum report.json audit.log bundle.tar.gz >SHA256SUMS
)
chmod 600 "$RUN_DIR/SHA256SUMS"
printf 'REPORT_BUNDLE=%s\n' "$RUN_DIR/bundle.tar.gz"
printf 'SHA256SUMS=%s\n' "$RUN_DIR/SHA256SUMS"

if [[ "$(jq -r '.summary.errors_total' "$REPORT_FILE")" -gt 0 ]]; then
  exit 2
fi
