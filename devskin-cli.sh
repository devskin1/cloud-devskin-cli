#!/usr/bin/env bash
# ============================================================================
# DevskinCloud CLI v1.0.0
# Manage your DevskinCloud infrastructure from the command line.
#
# Usage: devskin <command> [subcommand] [options]
# Run 'devskin --help' for full documentation.
# ============================================================================

set -euo pipefail

VERSION="1.0.0"
CONFIG_DIR="$HOME/.devskin"
CONFIG_FILE="$CONFIG_DIR/config"
API_URL="${DEVSKIN_API_URL:-https://cloud-api.devskin.com/api}"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Logging helpers ─────────────────────────────────────────────────────────
_info()    { echo -e "${BLUE}>>>${NC} $*"; }
_success() { echo -e "${GREEN}>>>${NC} $*"; }
_warn()    { echo -e "${YELLOW}>>>${NC} $*" >&2; }
_error()   { echo -e "${RED}>>>${NC} $*" >&2; }
_fatal()   { _error "$@"; exit 1; }

# ── Config helpers ──────────────────────────────────────────────────────────
_config_get() {
  local key="$1"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-
  fi
}

_config_set() {
  local key="$1" value="$2"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [[ -f "$CONFIG_FILE" ]] && grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      if [[ "$line" == "${key}="* ]]; then
        echo "${key}=${value}"
      else
        echo "$line"
      fi
    done < "$CONFIG_FILE" > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE"
}

_require_auth() {
  local token
  token=$(_config_get "token")
  if [[ -z "$token" ]]; then
    _fatal "Not authenticated. Run ${BOLD}devskin login${NC} or ${BOLD}devskin configure${NC} first."
  fi
}

# ── JSON parsing ────────────────────────────────────────────────────────────
# Prefer jq; fall back to python3/python.
_has_jq() { command -v jq &>/dev/null; }
_has_python() { command -v python3 &>/dev/null || command -v python &>/dev/null; }

_python_bin() {
  if command -v python3 &>/dev/null; then echo "python3"; else echo "python"; fi
}

_json_get() {
  # Usage: echo '{"a":1}' | _json_get '.a'
  local filter="$1"
  if _has_jq; then
    jq -r "$filter" 2>/dev/null
  elif _has_python; then
    $(_python_bin) -c "
import sys, json
data = json.load(sys.stdin)
keys = '''$filter'''.strip('.').split('.')
val = data
for k in keys:
    if k == '' : continue
    if isinstance(val, list):
        val = val[int(k)]
    else:
        val = val.get(k)
    if val is None: break
print(val if val is not None else '')
" 2>/dev/null
  else
    _fatal "Neither jq nor python found. Install jq for best results."
  fi
}

_json_array_len() {
  if _has_jq; then
    jq 'if type == "array" then length else 0 end' 2>/dev/null
  elif _has_python; then
    $(_python_bin) -c "
import sys, json
data = json.load(sys.stdin)
print(len(data) if isinstance(data, list) else 0)
" 2>/dev/null
  fi
}

_json_pretty() {
  if _has_jq; then
    jq '.' 2>/dev/null
  elif _has_python; then
    $(_python_bin) -m json.tool 2>/dev/null
  else
    cat
  fi
}

# ── Table formatter ─────────────────────────────────────────────────────────
# Usage: echo "$json_array" | _format_table field1 field2 field3 ...
_format_table() {
  local fields=("$@")
  local json
  json=$(cat)

  if [[ -z "$json" || "$json" == "null" || "$json" == "[]" ]]; then
    echo "  (no results)"
    return
  fi

  if _has_jq; then
    # Build header
    local header=""
    for f in "${fields[@]}"; do
      header="${header}${f}\t"
    done

    # Build jq expression
    local jq_expr='.[] | ['
    for i in "${!fields[@]}"; do
      [[ $i -gt 0 ]] && jq_expr+=','
      jq_expr+="(.${fields[$i]} // \"-\" | tostring)"
    done
    jq_expr+='] | @tsv'

    {
      echo -e "$header"
      echo "$json" | jq -r "$jq_expr" 2>/dev/null
    } | column -t -s $'\t' 2>/dev/null || {
      echo -e "$header"
      echo "$json" | jq -r "$jq_expr" 2>/dev/null
    }
  elif _has_python; then
    local fields_py
    fields_py=$(printf "'%s'," "${fields[@]}")
    fields_py="[${fields_py%,}]"

    echo "$json" | $(_python_bin) -c "
import sys, json
fields = $fields_py
data = json.load(sys.stdin)
if not isinstance(data, list):
    data = [data]
if not data:
    print('  (no results)')
    sys.exit(0)

# Calculate column widths
widths = [len(f) for f in fields]
rows = []
for item in data:
    row = []
    for i, f in enumerate(fields):
        val = item
        for part in f.split('.'):
            if isinstance(val, dict):
                val = val.get(part, '-')
            else:
                val = '-'
                break
        s = str(val) if val is not None else '-'
        row.append(s)
        widths[i] = max(widths[i], len(s))
    rows.append(row)

# Print header
header = '  '.join(f.upper().ljust(widths[i]) for i, f in enumerate(fields))
print(header)
print('-' * len(header))
for row in rows:
    print('  '.join(row[i].ljust(widths[i]) for i in range(len(fields))))
" 2>/dev/null
  else
    echo "$json" | _json_pretty
  fi
}

# ── API call helper ─────────────────────────────────────────────────────────
_api_call() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local token api_url
  token=$(_config_get "token")
  api_url=$(_config_get "api_url")
  api_url="${api_url:-$API_URL}"

  local args=(-s -w "\n%{http_code}" -X "$method" "${api_url}/api${endpoint}" -H "Content-Type: application/json")
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi

  local response http_code body
  response=$(curl "${args[@]}" 2>/dev/null) || _fatal "Failed to connect to ${api_url}. Check your network and API URL."

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    local msg
    msg=$(echo "$body" | _json_get '.message' 2>/dev/null || echo "$body")
    if [[ -z "$msg" || "$msg" == "null" || "$msg" == "None" ]]; then
      msg=$(echo "$body" | _json_get '.error' 2>/dev/null || echo "Request failed")
    fi
    _fatal "API error (HTTP ${http_code}): ${msg}"
  fi

  echo "$body"
}

# Convenience wrappers
_api_get()    { _api_call GET    "$1"; }
_api_post()   { _api_call POST   "$1" "${2:-}"; }
_api_patch()  { _api_call PATCH  "$1" "${2:-}"; }
_api_put()    { _api_call PUT    "$1" "${2:-}"; }
_api_delete() { _api_call DELETE "$1" "${2:-}"; }

# Extract data from standard { success, data } response
_extract_data() {
  local body="$1"
  if _has_jq; then
    echo "$body" | jq '.data // .' 2>/dev/null
  elif _has_python; then
    echo "$body" | $(_python_bin) -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('data', d)))
" 2>/dev/null
  else
    echo "$body"
  fi
}

# ── Argument parsing helpers ────────────────────────────────────────────────
_require_arg() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    _fatal "Missing required argument: ${BOLD}${name}${NC}"
  fi
}

_parse_flag() {
  # Usage: value=$(_parse_flag "--name" "$@") — searches args for --name VALUE
  local flag="$1"; shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$flag" && $# -ge 2 ]]; then
      echo "$2"
      return 0
    fi
    shift
  done
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
#                            COMMANDS
# ════════════════════════════════════════════════════════════════════════════

# ── configure ───────────────────────────────────────────────────────────────
cmd_configure() {
  echo -e "${BOLD}DevskinCloud CLI Configuration${NC}"
  echo ""

  local current_url current_token
  current_url=$(_config_get "api_url")
  current_token=$(_config_get "token")

  read -rp "API URL [${current_url:-$API_URL}]: " input_url
  input_url="${input_url:-${current_url:-$API_URL}}"
  _config_set "api_url" "$input_url"

  read -rp "API Token [${current_token:+****${current_token: -4}}]: " input_token
  input_token="${input_token:-$current_token}"
  if [[ -n "$input_token" ]]; then
    _config_set "token" "$input_token"
  fi

  echo ""
  _success "Configuration saved to ${CONFIG_FILE}"
}

# ── login ───────────────────────────────────────────────────────────────────
cmd_login() {
  echo -e "${BOLD}DevskinCloud Login${NC}"
  echo ""

  read -rp "Email: " email
  _require_arg "email" "$email"

  read -rsp "Password: " password
  echo ""
  _require_arg "password" "$password"

  _info "Authenticating..."
  local body
  body=$(_api_post "/auth/login" "{\"email\":\"${email}\",\"password\":\"${password}\"}")

  local token
  token=$(echo "$body" | _json_get '.token')
  if [[ -z "$token" || "$token" == "null" || "$token" == "None" ]]; then
    token=$(echo "$body" | _json_get '.data.token')
  fi

  if [[ -z "$token" || "$token" == "null" || "$token" == "None" ]]; then
    _fatal "Login failed. No token received."
  fi

  _config_set "token" "$token"

  local user_name
  user_name=$(echo "$body" | _json_get '.user.name' 2>/dev/null || echo "")
  if [[ -z "$user_name" || "$user_name" == "null" || "$user_name" == "None" ]]; then
    user_name=$(echo "$body" | _json_get '.data.user.name' 2>/dev/null || echo "")
  fi

  _success "Login successful!${user_name:+ Welcome, ${user_name}.}"
}

# ── logout ──────────────────────────────────────────────────────────────────
cmd_logout() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local tmp
    tmp=$(mktemp)
    grep -v "^token=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$CONFIG_FILE"
  fi
  _success "Logged out. Token removed."
}

# ── whoami ──────────────────────────────────────────────────────────────────
cmd_whoami() {
  _require_auth
  local body
  body=$(_api_get "/auth/me")

  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Current User${NC}"
  echo ""
  echo "  ID:    $(echo "$data" | _json_get '.id')"
  echo "  Name:  $(echo "$data" | _json_get '.name')"
  echo "  Email: $(echo "$data" | _json_get '.email')"
  echo "  Role:  $(echo "$data" | _json_get '.role')"
}

# ════════════════════════════════════════════════════════════════════════════
#                         COMPUTE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_compute() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       compute_list "$@" ;;
    create)     compute_create "$@" ;;
    start)      compute_action "start" "$@" ;;
    stop)       compute_action "stop" "$@" ;;
    reboot)     compute_action "reboot" "$@" ;;
    terminate)  compute_terminate "$@" ;;
    ssh)        compute_ssh "$@" ;;
    get|show)   compute_get "$@" ;;
    help|*)     compute_help ;;
  esac
}

compute_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin compute <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all instances
  create --name NAME --type TYPE --image IMAGE [--keypair KP] [--vpc VPC] [--subnet SUB] [--sg SG]
         [--monitoring-api-key KEY]
                                    Create a new instance (set --monitoring-api-key to enroll the
                                    VM into Flux observability at boot)
  get ID                            Show instance details
  start ID                          Start a stopped instance
  stop ID                           Stop a running instance
  reboot ID                         Reboot an instance
  terminate ID                      Terminate (delete) an instance
  ssh ID                            SSH into an instance
EOF
}

compute_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/instances")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Compute Instances${NC}"
  echo ""
  echo "$data" | _format_table id name instanceType status publicIp availabilityZone
}

compute_create() {
  _require_auth
  local name type image keypair vpc subnet sg monitoring_key
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  image=$(_parse_flag "--image" "$@")
  keypair=$(_parse_flag "--keypair" "$@")
  vpc=$(_parse_flag "--vpc" "$@")
  subnet=$(_parse_flag "--subnet" "$@")
  sg=$(_parse_flag "--sg" "$@")
  monitoring_key=$(_parse_flag "--monitoring-api-key" "$@")

  _require_arg "--name" "$name"
  _require_arg "--type" "$type"
  _require_arg "--image" "$image"

  local payload="{\"name\":\"${name}\",\"instanceType\":\"${type}\",\"imageId\":\"${image}\""
  [[ -n "$keypair" ]] && payload="${payload},\"keyPairId\":\"${keypair}\""
  [[ -n "$vpc" ]]     && payload="${payload},\"vpcId\":\"${vpc}\""
  [[ -n "$subnet" ]]  && payload="${payload},\"subnetId\":\"${subnet}\""
  [[ -n "$sg" ]]      && payload="${payload},\"securityGroupId\":\"${sg}\""
  if [[ -n "$monitoring_key" ]]; then
    payload="${payload},\"monitoring\":true,\"monitoringEnrollment\":{\"enabled\":true,\"apiKey\":\"${monitoring_key}\"}"
  fi
  payload="${payload}}"

  _info "Creating instance ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/compute/instances" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Instance created."
  echo ""
  echo "  ID:     $(echo "$data" | _json_get '.id')"
  echo "  Name:   $(echo "$data" | _json_get '.name')"
  echo "  Type:   $(echo "$data" | _json_get '.instanceType')"
  echo "  Status: $(echo "$data" | _json_get '.status')"
}

compute_action() {
  _require_auth
  local action="$1"; shift
  local id="${1:-}"
  _require_arg "INSTANCE_ID" "$id"

  _info "${action^}ing instance ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/compute/instances/${id}/action" "{\"action\":\"${action}\"}")
  _success "Instance ${id} ${action} command sent."
}

compute_terminate() {
  _require_auth
  local id="${1:-}"
  _require_arg "INSTANCE_ID" "$id"

  read -rp "Are you sure you want to terminate instance ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Terminating instance ${BOLD}${id}${NC} ..."
  _api_delete "/compute/instances/${id}" >/dev/null
  _success "Instance ${id} terminated."
}

compute_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "INSTANCE_ID" "$id"

  local body
  body=$(_api_get "/compute/instances/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Instance Details${NC}"
  echo ""
  echo "  ID:                $(echo "$data" | _json_get '.id')"
  echo "  Name:              $(echo "$data" | _json_get '.name')"
  echo "  Type:              $(echo "$data" | _json_get '.instanceType')"
  echo "  Status:            $(echo "$data" | _json_get '.status')"
  echo "  Public IP:         $(echo "$data" | _json_get '.publicIp')"
  echo "  Private IP:        $(echo "$data" | _json_get '.privateIp')"
  echo "  Availability Zone: $(echo "$data" | _json_get '.availabilityZone')"
  echo "  Image:             $(echo "$data" | _json_get '.imageId')"
  echo "  Key Pair:          $(echo "$data" | _json_get '.keyPairName')"
  echo "  Created:           $(echo "$data" | _json_get '.createdAt')"

  # Best-effort surface marketplace credentials and protocol hint via /connect.
  # The endpoint is omitted for plain VMs; ignore failure silently.
  local conn_body conn_data is_proto svc_port login pwd
  conn_body=$(_api_get "/compute/instances/${id}/connect" 2>/dev/null || true)
  if [[ -n "$conn_body" ]]; then
    conn_data=$(_extract_data "$conn_body" 2>/dev/null || true)
    is_proto=$(echo "$conn_data"  | _json_get '.isProtocolOnly' 2>/dev/null || echo "")
    svc_port=$(echo "$conn_data"  | _json_get '.servicePort' 2>/dev/null || echo "")
    login=$(echo "$conn_data"     | _json_get '.marketplace.defaultCredentials.username' 2>/dev/null || echo "")
    pwd=$(echo "$conn_data"       | _json_get '.marketplace.defaultCredentials.password' 2>/dev/null || echo "")
    if [[ -n "$svc_port" && "$svc_port" != "null" ]]; then
      echo ""
      echo -e "${BOLD}Service${NC}"
      echo "  Port:              ${svc_port}"
      [[ "$is_proto" == "true" ]] && echo "  Protocol-only:     yes (no HTTP login page — connect with the service client)"
      if [[ -n "$login" && "$login" != "null" ]]; then
        echo "  App username:      ${login}"
      fi
      if [[ -n "$pwd" && "$pwd" != "null" ]]; then
        echo "  App password:      ${pwd}"
      fi
    fi
  fi
}

compute_ssh() {
  _require_auth
  local id="${1:-}"
  _require_arg "INSTANCE_ID" "$id"

  _info "Fetching connection info for instance ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_get "/compute/instances/${id}")
  local data
  data=$(_extract_data "$body")

  local ip user key_name
  ip=$(echo "$data" | _json_get '.publicIp')
  user=$(echo "$data" | _json_get '.sshUser' 2>/dev/null || echo "")
  key_name=$(echo "$data" | _json_get '.keyPairName' 2>/dev/null || echo "")

  if [[ -z "$ip" || "$ip" == "null" || "$ip" == "None" || "$ip" == "-" ]]; then
    _fatal "Instance has no public IP. Assign an elastic IP or check the instance status."
  fi

  user="${user:-ubuntu}"
  [[ "$user" == "null" || "$user" == "None" ]] && user="ubuntu"

  local ssh_args=()
  if [[ -n "$key_name" && "$key_name" != "null" && "$key_name" != "None" ]]; then
    local key_path="$HOME/.ssh/${key_name}.pem"
    if [[ -f "$key_path" ]]; then
      ssh_args+=(-i "$key_path")
    else
      _warn "Key file ${key_path} not found. SSH may fail."
      _warn "Download your key pair and place it at ${key_path}"
    fi
  fi

  ssh_args+=(-o "StrictHostKeyChecking=no" "${user}@${ip}")

  _info "Connecting: ssh ${ssh_args[*]}"
  exec ssh "${ssh_args[@]}"
}

# ════════════════════════════════════════════════════════════════════════════
#                         DATABASE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_db() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       db_list "$@" ;;
    create)     db_create "$@" ;;
    get|show)   db_get "$@" ;;
    delete)     db_delete "$@" ;;
    start)      db_action "start" "$@" ;;
    stop)       db_action "stop" "$@" ;;
    reboot)     db_action "reboot" "$@" ;;
    snapshot)   db_snapshot "$@" ;;
    help|*)     db_help ;;
  esac
}

db_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin db <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all database instances
  create --name NAME --engine ENGINE --class CLASS --storage SIZE
                                    Create a new database instance
  get ID                            Show database details
  start ID                          Start a stopped database
  stop ID                           Stop a running database
  reboot ID                         Reboot a database
  delete ID                         Delete a database instance
  snapshot ID --name NAME           Create a snapshot of a database
EOF
}

db_list() {
  _require_auth
  local body
  body=$(_api_get "/database/instances")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Database Instances${NC}"
  echo ""
  echo "$data" | _format_table id name engine status instanceClass storageGb
}

db_create() {
  _require_auth
  local name engine class storage
  name=$(_parse_flag "--name" "$@")
  engine=$(_parse_flag "--engine" "$@")
  class=$(_parse_flag "--class" "$@")
  storage=$(_parse_flag "--storage" "$@")

  _require_arg "--name" "$name"
  _require_arg "--engine" "$engine"
  _require_arg "--class" "$class"
  _require_arg "--storage" "$storage"

  local payload="{\"name\":\"${name}\",\"engine\":\"${engine}\",\"instanceClass\":\"${class}\",\"storageGb\":${storage}}"

  _info "Creating database ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/database/instances" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Database created."
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  Engine:  $(echo "$data" | _json_get '.engine')"
  echo "  Status:  $(echo "$data" | _json_get '.status')"
}

db_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "DATABASE_ID" "$id"

  local body
  body=$(_api_get "/database/instances/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Database Details${NC}"
  echo ""
  echo "  ID:             $(echo "$data" | _json_get '.id')"
  echo "  Name:           $(echo "$data" | _json_get '.name')"
  echo "  Engine:         $(echo "$data" | _json_get '.engine')"
  echo "  Status:         $(echo "$data" | _json_get '.status')"
  echo "  Instance Class: $(echo "$data" | _json_get '.instanceClass')"
  echo "  Storage (GB):   $(echo "$data" | _json_get '.storageGb')"
  echo "  Endpoint:       $(echo "$data" | _json_get '.endpoint')"
  echo "  Created:        $(echo "$data" | _json_get '.createdAt')"
}

db_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "DATABASE_ID" "$id"

  read -rp "Are you sure you want to delete database ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting database ${BOLD}${id}${NC} ..."
  _api_delete "/database/instances/${id}" >/dev/null
  _success "Database ${id} deleted."
}

db_action() {
  _require_auth
  local action="$1"; shift
  local id="${1:-}"
  _require_arg "DATABASE_ID" "$id"

  _info "${action^}ing database ${BOLD}${id}${NC} ..."
  _api_post "/database/instances/${id}/${action}" >/dev/null
  _success "Database ${id} ${action} command sent."
}

db_snapshot() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "DATABASE_ID" "$id"

  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating snapshot ${BOLD}${name}${NC} for database ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/database/instances/${id}/snapshots" "{\"name\":\"${name}\"}")
  _success "Snapshot created."
}

# ════════════════════════════════════════════════════════════════════════════
#                         STORAGE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_storage() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       storage_list "$@" ;;
    create)     storage_create "$@" ;;
    get|show)   storage_get "$@" ;;
    delete)     storage_delete "$@" ;;
    help|*)     storage_help ;;
  esac
}

storage_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin storage <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all storage buckets
  create --name NAME [--region REGION] [--versioning true|false]
                                    Create a new bucket
  get ID                            Show bucket details
  delete ID                         Delete a bucket
EOF
}

storage_list() {
  _require_auth
  local body
  body=$(_api_get "/storage/buckets")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Storage Buckets${NC}"
  echo ""
  echo "$data" | _format_table id name region objectCount sizeBytes status
}

storage_create() {
  _require_auth
  local name region versioning
  name=$(_parse_flag "--name" "$@")
  region=$(_parse_flag "--region" "$@")
  versioning=$(_parse_flag "--versioning" "$@")

  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$region" ]]     && payload="${payload},\"region\":\"${region}\""
  [[ -n "$versioning" ]] && payload="${payload},\"versioning\":${versioning}"
  payload="${payload}}"

  _info "Creating bucket ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/storage/buckets" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Bucket created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

storage_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "BUCKET_ID" "$id"

  local body
  body=$(_api_get "/storage/buckets/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Bucket Details${NC}"
  echo ""
  echo "  ID:           $(echo "$data" | _json_get '.id')"
  echo "  Name:         $(echo "$data" | _json_get '.name')"
  echo "  Region:       $(echo "$data" | _json_get '.region')"
  echo "  Objects:      $(echo "$data" | _json_get '.objectCount')"
  echo "  Size:         $(echo "$data" | _json_get '.sizeBytes')"
  echo "  Versioning:   $(echo "$data" | _json_get '.versioning')"
  echo "  Status:       $(echo "$data" | _json_get '.status')"
  echo "  Created:      $(echo "$data" | _json_get '.createdAt')"
}

storage_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "BUCKET_ID" "$id"

  read -rp "Are you sure you want to delete bucket ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting bucket ${BOLD}${id}${NC} ..."
  _api_delete "/storage/buckets/${id}" >/dev/null
  _success "Bucket ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                         VOLUME COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_volume() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       volume_list "$@" ;;
    create)     volume_create "$@" ;;
    get|show)   volume_get "$@" ;;
    attach)     volume_attach "$@" ;;
    detach)     volume_detach "$@" ;;
    delete)     volume_delete "$@" ;;
    help|*)     volume_help ;;
  esac
}

volume_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin volume <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all volumes
  create --name NAME --size SIZE --type TYPE
                                    Create a new volume
  get ID                            Show volume details
  attach VOLUME_ID INSTANCE_ID      Attach a volume to an instance
  detach VOLUME_ID                  Detach a volume
  delete ID                         Delete a volume
EOF
}

volume_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/volumes")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Volumes${NC}"
  echo ""
  echo "$data" | _format_table id name size volumeType status attachedTo availabilityZone
}

volume_create() {
  _require_auth
  local name size type
  name=$(_parse_flag "--name" "$@")
  size=$(_parse_flag "--size" "$@")
  type=$(_parse_flag "--type" "$@")

  _require_arg "--name" "$name"
  _require_arg "--size" "$size"
  _require_arg "--type" "$type"

  local payload="{\"name\":\"${name}\",\"size\":${size},\"volumeType\":\"${type}\"}"

  _info "Creating volume ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/compute/volumes" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Volume created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
  echo "  Size: $(echo "$data" | _json_get '.size') GB"
  echo "  Type: $(echo "$data" | _json_get '.volumeType')"
}

volume_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "VOLUME_ID" "$id"

  local body
  body=$(_api_get "/compute/volumes/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Volume Details${NC}"
  echo ""
  echo "  ID:                $(echo "$data" | _json_get '.id')"
  echo "  Name:              $(echo "$data" | _json_get '.name')"
  echo "  Size:              $(echo "$data" | _json_get '.size') GB"
  echo "  Type:              $(echo "$data" | _json_get '.volumeType')"
  echo "  Status:            $(echo "$data" | _json_get '.status')"
  echo "  Attached To:       $(echo "$data" | _json_get '.attachedTo')"
  echo "  Availability Zone: $(echo "$data" | _json_get '.availabilityZone')"
  echo "  Created:           $(echo "$data" | _json_get '.createdAt')"
}

volume_attach() {
  _require_auth
  local volume_id="${1:-}"
  local instance_id="${2:-}"
  _require_arg "VOLUME_ID" "$volume_id"
  _require_arg "INSTANCE_ID" "$instance_id"

  _info "Attaching volume ${BOLD}${volume_id}${NC} to instance ${BOLD}${instance_id}${NC} ..."
  _api_post "/compute/volumes/${volume_id}/attach" "{\"instanceId\":\"${instance_id}\"}" >/dev/null
  _success "Volume attached."
}

volume_detach() {
  _require_auth
  local volume_id="${1:-}"
  _require_arg "VOLUME_ID" "$volume_id"

  _info "Detaching volume ${BOLD}${volume_id}${NC} ..."
  _api_post "/compute/volumes/${volume_id}/detach" >/dev/null
  _success "Volume detached."
}

volume_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "VOLUME_ID" "$id"

  read -rp "Are you sure you want to delete volume ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting volume ${BOLD}${id}${NC} ..."
  _api_delete "/compute/volumes/${id}" >/dev/null
  _success "Volume ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                        NETWORKING COMMANDS
# ════════════════════════════════════════════════════════════════════════════

# ── VPC ─────────────────────────────────────────────────────────────────────

cmd_vpc() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       vpc_list "$@" ;;
    create)     vpc_create "$@" ;;
    get|show)   vpc_get "$@" ;;
    delete)     vpc_delete "$@" ;;
    help|*)     vpc_help ;;
  esac
}

vpc_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin vpc <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all VPCs
  create --name NAME --cidr CIDR    Create a new VPC
  get ID                            Show VPC details
  delete ID                         Delete a VPC
EOF
}

vpc_list() {
  _require_auth
  local body
  body=$(_api_get "/networking/vpcs")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}VPCs${NC}"
  echo ""
  echo "$data" | _format_table id name cidrBlock status subnets
}

vpc_create() {
  _require_auth
  local name cidr
  name=$(_parse_flag "--name" "$@")
  cidr=$(_parse_flag "--cidr" "$@")

  _require_arg "--name" "$name"
  _require_arg "--cidr" "$cidr"

  _info "Creating VPC ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/networking/vpcs" "{\"name\":\"${name}\",\"cidrBlock\":\"${cidr}\"}")
  local data
  data=$(_extract_data "$body")

  _success "VPC created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
  echo "  CIDR: $(echo "$data" | _json_get '.cidrBlock')"
}

vpc_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "VPC_ID" "$id"

  local body
  body=$(_api_get "/networking/vpcs/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}VPC Details${NC}"
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  CIDR:    $(echo "$data" | _json_get '.cidrBlock')"
  echo "  Status:  $(echo "$data" | _json_get '.status')"
  echo "  Created: $(echo "$data" | _json_get '.createdAt')"
}

vpc_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "VPC_ID" "$id"

  read -rp "Are you sure you want to delete VPC ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting VPC ${BOLD}${id}${NC} ..."
  _api_delete "/networking/vpcs/${id}" >/dev/null
  _success "VPC ${id} deleted."
}

# ── Elastic IP ──────────────────────────────────────────────────────────────

cmd_elastic_ip() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)         eip_list "$@" ;;
    allocate)     eip_allocate "$@" ;;
    release)      eip_release "$@" ;;
    associate)    eip_associate "$@" ;;
    disassociate) eip_disassociate "$@" ;;
    help|*)       eip_help ;;
  esac
}

eip_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin elastic-ip <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all elastic IPs
  allocate                          Allocate a new elastic IP
  release ID                        Release an elastic IP
  associate IP_ID INSTANCE_ID       Associate an elastic IP with an instance
  associate IP_ID --cluster ID --node NAME
                                    OR associate to a Kubernetes node
                                    (master-XXX or worker-YYY from cluster.tags.vmIps).
                                    Auto-opens 80/443/30080/30443 on pfSense.
  disassociate IP_ID                Disassociate an elastic IP
EOF
}

eip_list() {
  _require_auth
  local body
  body=$(_api_get "/networking/elastic-ips")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Elastic IPs${NC}"
  echo ""
  echo "$data" | _format_table id publicIp status associatedInstanceId
}

eip_allocate() {
  _require_auth
  _info "Allocating elastic IP ..."
  local body
  body=$(_api_post "/networking/elastic-ips" "{}")
  local data
  data=$(_extract_data "$body")

  _success "Elastic IP allocated."
  echo ""
  echo "  ID:        $(echo "$data" | _json_get '.id')"
  echo "  Public IP: $(echo "$data" | _json_get '.publicIp')"
}

eip_release() {
  _require_auth
  local id="${1:-}"
  _require_arg "ELASTIC_IP_ID" "$id"

  _info "Releasing elastic IP ${BOLD}${id}${NC} ..."
  _api_delete "/networking/elastic-ips/${id}" >/dev/null
  _success "Elastic IP ${id} released."
}

eip_associate() {
  _require_auth
  local ip_id="${1:-}"
  shift || true
  _require_arg "ELASTIC_IP_ID" "$ip_id"

  # Either: instance_id positional OR --cluster + --node flags for K8s nodes
  local instance_id="${1:-}"
  local cluster_id node_name
  cluster_id=$(_parse_flag "--cluster" "$@")
  node_name=$(_parse_flag "--node" "$@")

  local payload
  if [[ -n "$cluster_id" && -n "$node_name" ]]; then
    _info "Associating elastic IP ${BOLD}${ip_id}${NC} with K8s node ${BOLD}${cluster_id}/${node_name}${NC} ..."
    payload="{\"kubernetesClusterId\":\"${cluster_id}\",\"nodeName\":\"${node_name}\"}"
  elif [[ -n "$instance_id" && "$instance_id" != --* ]]; then
    _info "Associating elastic IP ${BOLD}${ip_id}${NC} with instance ${BOLD}${instance_id}${NC} ..."
    payload="{\"instanceId\":\"${instance_id}\"}"
  else
    _err "Provide either INSTANCE_ID or --cluster CLUSTER_ID --node NODE_NAME"
    return 1
  fi

  _api_post "/networking/elastic-ips/${ip_id}/associate" "$payload" >/dev/null
  _success "Elastic IP associated."
}

eip_disassociate() {
  _require_auth
  local ip_id="${1:-}"
  _require_arg "ELASTIC_IP_ID" "$ip_id"

  _info "Disassociating elastic IP ${BOLD}${ip_id}${NC} ..."
  _api_post "/networking/elastic-ips/${ip_id}/disassociate" >/dev/null
  _success "Elastic IP disassociated."
}

# ════════════════════════════════════════════════════════════════════════════
#                        FUNCTIONS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_function() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       fn_list "$@" ;;
    create)     fn_create "$@" ;;
    get|show)   fn_get "$@" ;;
    invoke)     fn_invoke "$@" ;;
    delete)     fn_delete "$@" ;;
    help|*)     fn_help ;;
  esac
}

fn_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin function <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all functions
  create --name NAME --runtime RUNTIME [--memory MEM] [--timeout SEC]
                                    Create a new function
  get ID                            Show function details
  invoke ID --payload '{}'          Invoke a function
  delete ID                         Delete a function
EOF
}

fn_list() {
  _require_auth
  local body
  body=$(_api_get "/functions")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Functions${NC}"
  echo ""
  echo "$data" | _format_table id name runtime status memory timeout lastInvoked
}

fn_create() {
  _require_auth
  local name runtime memory timeout
  name=$(_parse_flag "--name" "$@")
  runtime=$(_parse_flag "--runtime" "$@")
  memory=$(_parse_flag "--memory" "$@")
  timeout=$(_parse_flag "--timeout" "$@")

  _require_arg "--name" "$name"
  _require_arg "--runtime" "$runtime"

  local payload="{\"name\":\"${name}\",\"runtime\":\"${runtime}\""
  [[ -n "$memory" ]]  && payload="${payload},\"memory\":${memory}"
  [[ -n "$timeout" ]] && payload="${payload},\"timeout\":${timeout}"
  payload="${payload}}"

  _info "Creating function ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/functions" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Function created."
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  Runtime: $(echo "$data" | _json_get '.runtime')"
}

fn_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "FUNCTION_ID" "$id"

  local body
  body=$(_api_get "/functions/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Function Details${NC}"
  echo ""
  echo "  ID:           $(echo "$data" | _json_get '.id')"
  echo "  Name:         $(echo "$data" | _json_get '.name')"
  echo "  Runtime:      $(echo "$data" | _json_get '.runtime')"
  echo "  Status:       $(echo "$data" | _json_get '.status')"
  echo "  Memory:       $(echo "$data" | _json_get '.memory') MB"
  echo "  Timeout:      $(echo "$data" | _json_get '.timeout') s"
  echo "  Last Invoked: $(echo "$data" | _json_get '.lastInvoked')"
  echo "  Created:      $(echo "$data" | _json_get '.createdAt')"
}

fn_invoke() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "FUNCTION_ID" "$id"

  local payload
  payload=$(_parse_flag "--payload" "$@")
  payload="${payload:-{\}}"

  _info "Invoking function ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/functions/${id}/invoke" "{\"payload\":${payload}}")
  local data
  data=$(_extract_data "$body")

  _success "Function invoked."
  echo ""
  echo -e "${BOLD}Response:${NC}"
  echo "$data" | _json_pretty
}

fn_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "FUNCTION_ID" "$id"

  read -rp "Are you sure you want to delete function ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting function ${BOLD}${id}${NC} ..."
  _api_delete "/functions/${id}" >/dev/null
  _success "Function ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       KUBERNETES COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_k8s() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)             k8s_list "$@" ;;
    create)           k8s_create "$@" ;;
    update)           k8s_update "$@" ;;
    get|show)         k8s_get "$@" ;;
    oidc)             k8s_oidc "$@" ;;
    autoscaler)       k8s_autoscaler "$@" ;;
    autoheal)         k8s_autoheal "$@" ;;
    namespace-costs)  k8s_namespace_costs "$@" ;;
    delete)           k8s_delete "$@" ;;
    backups)          k8s_backups_list "$@" ;;
    backup)           k8s_backup_create "$@" ;;
    backup-download)  k8s_backup_download "$@" ;;
    backup-delete)    k8s_backup_delete "$@" ;;
    optimize)         k8s_optimize "$@" ;;
    help|*)           k8s_help ;;
  esac
}

k8s_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin k8s <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all Kubernetes clusters
  create --name NAME --version VERSION [--nodes N] [--region R] [--vpc-id ID]
         [--max-pods N]             Max pods per node (default 110)
         [--cni calico|flannel]     Default calico
         [--addons LIST]            Comma-separated: metrics-server,ingress-nginx,
                                    cert-manager,kyverno,cilium,longhorn,velero,
                                    irsa,local-path  (defaults: metrics+local-path+irsa)
         [--ha]                     HA control plane (3 masters, ~R\$100-150/month extra)
         [--backup-bucket ID]       S3 bucket id for etcd backups
         [--backup-retention N]     Retention days, 1-90 (default 7)
         [--allowed-cidrs LIST]     Comma-separated CIDRs allowed to reach the API
                                    (default 0.0.0.0/0)
         [--default-deny-netpol]    Install default-deny NetworkPolicy addon
         [--autoscaler]             Enable Cluster Autoscaler (Proxmox-aware)
         [--autoscaler-min N]       Min worker nodes when autoscaler enabled (default 1)
         [--autoscaler-max N]       Max worker nodes cap (default 10)
         [--no-autoheal]            Disable Node Auto-Heal (default ENABLED). Auto-heal
                                    replaces dead workers (kubelet down/VM crashed) with
                                    fresh VMs automatically.
                                    Create a new cluster
  update ID [--backup-bucket ID] [--backup-retention N] [--allowed-cidrs LIST]
            [--addon=NAME=BOOL] [--autoscaler] [--no-autoscaler]
            [--autoscaler-min N] [--autoscaler-max N]
            [--autoheal] [--no-autoheal]
                                    Edit cluster post-creation (at least one flag required).
                                    --addon may repeat; NAME matches create's --addons keys.
  get ID                            Show cluster details
  oidc ID                           Show the cluster's OIDC issuer + JWKS URL (for IRSA setup)
  autoscaler ID                     Show Cluster Autoscaler status + recent scale events
  autoheal ID                       Show Node Auto-Heal recent replacements
  namespace-costs ID|--all          Per-namespace K8s cost attribution (CPU·h, RAM GB·h,
                                    pods, USD) over a chosen period.
            [--from ISO]            Period start (default: 30 days ago)
            [--to   ISO]            Period end   (default: now)
            [--group-by namespace|label]  Group rows (default namespace)
            [--label-key KEY]       Required when --group-by=label
            [--export-csv FILE]     Also write the rows to a CSV file
            --all                   Aggregate across every cluster in the org
  delete ID                         Delete a cluster
  backups ID                        List etcd backups for the cluster
  backup ID                         Trigger a manual backup snapshot
  backup-download ID BACKUP_ID [--save PATH]
                                    Get presigned URL (or download to PATH)
  backup-delete ID BACKUP_ID        Delete a backup (asks for confirmation)

${BOLD}Optimization (KubeTurbo-equivalent recommendations):${NC}
  optimize list [--cluster ID] [--status NEW|APPLIED|DISMISSED|EXPIRED]
                [--type rightsizing|binpack] [--sort savings|confidence|newest]
                                    List cluster optimization recommendations
  optimize show ID                  Show recommendation detail (incl. metrics snapshot)
  optimize apply ID                 Apply a recommendation — MODIFIES the cluster
                                    (rightsizing patches the Deployment;
                                     bin-packing drains the target node).
                                    Asks for confirmation.
  optimize dismiss ID               Dismiss without applying
  optimize savings [--cluster ID]   Aggregated potential + applied savings
  optimize scan                     Admin: trigger a fresh analyzer pass
EOF
}

k8s_list() {
  _require_auth
  local body
  body=$(_api_get "/kubernetes/clusters")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Kubernetes Clusters${NC}"
  echo ""
  echo "$data" | _format_table id name version status nodeCount region
}

_has_bool_flag() {
  # Usage: _has_bool_flag "--ha" "$@"  → echoes 1 if flag present, 0 otherwise.
  local flag="$1"; shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$flag" ]]; then echo 1; return 0; fi
    shift
  done
  echo 0
}

# Map CLI addon alias → backend addon key (shared between create + update).
_k8s_addon_key() {
  local a="$1"
  case "$a" in
    metrics-server)    echo "metricsServer" ;;
    ingress-nginx)     echo "ingressNginx" ;;
    cert-manager)      echo "certManager" ;;
    local-path)        echo "localPathStorage" ;;
    default-deny-netpol|defaultDenyNetpol)
                       echo "defaultDenyNetpol" ;;
    *)                 echo "$a" ;;
  esac
}

# Build a JSON array literal from a comma-separated list.
# Echoes e.g.  ["10.0.0.0/8","192.168.0.0/16"]
_csv_to_json_array() {
  local csv="$1"
  local out="["
  local first=1
  IFS=',' read -ra ITEMS <<< "$csv"
  for item in "${ITEMS[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z "$item" ]] && continue
    [[ $first -eq 0 ]] && out="${out},"
    out="${out}\"${item}\""
    first=0
  done
  out="${out}]"
  echo "$out"
}

k8s_create() {
  _require_auth
  local name version nodes region vpc_id max_pods cni addons
  local backup_bucket backup_retention allowed_cidrs ha default_deny_netpol
  local autoscaler autoscaler_min autoscaler_max
  name=$(_parse_flag "--name" "$@")
  version=$(_parse_flag "--version" "$@")
  nodes=$(_parse_flag "--nodes" "$@")
  region=$(_parse_flag "--region" "$@")
  vpc_id=$(_parse_flag "--vpc-id" "$@")
  max_pods=$(_parse_flag "--max-pods" "$@")
  cni=$(_parse_flag "--cni" "$@")
  addons=$(_parse_flag "--addons" "$@")
  backup_bucket=$(_parse_flag "--backup-bucket" "$@")
  backup_retention=$(_parse_flag "--backup-retention" "$@")
  allowed_cidrs=$(_parse_flag "--allowed-cidrs" "$@")
  ha=$(_has_bool_flag "--ha" "$@")
  default_deny_netpol=$(_has_bool_flag "--default-deny-netpol" "$@")
  autoscaler=$(_has_bool_flag "--autoscaler" "$@")
  autoscaler_min=$(_parse_flag "--autoscaler-min" "$@")
  autoscaler_max=$(_parse_flag "--autoscaler-max" "$@")
  local no_autoheal
  no_autoheal=$(_has_bool_flag "--no-autoheal" "$@")

  _require_arg "--name" "$name"
  _require_arg "--version" "$version"

  if [[ -n "$backup_retention" ]]; then
    if ! [[ "$backup_retention" =~ ^[0-9]+$ ]] || [[ "$backup_retention" -lt 1 ]] || [[ "$backup_retention" -gt 90 ]]; then
      _fatal "--backup-retention must be an integer between 1 and 90."
    fi
  fi

  if [[ -n "$autoscaler_min" ]] && ! [[ "$autoscaler_min" =~ ^[0-9]+$ ]]; then
    _fatal "--autoscaler-min must be a non-negative integer."
  fi
  if [[ -n "$autoscaler_max" ]] && ! [[ "$autoscaler_max" =~ ^[0-9]+$ ]]; then
    _fatal "--autoscaler-max must be a non-negative integer."
  fi

  if [[ "$ha" == "1" ]]; then
    _warn "WARNING: HA cluster uses 3 masters (~R\$100-150/month extra). Cannot be undone after creation."
    read -rp "Continue creating HA cluster ${name}? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
      echo "Aborted."
      return
    fi
  fi

  local payload="{\"name\":\"${name}\",\"version\":\"${version}\""
  [[ -n "$nodes" ]]            && payload="${payload},\"nodeCount\":${nodes}"
  [[ -n "$region" ]]           && payload="${payload},\"region\":\"${region}\""
  [[ -n "$vpc_id" ]]           && payload="${payload},\"vpcId\":\"${vpc_id}\""
  [[ -n "$max_pods" ]]         && payload="${payload},\"maxPods\":${max_pods}"
  [[ -n "$cni" ]]              && payload="${payload},\"cni\":\"${cni}\""
  [[ "$ha" == "1" ]]           && payload="${payload},\"haControlPlane\":true"
  [[ -n "$backup_bucket" ]]    && payload="${payload},\"backupBucketId\":\"${backup_bucket}\""
  [[ -n "$backup_retention" ]] && payload="${payload},\"backupRetention\":${backup_retention}"
  if [[ -n "$allowed_cidrs" ]]; then
    payload="${payload},\"allowedSourceCidrs\":$(_csv_to_json_array "$allowed_cidrs")"
  fi
  [[ "$autoscaler" == "1" ]]    && payload="${payload},\"autoscalerEnabled\":true"
  [[ -n "$autoscaler_min" ]]    && payload="${payload},\"autoscalerMinNodes\":${autoscaler_min}"
  [[ -n "$autoscaler_max" ]]    && payload="${payload},\"autoscalerMaxNodes\":${autoscaler_max}"
  [[ "$no_autoheal" == "1" ]]   && payload="${payload},\"autohealEnabled\":false"

  # Build addons object from --addons list + boolean toggles.
  local addons_json="" addons_first=1
  if [[ -n "$addons" ]]; then
    addons_json="{"
    IFS=',' read -ra ADDR <<< "$addons"
    for a in "${ADDR[@]}"; do
      a=$(echo "$a" | tr -d '[:space:]')
      [[ -z "$a" ]] && continue
      local key
      key=$(_k8s_addon_key "$a")
      [[ $addons_first -eq 0 ]] && addons_json="${addons_json},"
      addons_json="${addons_json}\"${key}\":true"
      addons_first=0
    done
  fi
  if [[ "$default_deny_netpol" == "1" ]]; then
    [[ -z "$addons_json" ]] && addons_json="{"
    [[ $addons_first -eq 0 ]] && addons_json="${addons_json},"
    addons_json="${addons_json}\"defaultDenyNetpol\":true"
    addons_first=0
  fi
  if [[ -n "$addons_json" ]]; then
    addons_json="${addons_json}}"
    payload="${payload},\"addons\":${addons_json}"
  fi
  payload="${payload}}"

  _info "Creating Kubernetes cluster ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/kubernetes/clusters" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Cluster created."
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  Version: $(echo "$data" | _json_get '.version')"
}

k8s_update() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  shift || true

  local backup_bucket backup_retention allowed_cidrs
  local autoscaler_on autoscaler_off autoscaler_min autoscaler_max
  local autoheal_on autoheal_off
  backup_bucket=$(_parse_flag "--backup-bucket" "$@")
  backup_retention=$(_parse_flag "--backup-retention" "$@")
  allowed_cidrs=$(_parse_flag "--allowed-cidrs" "$@")
  autoscaler_on=$(_has_bool_flag "--autoscaler" "$@")
  autoscaler_off=$(_has_bool_flag "--no-autoscaler" "$@")
  autoscaler_min=$(_parse_flag "--autoscaler-min" "$@")
  autoscaler_max=$(_parse_flag "--autoscaler-max" "$@")
  autoheal_on=$(_has_bool_flag "--autoheal" "$@")
  autoheal_off=$(_has_bool_flag "--no-autoheal" "$@")

  if [[ "$autoscaler_on" == "1" && "$autoscaler_off" == "1" ]]; then
    _fatal "Cannot pass both --autoscaler and --no-autoscaler."
  fi
  if [[ "$autoheal_on" == "1" && "$autoheal_off" == "1" ]]; then
    _fatal "Cannot pass both --autoheal and --no-autoheal."
  fi
  if [[ -n "$autoscaler_min" ]] && ! [[ "$autoscaler_min" =~ ^[0-9]+$ ]]; then
    _fatal "--autoscaler-min must be a non-negative integer."
  fi
  if [[ -n "$autoscaler_max" ]] && ! [[ "$autoscaler_max" =~ ^[0-9]+$ ]]; then
    _fatal "--autoscaler-max must be a non-negative integer."
  fi

  if [[ -n "$backup_retention" ]]; then
    if ! [[ "$backup_retention" =~ ^[0-9]+$ ]] || [[ "$backup_retention" -lt 1 ]] || [[ "$backup_retention" -gt 90 ]]; then
      _fatal "--backup-retention must be an integer between 1 and 90."
    fi
  fi

  # Collect repeated --addon=NAME=BOOL flags.
  local addons_json="" addons_first=1
  for arg in "$@"; do
    if [[ "$arg" == --addon=* ]]; then
      local kv="${arg#--addon=}"
      local aname="${kv%%=*}" aval="${kv#*=}"
      if [[ "$aname" == "$kv" || -z "$aname" ]]; then
        _fatal "Invalid --addon syntax: ${arg} (expected --addon=NAME=true|false)"
      fi
      case "${aval,,}" in
        true|1|yes|on)   aval="true" ;;
        false|0|no|off)  aval="false" ;;
        *) _fatal "Invalid boolean for --addon=${aname}: ${aval}" ;;
      esac
      local key
      key=$(_k8s_addon_key "$aname")
      [[ -z "$addons_json" ]] && addons_json="{"
      [[ $addons_first -eq 0 ]] && addons_json="${addons_json},"
      addons_json="${addons_json}\"${key}\":${aval}"
      addons_first=0
    fi
  done
  [[ -n "$addons_json" ]] && addons_json="${addons_json}}"

  if [[ -z "$backup_bucket" && -z "$backup_retention" && -z "$allowed_cidrs" && -z "$addons_json" \
        && "$autoscaler_on" != "1" && "$autoscaler_off" != "1" \
        && -z "$autoscaler_min" && -z "$autoscaler_max" \
        && "$autoheal_on" != "1" && "$autoheal_off" != "1" ]]; then
    _fatal "At least one flag required: --backup-bucket, --backup-retention, --allowed-cidrs, --addon=NAME=BOOL, --autoscaler/--no-autoscaler, --autoscaler-min, --autoscaler-max, or --autoheal/--no-autoheal"
  fi

  local payload="{" first=1
  if [[ -n "$backup_bucket" ]]; then
    payload="${payload}\"backupBucketId\":\"${backup_bucket}\""; first=0
  fi
  if [[ -n "$backup_retention" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"backupRetention\":${backup_retention}"; first=0
  fi
  if [[ -n "$allowed_cidrs" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"allowedSourceCidrs\":$(_csv_to_json_array "$allowed_cidrs")"; first=0
  fi
  if [[ -n "$addons_json" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"addons\":${addons_json}"; first=0
  fi
  if [[ "$autoscaler_on" == "1" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autoscalerEnabled\":true"; first=0
  elif [[ "$autoscaler_off" == "1" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autoscalerEnabled\":false"; first=0
  fi
  if [[ -n "$autoscaler_min" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autoscalerMinNodes\":${autoscaler_min}"; first=0
  fi
  if [[ -n "$autoscaler_max" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autoscalerMaxNodes\":${autoscaler_max}"; first=0
  fi
  if [[ "$autoheal_on" == "1" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autohealEnabled\":true"; first=0
  elif [[ "$autoheal_off" == "1" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"autohealEnabled\":false"; first=0
  fi
  payload="${payload}}"

  _info "Updating cluster ${BOLD}${id}${NC} ..."
  _api_patch "/kubernetes/clusters/${id}" "$payload" >/dev/null
  _success "Cluster ${id} updated."
}

k8s_oidc() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  local body
  body=$(_api_get "/oidc/cluster/${id}/.well-known/openid-configuration") || true
  if [[ -z "$body" ]]; then
    _err "Cluster ${id} has no OIDC keys (IRSA not enabled or still provisioning)."
    return 1
  fi
  echo -e "${BOLD}OIDC issuer info — cluster ${id}${NC}"
  echo ""
  echo "  Issuer:    $(echo "$body" | _json_get '.issuer')"
  echo "  JWKS URL:  $(echo "$body" | _json_get '.jwks_uri')"
  echo "  Audience:  sts.kubmix.cloud   (use this in your projected SA token)"
  echo ""
  echo "Pod manifest snippet:"
  cat <<'EOF'
  serviceAccountName: <your-sa>
  volumes:
  - name: aws-iam-token
    projected:
      sources:
      - serviceAccountToken: { audience: sts.kubmix.cloud, expirationSeconds: 3600, path: token }
EOF
}

k8s_autoscaler() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  local body data
  body=$(_api_get "/kubernetes/clusters/${id}/autoscaler/status")
  data=$(_extract_data "$body")

  local enabled min_nodes max_nodes current autoscaled last_scale state
  enabled=$(echo      "$data" | _json_get '.enabled')
  min_nodes=$(echo    "$data" | _json_get '.minNodes')
  max_nodes=$(echo    "$data" | _json_get '.maxNodes')
  current=$(echo      "$data" | _json_get '.currentNodes')
  autoscaled=$(echo   "$data" | _json_get '.autoscaledNodes')
  last_scale=$(echo   "$data" | _json_get '.autoscalerLastScaleAt')
  [[ -z "$last_scale" || "$last_scale" == "null" ]] && last_scale="—"

  if [[ "${enabled,,}" == "true" ]]; then
    state="ENABLED"
  else
    state="DISABLED"
  fi

  echo -e "${BOLD}Autoscaler:${NC} ${state} (${min_nodes:-?}-${max_nodes:-?} nodes)"
  echo "Current nodes:    ${current:-?}"
  echo "Autoscaled nodes: ${autoscaled:-0}"
  echo "Last scale:       ${last_scale}"
  echo ""
  echo -e "${BOLD}Recent events:${NC}"

  local events count i
  if _has_jq; then
    events=$(echo "$data" | jq -c '.recentEvents // []' 2>/dev/null || echo "[]")
    count=$(echo "$events" | jq 'length' 2>/dev/null || echo 0)
  else
    events=$(echo "$data" | _json_get '.recentEvents')
    [[ -z "$events" || "$events" == "null" ]] && events="[]"
    count=$(echo "$events" | _json_array_len)
  fi
  count="${count:-0}"

  if [[ "$count" -eq 0 ]]; then
    echo "  (no scale events recorded)"
    return
  fi

  i=0
  while [[ $i -lt $count ]]; do
    local kind delta reason at arrow label
    kind=$(echo   "$events" | _json_get ".[${i}].kind")
    delta=$(echo  "$events" | _json_get ".[${i}].delta")
    reason=$(echo "$events" | _json_get ".[${i}].reason")
    at=$(echo     "$events" | _json_get ".[${i}].at")
    case "${kind,,}" in
      scale-up|up|scaleup)     arrow="↑"; label="scale-up  " ;;
      scale-down|down|scaledown) arrow="↓"; label="scale-down" ;;
      *)                       arrow="•"; label="${kind:-event}" ;;
    esac
    [[ -n "$reason" && "$reason" != "null" ]] || reason="-"
    [[ -n "$at" && "$at" != "null" ]] || at="-"
    local delta_str
    if [[ "$delta" =~ ^-?[0-9]+$ ]]; then
      delta_str=$(printf "%+d nodes" "$delta")
    else
      delta_str="?  nodes"
    fi
    printf "  %s %-10s  %-9s  %-30s  %s\n" "$arrow" "$label" "$delta_str" "$reason" "$at"
    i=$((i+1))
  done
}

k8s_autoheal() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  local body data enabled events count i
  body=$(_api_get "/kubernetes/clusters/${id}/autoheal/events")
  data=$(_extract_data "$body")

  enabled=$(echo "$data" | _json_get '.enabled')
  if [[ "${enabled,,}" == "true" ]]; then
    echo -e "${BOLD}Auto-heal:${NC} ENABLED"
  else
    echo -e "${BOLD}Auto-heal:${NC} DISABLED"
  fi
  echo ""
  echo -e "${BOLD}Recent replacements:${NC}"

  if _has_jq; then
    events=$(echo "$data" | jq -c '.events // []' 2>/dev/null || echo "[]")
    count=$(echo "$events" | jq 'length' 2>/dev/null || echo 0)
  else
    events=$(echo "$data" | _json_get '.events')
    [[ -z "$events" || "$events" == "null" ]] && events="[]"
    count=$(echo "$events" | _json_array_len)
  fi
  count="${count:-0}"

  if [[ "$count" -eq 0 ]]; then
    echo "  (no replacements yet — healthy cluster)"
    return
  fi

  i=0
  while [[ $i -lt $count ]]; do
    local dead_vmid new_vmid reason dead_name at
    dead_vmid=$(echo "$events" | _json_get ".[${i}].details.deadVmid")
    new_vmid=$(echo  "$events" | _json_get ".[${i}].details.newVmid")
    dead_name=$(echo "$events" | _json_get ".[${i}].details.deadNodeName")
    reason=$(echo    "$events" | _json_get ".[${i}].details.reason")
    at=$(echo        "$events" | _json_get ".[${i}].createdAt")
    [[ -z "$reason" || "$reason" == "null" ]] && reason="-"
    [[ -z "$dead_name" || "$dead_name" == "null" ]] && dead_name="?"
    printf "  ♥ VM %-6s replaced VM %-6s  %-22s  %s  (%s)\n" \
      "${new_vmid:-?}" "${dead_vmid:-?}" "$reason" "$at" "$dead_name"
    i=$((i+1))
  done
}

k8s_namespace_costs() {
  _require_auth

  # First positional arg is either the cluster ID or --all.
  local id=""
  local all_clusters=0
  if [[ $# -gt 0 && "$1" != --* ]]; then
    id="$1"; shift
  fi

  local from="" to="" group_by="" label_key="" export_csv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)         all_clusters=1; shift ;;
      --from)        from="${2:-}"; shift 2 ;;
      --to)          to="${2:-}"; shift 2 ;;
      --group-by)    group_by="${2:-}"; shift 2 ;;
      --label-key)   label_key="${2:-}"; shift 2 ;;
      --export-csv)  export_csv="${2:-}"; shift 2 ;;
      *)             _warn "Unknown flag: $1"; shift ;;
    esac
  done

  if [[ -z "$id" && $all_clusters -eq 0 ]]; then
    _fatal "Pass a CLUSTER_ID or --all. See 'devskin k8s' for usage."
  fi
  if [[ "$group_by" == "label" && -z "$label_key" ]]; then
    _fatal "--label-key is required when --group-by=label"
  fi

  # Build query string
  local qs=""
  _append_qs() {
    local k="$1" v="$2"
    [[ -z "$v" ]] && return
    # Minimal URL-encode of common chars; relies on jq if present, else passes through.
    if [[ -z "$qs" ]]; then qs="?${k}=${v}"; else qs="${qs}&${k}=${v}"; fi
  }
  _append_qs "from" "$from"
  _append_qs "to" "$to"
  _append_qs "groupBy" "$group_by"
  _append_qs "labelKey" "$label_key"

  local path
  if [[ $all_clusters -eq 1 ]]; then
    path="/kubernetes/namespace-costs${qs}"
  else
    path="/kubernetes/clusters/${id}/namespace-costs${qs}"
  fi

  local body data
  body=$(_api_get "$path")
  data=$(_extract_data "$body")

  # Header summary
  local cluster_name total nscount pfrom pto
  if [[ $all_clusters -eq 1 ]]; then
    cluster_name="(all clusters)"
  else
    cluster_name=$(_api_get "/kubernetes/clusters/${id}" | _extract_data | _json_get '.name' 2>/dev/null)
    [[ -z "$cluster_name" || "$cluster_name" == "null" ]] && cluster_name="$id"
  fi
  total=$(echo "$data" | _json_get '.summary.totalUsd')
  nscount=$(echo "$data" | _json_get '.summary.namespaceCount')
  pfrom=$(echo "$data" | _json_get '.summary.periodFrom')
  pto=$(echo "$data" | _json_get '.summary.periodTo')
  [[ -z "$total"   || "$total"   == "null" ]] && total="0"
  [[ -z "$nscount" || "$nscount" == "null" ]] && nscount="0"
  [[ -z "$pfrom"   || "$pfrom"   == "null" ]] && pfrom="-"
  [[ -z "$pto"     || "$pto"     == "null" ]] && pto="-"

  echo -e "${BOLD}Cluster:${NC} ${cluster_name} · ${BOLD}Period:${NC} ${pfrom} → ${pto}"
  printf "${BOLD}Total:${NC} US\$ %.2f  ${BOLD}Namespaces:${NC} %s\n" "$total" "$nscount"
  echo ""

  # Sorted rows (cost desc) — let the API order stand if jq is absent.
  local rows count i
  if _has_jq; then
    rows=$(echo "$data" | jq -c '(.rows // []) | sort_by(-(.costUsd // 0))' 2>/dev/null || echo "[]")
    count=$(echo "$rows" | jq 'length' 2>/dev/null || echo 0)
  else
    rows=$(echo "$data" | _json_get '.rows')
    [[ -z "$rows" || "$rows" == "null" ]] && rows="[]"
    count=$(echo "$rows" | _json_array_len)
  fi
  count="${count:-0}"

  if [[ "$count" -eq 0 ]]; then
    echo "  (no namespace cost data for this period)"
    return
  fi

  printf "  %-22s  %8s  %10s  %5s  %12s  %5s\n" \
    "NAMESPACE" "CPU·h" "RAM GB·h" "Pods" "Cost (USD)" "%"
  printf "  %s\n" "------------------------------------------------------------------------------"

  i=0
  while [[ $i -lt $count ]]; do
    local key cpu ram pods cost pct
    key=$(echo  "$rows" | _json_get ".[${i}].key")
    cpu=$(echo  "$rows" | _json_get ".[${i}].cpuHours")
    ram=$(echo  "$rows" | _json_get ".[${i}].ramGbHours")
    pods=$(echo "$rows" | _json_get ".[${i}].podCount")
    cost=$(echo "$rows" | _json_get ".[${i}].costUsd")
    pct=$(echo  "$rows" | _json_get ".[${i}].percentage")
    [[ -z "$key"  || "$key"  == "null" ]] && key="-"
    [[ -z "$cpu"  || "$cpu"  == "null" ]] && cpu="0"
    [[ -z "$ram"  || "$ram"  == "null" ]] && ram="0"
    [[ -z "$pods" || "$pods" == "null" ]] && pods="0"
    [[ -z "$cost" || "$cost" == "null" ]] && cost="0"
    [[ -z "$pct"  || "$pct"  == "null" ]] && pct="0"
    printf "  %-22s  %8.1f  %10.1f  %5s  \$ %9.2f  %4.0f%%\n" \
      "$key" "$cpu" "$ram" "$pods" "$cost" "$pct"
    i=$((i+1))
  done

  # CSV export
  if [[ -n "$export_csv" ]]; then
    {
      echo "key,costUsd,cpuHours,ramGbHours,storageGbMonths,podCount,percentage"
      if _has_jq; then
        echo "$rows" | jq -r '.[] | [
          .key, (.costUsd // 0), (.cpuHours // 0), (.ramGbHours // 0),
          (.storageGbMonths // 0), (.podCount // 0), (.percentage // 0)
        ] | @csv'
      else
        local j=0
        while [[ $j -lt $count ]]; do
          local k_ c_ cpu_ ram_ stor_ pods_ pct_
          k_=$(echo    "$rows" | _json_get ".[${j}].key")
          c_=$(echo    "$rows" | _json_get ".[${j}].costUsd")
          cpu_=$(echo  "$rows" | _json_get ".[${j}].cpuHours")
          ram_=$(echo  "$rows" | _json_get ".[${j}].ramGbHours")
          stor_=$(echo "$rows" | _json_get ".[${j}].storageGbMonths")
          pods_=$(echo "$rows" | _json_get ".[${j}].podCount")
          pct_=$(echo  "$rows" | _json_get ".[${j}].percentage")
          printf '"%s",%s,%s,%s,%s,%s,%s\n' \
            "${k_:-}" "${c_:-0}" "${cpu_:-0}" "${ram_:-0}" "${stor_:-0}" "${pods_:-0}" "${pct_:-0}"
          j=$((j+1))
        done
      fi
    } > "$export_csv"
    _info "Wrote $count rows to ${BOLD}${export_csv}${NC}"
  fi
}

k8s_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  local body
  body=$(_api_get "/kubernetes/clusters/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Cluster Details${NC}"
  echo ""
  echo "  ID:           $(echo "$data" | _json_get '.id')"
  echo "  Name:         $(echo "$data" | _json_get '.name')"
  echo "  Version:      $(echo "$data" | _json_get '.version')"
  echo "  Status:       $(echo "$data" | _json_get '.status')"
  echo "  Nodes:        $(echo "$data" | _json_get '.nodeCount')"
  echo "  Pods Running: $(echo "$data" | _json_get '.podsRunning')"
  echo "  Services:     $(echo "$data" | _json_get '.servicesCount')"
  echo "  Region:       $(echo "$data" | _json_get '.region')"
  echo "  Created:      $(echo "$data" | _json_get '.createdAt')"
}

k8s_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  read -rp "Are you sure you want to delete cluster ${id}? This cannot be undone. [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting cluster ${BOLD}${id}${NC} ..."
  _api_delete "/kubernetes/clusters/${id}" >/dev/null
  _success "Cluster ${id} deleted."
}

# ── Backups ─────────────────────────────────────────────────────────────────
_human_bytes() {
  local b="${1:-0}"
  if ! [[ "$b" =~ ^[0-9]+$ ]]; then echo "-"; return; fi
  if   [[ $b -lt 1024 ]];          then echo "${b}B"
  elif [[ $b -lt 1048576 ]];       then awk -v n="$b" 'BEGIN{printf "%.1fKB", n/1024}'
  elif [[ $b -lt 1073741824 ]];    then awk -v n="$b" 'BEGIN{printf "%.1fMB", n/1048576}'
  elif [[ $b -lt 1099511627776 ]]; then awk -v n="$b" 'BEGIN{printf "%.2fGB", n/1073741824}'
  else                                  awk -v n="$b" 'BEGIN{printf "%.2fTB", n/1099511627776}'
  fi
}

k8s_backups_list() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  local body data
  body=$(_api_get "/kubernetes/clusters/${id}/backups")
  data=$(_extract_data "$body")

  echo -e "${BOLD}Backups for cluster ${id}${NC}"
  echo ""

  if [[ -z "$data" || "$data" == "null" || "$data" == "[]" ]]; then
    echo "  (no backups)"
    return
  fi

  # Print a hand-rolled table so we can format sizeBytes as human-readable.
  printf "  %-26s  %-32s  %-10s  %-10s  %-25s  %-25s\n" \
    "ID" "FILENAME" "STATUS" "SIZE" "STARTED" "COMPLETED"
  printf "  %s\n" "------------------------------------------------------------------------------------------------------------------------"

  local count i bid bfile bstatus bsize bstart bend
  if _has_jq; then
    count=$(echo "$data" | jq 'length' 2>/dev/null || echo 0)
  else
    count=$(echo "$data" | _json_array_len)
  fi
  count="${count:-0}"
  i=0
  while [[ $i -lt $count ]]; do
    bid=$(echo     "$data" | _json_get ".[${i}].id")
    bfile=$(echo   "$data" | _json_get ".[${i}].filename")
    bstatus=$(echo "$data" | _json_get ".[${i}].status")
    bsize=$(echo   "$data" | _json_get ".[${i}].sizeBytes")
    bstart=$(echo  "$data" | _json_get ".[${i}].startedAt")
    bend=$(echo    "$data" | _json_get ".[${i}].completedAt")
    [[ -z "$bsize" || "$bsize" == "null" ]] && bsize="-" || bsize=$(_human_bytes "$bsize")
    [[ -z "$bend"  || "$bend"  == "null" ]] && bend="-"
    printf "  %-26s  %-32s  %-10s  %-10s  %-25s  %-25s\n" \
      "${bid:--}" "${bfile:--}" "${bstatus:--}" "$bsize" "${bstart:--}" "$bend"
    i=$((i+1))
  done
}

k8s_backup_create() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  _info "Triggering manual backup for cluster ${BOLD}${id}${NC} ..."
  local body data
  body=$(_api_post "/kubernetes/clusters/${id}/backups" "{}")
  data=$(_extract_data "$body")

  local bid bstatus
  bid=$(echo "$data" | _json_get '.id')
  bstatus=$(echo "$data" | _json_get '.status')
  _success "Backup queued."
  echo ""
  echo "  Backup ID: ${bid:--}"
  echo "  Status:    ${bstatus:--}"
  echo ""
  echo "  Run 'devskin k8s backups ${id}' to track progress."
}

k8s_backup_download() {
  _require_auth
  local id="${1:-}"
  local backup_id="${2:-}"
  _require_arg "CLUSTER_ID" "$id"
  _require_arg "BACKUP_ID"  "$backup_id"
  shift 2 2>/dev/null || true

  local save_path
  save_path=$(_parse_flag "--save" "$@")

  local body data url expires
  body=$(_api_get "/kubernetes/clusters/${id}/backups/${backup_id}/download")
  data=$(_extract_data "$body")
  url=$(echo "$data" | _json_get '.url')
  expires=$(echo "$data" | _json_get '.expiresIn')

  if [[ -z "$url" || "$url" == "null" ]]; then
    _fatal "API did not return a download URL."
  fi

  if [[ -n "$save_path" ]]; then
    _info "Downloading backup ${backup_id} → ${save_path} ..."
    if curl -fL -o "$save_path" "$url"; then
      _success "Saved to ${save_path}"
    else
      _fatal "Download failed."
    fi
  else
    echo -e "${BOLD}Presigned URL${NC} (expires in ${expires:-?}s):"
    echo ""
    echo "$url"
  fi
}

k8s_backup_delete() {
  _require_auth
  local id="${1:-}"
  local backup_id="${2:-}"
  _require_arg "CLUSTER_ID" "$id"
  _require_arg "BACKUP_ID"  "$backup_id"

  read -rp "Delete backup ${backup_id} of cluster ${id}? This cannot be undone. [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting backup ${BOLD}${backup_id}${NC} ..."
  _api_delete "/kubernetes/clusters/${id}/backups/${backup_id}" >/dev/null
  _success "Backup ${backup_id} deleted."
}

# ── Optimization (KubeTurbo-equivalent recommendations) ─────────────────────

k8s_optimize() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       k8s_optimize_list "$@" ;;
    show|get)   k8s_optimize_show "$@" ;;
    apply)      k8s_optimize_apply "$@" ;;
    dismiss)    k8s_optimize_dismiss "$@" ;;
    savings)    k8s_optimize_savings "$@" ;;
    scan)       k8s_optimize_scan "$@" ;;
    help|*)     k8s_optimize_help ;;
  esac
}

k8s_optimize_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin k8s optimize <subcommand> [options]

${BOLD}Subcommands:${NC}
  list [--cluster ID] [--status NEW|APPLIED|DISMISSED|EXPIRED]
       [--type rightsizing|binpack] [--sort savings|confidence|newest]
                                    List recommendations
  show ID                           Show full detail (incl. metrics snapshot)
  apply ID                          Apply — MODIFIES the cluster (asks confirmation)
  dismiss ID                        Mark recommendation as DISMISSED
  savings [--cluster ID]            Aggregated savings + top-10
  scan                              Admin: trigger a fresh analyzer pass
EOF
}

# Format a USD number as US$ X.XX
_k8s_opt_usd() {
  local v="${1:-0}"
  if ! [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then echo "US\$ -"; return; fi
  awk -v n="$v" 'BEGIN{printf "US$ %.2f", n}'
}

# Truncate ID-short
_k8s_opt_short() {
  local v="${1:-}"
  [[ -z "$v" || "$v" == "null" ]] && { echo "-"; return; }
  if [[ ${#v} -gt 8 ]]; then echo "${v:0:8}"; else echo "$v"; fi
}

# Compute a relative age string from an ISO timestamp
_k8s_opt_age() {
  local ts="${1:-}"
  [[ -z "$ts" || "$ts" == "null" || "$ts" == "-" ]] && { echo "-"; return; }
  if _has_python; then
    $(_python_bin) -c "
import sys, datetime
try:
    s = '''$ts'''.replace('Z','+00:00')
    t = datetime.datetime.fromisoformat(s)
    now = datetime.datetime.now(datetime.timezone.utc)
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    d = int((now - t).total_seconds())
    if d < 60: print(f'{d}s')
    elif d < 3600: print(f'{d//60}m')
    elif d < 86400: print(f'{d//3600}h')
    else: print(f'{d//86400}d')
except Exception:
    print('-')
" 2>/dev/null
  else
    echo "$ts"
  fi
}

k8s_optimize_list() {
  _require_auth
  local cluster status type sort
  cluster=$(_parse_flag "--cluster" "$@")
  status=$(_parse_flag  "--status"  "$@")
  type=$(_parse_flag    "--type"    "$@")
  sort=$(_parse_flag    "--sort"    "$@")

  local qs="" first=1
  for kv in \
      "status=${status}" \
      "type=${type}" \
      "clusterId=${cluster}" \
      "sort=${sort}"; do
    local val="${kv#*=}"
    [[ -z "$val" ]] && continue
    if [[ $first -eq 1 ]]; then qs="?"; first=0; else qs="${qs}&"; fi
    qs="${qs}${kv}"
  done

  local body data
  body=$(_api_get "/optimization/recommendations${qs}")
  data=$(_extract_data "$body")

  echo -e "${BOLD}Optimization Recommendations${NC}"
  echo ""

  if [[ -z "$data" || "$data" == "null" || "$data" == "[]" ]]; then
    echo "  (no recommendations)"
    return
  fi

  printf "  %-10s  %-12s  %-9s  %-32s  %-13s  %-11s  %s\n" \
    "ID" "TYPE" "SEVERITY" "RESOURCE" "SAVINGS/MO" "CONFIDENCE" "AGE"
  printf "  %s\n" "------------------------------------------------------------------------------------------------------------------------"

  local count i
  if _has_jq; then
    count=$(echo "$data" | jq 'length' 2>/dev/null || echo 0)
  else
    count=$(echo "$data" | _json_array_len)
  fi
  count="${count:-0}"
  i=0
  while [[ $i -lt $count ]]; do
    local rid rtype rsev rres rsav rconf rcreated rage rsav_str rconf_str
    rid=$(echo      "$data" | _json_get ".[${i}].id")
    rtype=$(echo    "$data" | _json_get ".[${i}].type")
    rsev=$(echo     "$data" | _json_get ".[${i}].severity")
    rres=$(echo     "$data" | _json_get ".[${i}].resource")
    rsav=$(echo     "$data" | _json_get ".[${i}].estimatedMonthlySavingsUsd")
    rconf=$(echo    "$data" | _json_get ".[${i}].confidence")
    rcreated=$(echo "$data" | _json_get ".[${i}].createdAt")

    [[ -z "$rres" || "$rres" == "null" ]] && rres="-"
    [[ -z "$rsev" || "$rsev" == "null" ]] && rsev="-"
    [[ -z "$rtype" || "$rtype" == "null" ]] && rtype="-"
    rsav_str=$(_k8s_opt_usd "${rsav:-0}")
    if [[ "$rconf" =~ ^[0-9.]+$ ]]; then
      rconf_str=$(awk -v c="$rconf" 'BEGIN{printf "%.0f%%", (c<=1?c*100:c)}')
    else
      rconf_str="-"
    fi
    rage=$(_k8s_opt_age "$rcreated")
    if [[ ${#rres} -gt 32 ]]; then rres="${rres:0:29}..."; fi

    printf "  %-10s  %-12s  %-9s  %-32s  %-13s  %-11s  %s\n" \
      "$(_k8s_opt_short "$rid")" "${rtype}" "${rsev}" "${rres}" "${rsav_str}" "${rconf_str}" "${rage}"
    i=$((i+1))
  done
}

k8s_optimize_show() {
  _require_auth
  local id="${1:-}"
  _require_arg "RECOMMENDATION_ID" "$id"

  local body data
  body=$(_api_get "/optimization/recommendations/${id}")
  data=$(_extract_data "$body")

  echo -e "${BOLD}Recommendation Detail${NC}"
  echo ""
  echo "  ID:            $(echo "$data" | _json_get '.id')"
  echo "  Type:          $(echo "$data" | _json_get '.type')"
  echo "  Severity:      $(echo "$data" | _json_get '.severity')"
  echo "  Status:        $(echo "$data" | _json_get '.status')"
  echo "  Cluster:       $(echo "$data" | _json_get '.clusterId')"
  echo "  Resource:      $(echo "$data" | _json_get '.resource')"
  echo "  Namespace:     $(echo "$data" | _json_get '.namespace')"
  local sav conf
  sav=$(echo "$data" | _json_get '.estimatedMonthlySavingsUsd')
  conf=$(echo "$data" | _json_get '.confidence')
  echo "  Savings/mo:    $(_k8s_opt_usd "${sav:-0}")"
  echo "  Confidence:    ${conf:--}"
  echo "  Created:       $(echo "$data" | _json_get '.createdAt')"
  echo "  Rationale:     $(echo "$data" | _json_get '.rationale')"
  echo ""
  echo -e "${BOLD}Metrics Snapshot${NC}"
  if _has_jq; then
    echo "$data" | jq '.metricsJson // {}'
  else
    echo "$data" | _json_get '.metricsJson'
  fi
}

k8s_optimize_apply() {
  _require_auth
  local id="${1:-}"
  _require_arg "RECOMMENDATION_ID" "$id"

  _warn "WARNING: applying a recommendation MODIFIES the live cluster."
  _warn "  rightsizing → patches the Deployment's resource requests/limits (rolling restart)."
  _warn "  binpack     → cordons + drains the target node."
  read -rp "Apply recommendation ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Applying recommendation ${BOLD}${id}${NC} ..."
  local body data status
  body=$(_api_post "/optimization/recommendations/${id}/apply" "{}")
  data=$(_extract_data "$body")
  status=$(echo "$data" | _json_get '.status')
  _success "Recommendation ${id} applied (status=${status:--})."
}

k8s_optimize_dismiss() {
  _require_auth
  local id="${1:-}"
  _require_arg "RECOMMENDATION_ID" "$id"

  _info "Dismissing recommendation ${BOLD}${id}${NC} ..."
  _api_post "/optimization/recommendations/${id}/dismiss" "{}" >/dev/null
  _success "Recommendation ${id} dismissed."
}

k8s_optimize_savings() {
  _require_auth
  local cluster
  cluster=$(_parse_flag "--cluster" "$@")

  local qs=""
  [[ -n "$cluster" ]] && qs="?clusterId=${cluster}"

  local body data
  body=$(_api_get "/optimization/savings${qs}")
  data=$(_extract_data "$body")

  if [[ -z "$data" || "$data" == "null" ]]; then
    echo "  (no savings data)"
    return
  fi

  local cname potential applied applied_count rec_count
  cname=$(echo "$data" | _json_get '.clusterName')
  [[ -z "$cname" || "$cname" == "null" ]] && cname="${cluster:-(all clusters)}"
  potential=$(echo "$data"     | _json_get '.potentialMonthlyUsd')
  applied=$(echo "$data"       | _json_get '.appliedMonthlyUsd')
  applied_count=$(echo "$data" | _json_get '.appliedActionCount')
  rec_count=$(echo "$data"     | _json_get '.recommendationCount')

  echo ""
  echo "Cluster: ${cname}"
  echo "Potential savings: $(_k8s_opt_usd "${potential:-0}")/mo"

  # byType breakdown
  local rs_amount rs_count bp_amount bp_count
  if _has_jq; then
    rs_amount=$(echo "$data" | jq -r '.byType.rightsizing.amount // 0' 2>/dev/null)
    rs_count=$(echo  "$data" | jq -r '.byType.rightsizing.count // 0'  2>/dev/null)
    bp_amount=$(echo "$data" | jq -r '.byType.binpack.amount // 0'     2>/dev/null)
    bp_count=$(echo  "$data" | jq -r '.byType.binpack.count // 0'      2>/dev/null)
  else
    rs_amount=$(echo "$data" | _json_get '.byType.rightsizing.amount')
    rs_count=$(echo  "$data" | _json_get '.byType.rightsizing.count')
    bp_amount=$(echo "$data" | _json_get '.byType.binpack.amount')
    bp_count=$(echo  "$data" | _json_get '.byType.binpack.count')
  fi
  rs_amount="${rs_amount:-0}"; rs_count="${rs_count:-0}"
  bp_amount="${bp_amount:-0}"; bp_count="${bp_count:-0}"
  echo "  ├─ rightsizing: $(_k8s_opt_usd "$rs_amount") (${rs_count} recommendations)"
  echo "  └─ bin-packing: $(_k8s_opt_usd "$bp_amount") (${bp_count} recommendations)"
  echo "Applied last month: $(_k8s_opt_usd "${applied:-0}") (${applied_count:-0} actions)"
  echo "Total recommendations: ${rec_count:-0}"
  echo ""

  echo -e "${BOLD}Top 10 by savings:${NC}"
  local top10 count i
  if _has_jq; then
    top10=$(echo "$data" | jq -c '.top10 // []' 2>/dev/null)
    count=$(echo "$top10" | jq 'length' 2>/dev/null || echo 0)
  else
    top10=$(echo "$data" | _json_get '.top10')
    [[ -z "$top10" || "$top10" == "null" ]] && top10="[]"
    count=$(echo "$top10" | _json_array_len)
  fi
  count="${count:-0}"

  if [[ "$count" -eq 0 ]]; then
    echo "  (none)"
    return
  fi

  i=0
  while [[ $i -lt $count ]]; do
    local tres ttype tsav rank
    tres=$(echo  "$top10" | _json_get ".[${i}].resource")
    ttype=$(echo "$top10" | _json_get ".[${i}].type")
    tsav=$(echo  "$top10" | _json_get ".[${i}].estimatedMonthlySavingsUsd")
    [[ -z "$tres" || "$tres" == "null" ]] && tres="-"
    [[ -z "$ttype" || "$ttype" == "null" ]] && ttype="-"
    rank=$((i+1))
    printf "  %2d. %-30s -%s  %s\n" "$rank" "$tres" "$(_k8s_opt_usd "${tsav:-0}")/mo" "$ttype"
    i=$((i+1))
  done
}

k8s_optimize_scan() {
  _require_auth
  _info "Triggering a fresh optimization analyzer pass ..."
  local body data status
  body=$(_api_post "/optimization/scan" "{}")
  data=$(_extract_data "$body")
  status=$(echo "$data" | _json_get '.status')
  _success "Scan triggered (status=${status:-queued}). Run 'devskin k8s optimize list' shortly to see new recommendations."
}

# ════════════════════════════════════════════════════════════════════════════
#                       K8S DEPLOYMENT COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_k8s_deploy() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       k8s_deploy_list "$@" ;;
    create)     k8s_deploy_create "$@" ;;
    update)     k8s_deploy_update "$@" ;;
    delete)     k8s_deploy_delete "$@" ;;
    help|*)     k8s_deploy_help ;;
  esac
}

k8s_deploy_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin k8s-deploy <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all Kubernetes deployments
  create --name NAME --source-repo REPO --replicas N --port PORT
                                    Create a new deployment
  update NAME --replicas N [--image IMAGE]
                                    Update an existing deployment
  delete NAME                       Delete a deployment
EOF
}

k8s_deploy_list() {
  _require_auth
  local body
  body=$(_api_get "/kubernetes/deployments")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Kubernetes Deployments${NC}"
  echo ""
  echo "$data" | _format_table id name replicas port status sourceRepo
}

k8s_deploy_create() {
  _require_auth
  local name source_repo replicas port
  name=$(_parse_flag "--name" "$@")
  source_repo=$(_parse_flag "--source-repo" "$@")
  replicas=$(_parse_flag "--replicas" "$@")
  port=$(_parse_flag "--port" "$@")

  _require_arg "--name" "$name"
  _require_arg "--source-repo" "$source_repo"
  _require_arg "--replicas" "$replicas"
  _require_arg "--port" "$port"

  local payload="{\"name\":\"${name}\",\"sourceRepo\":\"${source_repo}\",\"replicas\":${replicas},\"port\":${port}}"

  _info "Creating Kubernetes deployment ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/kubernetes/deployments" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Deployment created."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Replicas: $(echo "$data" | _json_get '.replicas')"
  echo "  Port:     $(echo "$data" | _json_get '.port')"
}

k8s_deploy_update() {
  _require_auth
  local name="${1:-}"; shift 2>/dev/null || true
  _require_arg "NAME" "$name"

  local replicas image
  replicas=$(_parse_flag "--replicas" "$@")
  image=$(_parse_flag "--image" "$@")

  _require_arg "--replicas" "$replicas"

  local payload="{\"replicas\":${replicas}"
  [[ -n "$image" ]] && payload="${payload},\"image\":\"${image}\""
  payload="${payload}}"

  _info "Updating deployment ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_patch "/kubernetes/deployments/${name}" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Deployment updated."
  echo ""
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Replicas: $(echo "$data" | _json_get '.replicas')"
  [[ -n "$image" ]] && echo "  Image:    $(echo "$data" | _json_get '.image')"
}

k8s_deploy_delete() {
  _require_auth
  local name="${1:-}"
  _require_arg "NAME" "$name"

  read -rp "Are you sure you want to delete deployment ${name}? This cannot be undone. [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting deployment ${BOLD}${name}${NC} ..."
  _api_delete "/kubernetes/deployments/${name}" >/dev/null
  _success "Deployment ${name} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       MONITORING COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_alarm() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       alarm_list "$@" ;;
    create)     alarm_create "$@" ;;
    get|show)   alarm_get "$@" ;;
    toggle)     alarm_toggle "$@" ;;
    delete)     alarm_delete "$@" ;;
    help|*)     alarm_help ;;
  esac
}

alarm_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin alarm <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all alarms
  create --name NAME --metric METRIC --threshold VALUE [--comparison OP] [--period SEC]
                                    Create a new alarm
  get ID                            Show alarm details
  toggle ID                         Enable or disable an alarm
  delete ID                         Delete an alarm
EOF
}

alarm_list() {
  _require_auth
  local body
  body=$(_api_get "/monitoring/alarms")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Alarms${NC}"
  echo ""
  echo "$data" | _format_table id name metric state enabled
}

alarm_create() {
  _require_auth
  local name metric threshold comparison period
  name=$(_parse_flag "--name" "$@")
  metric=$(_parse_flag "--metric" "$@")
  threshold=$(_parse_flag "--threshold" "$@")
  comparison=$(_parse_flag "--comparison" "$@")
  period=$(_parse_flag "--period" "$@")

  _require_arg "--name" "$name"
  _require_arg "--metric" "$metric"
  _require_arg "--threshold" "$threshold"

  local payload="{\"name\":\"${name}\",\"metric\":\"${metric}\",\"threshold\":${threshold}"
  [[ -n "$comparison" ]] && payload="${payload},\"comparison\":\"${comparison}\""
  [[ -n "$period" ]]     && payload="${payload},\"period\":${period}"
  payload="${payload}}"

  _info "Creating alarm ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/monitoring/alarms" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Alarm created."
  echo ""
  echo "  ID:        $(echo "$data" | _json_get '.id')"
  echo "  Name:      $(echo "$data" | _json_get '.name')"
  echo "  Metric:    $(echo "$data" | _json_get '.metric')"
  echo "  Threshold: $(echo "$data" | _json_get '.threshold')"
}

alarm_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "ALARM_ID" "$id"

  local body
  body=$(_api_get "/monitoring/alarms/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Alarm Details${NC}"
  echo ""
  echo "  ID:         $(echo "$data" | _json_get '.id')"
  echo "  Name:       $(echo "$data" | _json_get '.name')"
  echo "  Metric:     $(echo "$data" | _json_get '.metric')"
  echo "  Threshold:  $(echo "$data" | _json_get '.threshold')"
  echo "  Comparison: $(echo "$data" | _json_get '.comparison')"
  echo "  Period:     $(echo "$data" | _json_get '.period')"
  echo "  State:      $(echo "$data" | _json_get '.state')"
  echo "  Enabled:    $(echo "$data" | _json_get '.enabled')"
}

alarm_toggle() {
  _require_auth
  local id="${1:-}"
  _require_arg "ALARM_ID" "$id"

  _info "Toggling alarm ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_patch "/monitoring/alarms/${id}")
  _success "Alarm ${id} toggled."
}

alarm_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "ALARM_ID" "$id"

  _info "Deleting alarm ${BOLD}${id}${NC} ..."
  _api_delete "/monitoring/alarms/${id}" >/dev/null
  _success "Alarm ${id} deleted."
}

# ── Logs ────────────────────────────────────────────────────────────────────

cmd_log() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       log_list "$@" ;;
    create)     log_create "$@" ;;
    delete)     log_delete "$@" ;;
    export)     log_export "$@" ;;
    help|*)     log_help ;;
  esac
}

log_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin log <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all log groups
  create --name NAME [--retention DAYS]
                                    Create a new log group
  delete ID                         Delete a log group
  export ID [--from FROM] [--to TO] Export logs
EOF
}

log_list() {
  _require_auth
  local body
  body=$(_api_get "/monitoring/logs")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Log Groups${NC}"
  echo ""
  echo "$data" | _format_table id name retentionDays storedBytes status
}

log_create() {
  _require_auth
  local name retention
  name=$(_parse_flag "--name" "$@")
  retention=$(_parse_flag "--retention" "$@")

  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$retention" ]] && payload="${payload},\"retentionDays\":${retention}"
  payload="${payload}}"

  _info "Creating log group ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/monitoring/logs" "$payload")
  _success "Log group created."
}

log_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "LOG_GROUP_ID" "$id"

  _info "Deleting log group ${BOLD}${id}${NC} ..."
  _api_delete "/monitoring/logs/${id}" >/dev/null
  _success "Log group ${id} deleted."
}

log_export() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "LOG_GROUP_ID" "$id"

  local from to
  from=$(_parse_flag "--from" "$@")
  to=$(_parse_flag "--to" "$@")

  local payload="{}"
  if [[ -n "$from" || -n "$to" ]]; then
    payload="{"
    [[ -n "$from" ]] && payload="${payload}\"from\":\"${from}\""
    [[ -n "$from" && -n "$to" ]] && payload="${payload},"
    [[ -n "$to" ]]   && payload="${payload}\"to\":\"${to}\""
    payload="${payload}}"
  fi

  _info "Exporting logs from log group ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/monitoring/logs/${id}/export" "$payload")
  local data
  data=$(_extract_data "$body")

  echo "$data" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       SECURITY COMMANDS
# ════════════════════════════════════════════════════════════════════════════

# ── Certificates ────────────────────────────────────────────────────────────

cmd_cert() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       cert_list "$@" ;;
    request)    cert_request "$@" ;;
    get|show)   cert_get "$@" ;;
    renew)      cert_renew "$@" ;;
    delete)     cert_delete "$@" ;;
    help|*)     cert_help ;;
  esac
}

cert_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin cert <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all certificates
  request --domain DOMAIN [--sans "d1,d2"]
                                    Request a new certificate
  get ID                            Show certificate details
  renew ID                          Renew a certificate
  delete ID                         Delete a certificate
EOF
}

cert_list() {
  _require_auth
  local body
  body=$(_api_get "/security/certificates")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Certificates${NC}"
  echo ""
  echo "$data" | _format_table id domainName status type expiresAt
}

cert_request() {
  _require_auth
  local domain sans
  domain=$(_parse_flag "--domain" "$@")
  sans=$(_parse_flag "--sans" "$@")

  _require_arg "--domain" "$domain"

  local payload="{\"domainName\":\"${domain}\""
  if [[ -n "$sans" ]]; then
    # Convert comma-separated to JSON array
    local sans_json
    sans_json=$(echo "$sans" | tr ',' '\n' | while read -r s; do echo "\"$(echo "$s" | xargs)\""; done | paste -sd, -)
    payload="${payload},\"subjectAlternativeNames\":[${sans_json}]"
  fi
  payload="${payload}}"

  _info "Requesting certificate for ${BOLD}${domain}${NC} ..."
  local body
  body=$(_api_post "/security/certificates" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Certificate requested."
  echo ""
  echo "  ID:     $(echo "$data" | _json_get '.id')"
  echo "  Domain: $(echo "$data" | _json_get '.domainName')"
  echo "  Status: $(echo "$data" | _json_get '.status')"
}

cert_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "CERTIFICATE_ID" "$id"

  local body
  body=$(_api_get "/security/certificates/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Certificate Details${NC}"
  echo ""
  echo "  ID:         $(echo "$data" | _json_get '.id')"
  echo "  Domain:     $(echo "$data" | _json_get '.domainName')"
  echo "  Status:     $(echo "$data" | _json_get '.status')"
  echo "  Type:       $(echo "$data" | _json_get '.type')"
  echo "  Expires At: $(echo "$data" | _json_get '.expiresAt')"
  echo "  Created:    $(echo "$data" | _json_get '.createdAt')"
}

cert_renew() {
  _require_auth
  local id="${1:-}"
  _require_arg "CERTIFICATE_ID" "$id"

  _info "Renewing certificate ${BOLD}${id}${NC} ..."
  _api_post "/security/certificates/${id}/renew" >/dev/null
  _success "Certificate ${id} renewal initiated."
}

cert_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "CERTIFICATE_ID" "$id"

  _info "Deleting certificate ${BOLD}${id}${NC} ..."
  _api_delete "/security/certificates/${id}" >/dev/null
  _success "Certificate ${id} deleted."
}

# ── Key Pairs ───────────────────────────────────────────────────────────────

cmd_keypair() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       keypair_list "$@" ;;
    create)     keypair_create "$@" ;;
    delete)     keypair_delete "$@" ;;
    help|*)     keypair_help ;;
  esac
}

keypair_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin keypair <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all key pairs
  create --name NAME                Create a new key pair
  delete ID                         Delete a key pair
EOF
}

keypair_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/key-pairs")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Key Pairs${NC}"
  echo ""
  echo "$data" | _format_table id name fingerprint createdAt
}

keypair_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating key pair ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/compute/key-pairs" "{\"name\":\"${name}\"}")
  local data
  data=$(_extract_data "$body")

  _success "Key pair created."
  echo ""
  echo "  ID:          $(echo "$data" | _json_get '.id')"
  echo "  Name:        $(echo "$data" | _json_get '.name')"
  echo "  Fingerprint: $(echo "$data" | _json_get '.fingerprint')"

  # Save private key if returned
  local private_key
  private_key=$(echo "$data" | _json_get '.privateKey' 2>/dev/null || echo "")
  if [[ -n "$private_key" && "$private_key" != "null" && "$private_key" != "None" ]]; then
    local key_path="$HOME/.ssh/${name}.pem"
    mkdir -p "$HOME/.ssh"
    echo "$private_key" > "$key_path"
    chmod 600 "$key_path"
    _success "Private key saved to ${key_path}"
  fi
}

keypair_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "KEYPAIR_ID" "$id"

  read -rp "Are you sure you want to delete key pair ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting key pair ${BOLD}${id}${NC} ..."
  _api_delete "/compute/key-pairs/${id}" >/dev/null
  _success "Key pair ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                        DNS ZONE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_zone() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       zone_list "$@" ;;
    create)     zone_create "$@" ;;
    get|show)   zone_get "$@" ;;
    delete)     zone_delete "$@" ;;
    records)    zone_records "$@" ;;
    help|*)     zone_help ;;
  esac
}

zone_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin zone <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all admin zones (infrastructure)
  create --slug SLUG --name NAME [--type TYPE]
                                    Create a new admin zone
  get ID                            Show zone details
  delete ID                         Delete a zone
EOF
}

zone_list() {
  _require_auth
  local body
  body=$(_api_get "/admin/zones")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Zones${NC}"
  echo ""
  echo "$data" | _format_table id slug name type status
}

zone_create() {
  _require_auth
  local slug name type
  slug=$(_parse_flag "--slug" "$@")
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")

  _require_arg "--slug" "$slug"
  _require_arg "--name" "$name"

  local payload="{\"slug\":\"${slug}\",\"name\":\"${name}\""
  [[ -n "$type" ]] && payload="${payload},\"type\":\"${type}\""
  payload="${payload}}"

  _info "Creating zone ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/admin/zones" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Zone created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Slug: $(echo "$data" | _json_get '.slug')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

zone_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "ZONE_ID" "$id"

  local body
  body=$(_api_get "/admin/zones/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Zone Details${NC}"
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Slug:    $(echo "$data" | _json_get '.slug')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  Type:    $(echo "$data" | _json_get '.type')"
  echo "  Status:  $(echo "$data" | _json_get '.status')"
  echo "  Created: $(echo "$data" | _json_get '.createdAt')"
}

zone_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "ZONE_ID" "$id"

  read -rp "Are you sure you want to delete zone ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting zone ${BOLD}${id}${NC} ..."
  _api_delete "/admin/zones/${id}" >/dev/null
  _success "Zone ${id} deleted."
}

zone_records() {
  _require_auth
  local id="${1:-}"
  _require_arg "ZONE_ID" "$id"

  local body
  body=$(_api_get "/admin/zones/${id}/config")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Zone Configuration${NC}"
  echo ""
  echo "$data" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                        DNS HOSTED ZONES
# ════════════════════════════════════════════════════════════════════════════

cmd_dns() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       dns_list "$@" ;;
    create)     dns_create "$@" ;;
    get|show)   dns_get "$@" ;;
    delete)     dns_delete "$@" ;;
    records)    dns_records "$@" ;;
    add-record)   dns_add_record "$@" ;;
    del-record)   dns_del_record "$@" ;;
    help|*)     dns_help ;;
  esac
}

dns_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin dns <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all hosted zones
  create --name NAME                Create a new hosted zone
  get ID                            Show hosted zone details
  delete ID                         Delete a hosted zone
  records ZONE_ID                   List records in a zone
  add-record ZONE_ID --name NAME --type TYPE --value VALUE [--ttl TTL]
                                    Add a record to a zone
  del-record ZONE_ID RECORD_ID      Delete a record from a zone
EOF
}

dns_list() {
  _require_auth
  local body
  body=$(_api_get "/dns/zones")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Hosted Zones${NC}"
  echo ""
  echo "$data" | _format_table id name recordCount status
}

dns_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating hosted zone ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/dns/zones" "{\"name\":\"${name}\"}")
  local data
  data=$(_extract_data "$body")

  _success "Hosted zone created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

dns_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "ZONE_ID" "$id"

  local body
  body=$(_api_get "/dns/zones/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Hosted Zone Details${NC}"
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Name:    $(echo "$data" | _json_get '.name')"
  echo "  Records: $(echo "$data" | _json_get '.recordCount')"
  echo "  Status:  $(echo "$data" | _json_get '.status')"
  echo "  Created: $(echo "$data" | _json_get '.createdAt')"
}

dns_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "ZONE_ID" "$id"

  read -rp "Are you sure you want to delete hosted zone ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting hosted zone ${BOLD}${id}${NC} ..."
  _api_delete "/dns/zones/${id}" >/dev/null
  _success "Hosted zone ${id} deleted."
}

dns_records() {
  _require_auth
  local zone_id="${1:-}"
  _require_arg "ZONE_ID" "$zone_id"

  local body
  body=$(_api_get "/dns/zones/${zone_id}/records")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}DNS Records (Zone: ${zone_id})${NC}"
  echo ""
  echo "$data" | _format_table id name type value ttl
}

dns_add_record() {
  _require_auth
  local zone_id="${1:-}"; shift 2>/dev/null || true
  _require_arg "ZONE_ID" "$zone_id"

  local name type value ttl
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  value=$(_parse_flag "--value" "$@")
  ttl=$(_parse_flag "--ttl" "$@")

  _require_arg "--name" "$name"
  _require_arg "--type" "$type"
  _require_arg "--value" "$value"

  local payload="{\"name\":\"${name}\",\"type\":\"${type}\",\"value\":\"${value}\""
  [[ -n "$ttl" ]] && payload="${payload},\"ttl\":${ttl}"
  payload="${payload}}"

  _info "Adding ${type} record ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/dns/zones/${zone_id}/records" "$payload")
  _success "Record added."
}

dns_del_record() {
  _require_auth
  local zone_id="${1:-}"
  local record_id="${2:-}"
  _require_arg "ZONE_ID" "$zone_id"
  _require_arg "RECORD_ID" "$record_id"

  _info "Deleting record ${BOLD}${record_id}${NC} from zone ${BOLD}${zone_id}${NC} ..."
  _api_delete "/dns/zones/${zone_id}/records/${record_id}" >/dev/null
  _success "Record deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                     SECURITY GROUPS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_sg() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       sg_list "$@" ;;
    create)     sg_create "$@" ;;
    get|show)   sg_get "$@" ;;
    delete)     sg_delete "$@" ;;
    help|*)     sg_help ;;
  esac
}

sg_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin sg <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all security groups
  create --name NAME --vpc VPC_ID [--description DESC]
                                    Create a new security group
  get ID                            Show security group details
  delete ID                         Delete a security group
EOF
}

sg_list() {
  _require_auth
  local body
  body=$(_api_get "/networking/security-groups")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Security Groups${NC}"
  echo ""
  echo "$data" | _format_table id name vpcId rulesCount
}

sg_create() {
  _require_auth
  local name vpc description
  name=$(_parse_flag "--name" "$@")
  vpc=$(_parse_flag "--vpc" "$@")
  description=$(_parse_flag "--description" "$@")

  _require_arg "--name" "$name"
  _require_arg "--vpc" "$vpc"

  local payload="{\"name\":\"${name}\",\"vpcId\":\"${vpc}\""
  [[ -n "$description" ]] && payload="${payload},\"description\":\"${description}\""
  payload="${payload}}"

  _info "Creating security group ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/networking/security-groups" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Security group created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

sg_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECURITY_GROUP_ID" "$id"

  local body
  body=$(_api_get "/networking/security-groups/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Security Group Details${NC}"
  echo ""
  echo "  ID:          $(echo "$data" | _json_get '.id')"
  echo "  Name:        $(echo "$data" | _json_get '.name')"
  echo "  Description: $(echo "$data" | _json_get '.description')"
  echo "  VPC:         $(echo "$data" | _json_get '.vpcId')"
  echo "  Created:     $(echo "$data" | _json_get '.createdAt')"
}

sg_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECURITY_GROUP_ID" "$id"

  _info "Deleting security group ${BOLD}${id}${NC} ..."
  _api_delete "/networking/security-groups/${id}" >/dev/null
  _success "Security group ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                      LOAD BALANCER COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_lb() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       lb_list "$@" ;;
    create)     lb_create "$@" ;;
    get|show)   lb_get "$@" ;;
    delete)     lb_delete "$@" ;;
    help|*)     lb_help ;;
  esac
}

lb_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin lb <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all load balancers
  create --name NAME --type TYPE [--vpc VPC_ID]
                                    Create a new load balancer
  get ID                            Show load balancer details
  delete ID                         Delete a load balancer
EOF
}

lb_list() {
  _require_auth
  local body
  body=$(_api_get "/networking/load-balancers")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Load Balancers${NC}"
  echo ""
  echo "$data" | _format_table id name type status dnsName
}

lb_create() {
  _require_auth
  local name type vpc
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  vpc=$(_parse_flag "--vpc" "$@")

  _require_arg "--name" "$name"
  _require_arg "--type" "$type"

  local payload="{\"name\":\"${name}\",\"type\":\"${type}\""
  [[ -n "$vpc" ]] && payload="${payload},\"vpcId\":\"${vpc}\""
  payload="${payload}}"

  _info "Creating load balancer ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/networking/load-balancers" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Load balancer created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

lb_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "LOAD_BALANCER_ID" "$id"

  local body
  body=$(_api_get "/networking/load-balancers/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Load Balancer Details${NC}"
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Type:     $(echo "$data" | _json_get '.type')"
  echo "  Status:   $(echo "$data" | _json_get '.status')"
  echo "  DNS Name: $(echo "$data" | _json_get '.dnsName')"
  echo "  VPC:      $(echo "$data" | _json_get '.vpcId')"
  echo "  Created:  $(echo "$data" | _json_get '.createdAt')"
}

lb_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "LOAD_BALANCER_ID" "$id"

  read -rp "Are you sure you want to delete load balancer ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting load balancer ${BOLD}${id}${NC} ..."
  _api_delete "/networking/load-balancers/${id}" >/dev/null
  _success "Load balancer ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                         CDN COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_cdn() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)         cdn_list "$@" ;;
    create)       cdn_create "$@" ;;
    get|show)     cdn_get "$@" ;;
    delete)       cdn_delete "$@" ;;
    invalidate)   cdn_invalidate "$@" ;;
    toggle)       cdn_toggle "$@" ;;
    help|*)       cdn_help ;;
  esac
}

cdn_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin cdn <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all CDN distributions
  create --origin ORIGIN [--name NAME]
                                    Create a new distribution
  get ID                            Show distribution details
  delete ID                         Delete a distribution
  invalidate ID --paths "/path1,/path2"
                                    Invalidate cached paths
  toggle ID                         Enable/disable a distribution
EOF
}

cdn_list() {
  _require_auth
  local body
  body=$(_api_get "/cdn/distributions")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}CDN Distributions${NC}"
  echo ""
  echo "$data" | _format_table id domainName status enabled origin
}

cdn_create() {
  _require_auth
  local origin name
  origin=$(_parse_flag "--origin" "$@")
  name=$(_parse_flag "--name" "$@")

  _require_arg "--origin" "$origin"

  local payload="{\"origin\":\"${origin}\""
  [[ -n "$name" ]] && payload="${payload},\"name\":\"${name}\""
  payload="${payload}}"

  _info "Creating CDN distribution ..."
  local body
  body=$(_api_post "/cdn/distributions" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Distribution created."
  echo ""
  echo "  ID:     $(echo "$data" | _json_get '.id')"
  echo "  Domain: $(echo "$data" | _json_get '.domainName')"
}

cdn_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "DISTRIBUTION_ID" "$id"

  local body
  body=$(_api_get "/cdn/distributions/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Distribution Details${NC}"
  echo ""
  echo "  ID:      $(echo "$data" | _json_get '.id')"
  echo "  Domain:  $(echo "$data" | _json_get '.domainName')"
  echo "  Status:  $(echo "$data" | _json_get '.status')"
  echo "  Enabled: $(echo "$data" | _json_get '.enabled')"
  echo "  Origin:  $(echo "$data" | _json_get '.origin')"
  echo "  Created: $(echo "$data" | _json_get '.createdAt')"
}

cdn_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "DISTRIBUTION_ID" "$id"

  read -rp "Are you sure you want to delete distribution ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting distribution ${BOLD}${id}${NC} ..."
  _api_delete "/cdn/distributions/${id}" >/dev/null
  _success "Distribution ${id} deleted."
}

cdn_invalidate() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "DISTRIBUTION_ID" "$id"

  local paths
  paths=$(_parse_flag "--paths" "$@")
  _require_arg "--paths" "$paths"

  # Convert comma-separated paths to JSON array
  local paths_json
  paths_json=$(echo "$paths" | tr ',' '\n' | while read -r p; do echo "\"$(echo "$p" | xargs)\""; done | paste -sd, -)

  _info "Invalidating cache for distribution ${BOLD}${id}${NC} ..."
  _api_post "/cdn/distributions/${id}/invalidate" "{\"paths\":[${paths_json}]}" >/dev/null
  _success "Cache invalidation initiated."
}

cdn_toggle() {
  _require_auth
  local id="${1:-}"
  _require_arg "DISTRIBUTION_ID" "$id"

  _info "Toggling distribution ${BOLD}${id}${NC} ..."
  _api_patch "/cdn/distributions/${id}/toggle" >/dev/null
  _success "Distribution ${id} toggled."
}

# ════════════════════════════════════════════════════════════════════════════
#                         IAM COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_iam() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    users)      iam_users "$@" ;;
    groups)     iam_groups "$@" ;;
    roles)      iam_roles "$@" ;;
    policies)   iam_policies "$@" ;;
    help|*)     iam_help ;;
  esac
}

iam_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin iam <subcommand> [options]

${BOLD}Subcommands:${NC}
  users list                        List IAM users
  users create --name NAME --email EMAIL
                                    Create an IAM user
  users delete ID                   Delete an IAM user
  groups list                       List IAM groups
  groups create --name NAME         Create an IAM group
  groups delete ID                  Delete an IAM group
  roles list                        List IAM roles
  roles create --name NAME [--description TEXT] [--policies LIST]
                [--trust-cluster CLUSTER --trust-namespace NS --trust-sa SA]
                                    Create an IAM role. --policies is a comma-list
                                    (e.g. "s3:GetObject,s3:ListBucket"). The trust
                                    flags enable IRSA from a K8s ServiceAccount.
  roles delete ID                   Delete an IAM role
  policies list                     List IAM policies
  policies create --name NAME       Create an IAM policy
  policies delete ID                Delete an IAM policy
EOF
}

iam_users() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/iam/users")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}IAM Users${NC}"
      echo ""
      echo "$data" | _format_table id username email status
      ;;
    create)
      _require_auth
      local name email
      name=$(_parse_flag "--name" "$@")
      email=$(_parse_flag "--email" "$@")
      _require_arg "--name" "$name"
      _require_arg "--email" "$email"
      _info "Creating IAM user ${BOLD}${name}${NC} ..."
      local body
      body=$(_api_post "/iam/users" "{\"username\":\"${name}\",\"email\":\"${email}\"}")
      _success "IAM user created."
      ;;
    get)
      _require_auth
      local id="${1:-}"
      _require_arg "USER_ID" "$id"
      local body
      body=$(_api_get "/iam/users/${id}")
      _extract_data "$body" | _json_pretty
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "USER_ID" "$id"
      _api_delete "/iam/users/${id}" >/dev/null
      _success "IAM user ${id} deleted."
      ;;
    *) iam_help ;;
  esac
}

iam_groups() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/iam/groups")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}IAM Groups${NC}"
      echo ""
      echo "$data" | _format_table id name usersCount
      ;;
    create)
      _require_auth
      local name
      name=$(_parse_flag "--name" "$@")
      _require_arg "--name" "$name"
      _info "Creating IAM group ${BOLD}${name}${NC} ..."
      _api_post "/iam/groups" "{\"name\":\"${name}\"}" >/dev/null
      _success "IAM group created."
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "GROUP_ID" "$id"
      _api_delete "/iam/groups/${id}" >/dev/null
      _success "IAM group ${id} deleted."
      ;;
    *) iam_help ;;
  esac
}

iam_roles() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/iam/roles")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}IAM Roles${NC}"
      echo ""
      echo "$data" | _format_table id name
      ;;
    create)
      _require_auth
      local name desc policies trust_cluster trust_ns trust_sa
      name=$(_parse_flag "--name" "$@")
      desc=$(_parse_flag "--description" "$@")
      policies=$(_parse_flag "--policies" "$@")
      trust_cluster=$(_parse_flag "--trust-cluster" "$@")
      trust_ns=$(_parse_flag "--trust-namespace" "$@")
      trust_sa=$(_parse_flag "--trust-sa" "$@")
      _require_arg "--name" "$name"

      local payload="{\"name\":\"${name}\""
      [[ -n "$desc" ]] && payload="${payload},\"description\":\"${desc}\""

      # --policies "s3:GetObject,s3:ListBucket"  → JSON array
      if [[ -n "$policies" ]]; then
        local arr="["; local first=1
        IFS=',' read -ra PARR <<< "$policies"
        for p in "${PARR[@]}"; do
          p=$(echo "$p" | tr -d '[:space:]')
          [[ $first -eq 0 ]] && arr="${arr},"
          arr="${arr}\"${p}\""
          first=0
        done
        arr="${arr}]"
        payload="${payload},\"policies\":${arr}"
      fi

      # IRSA trust policy: only when all three flags provided. Use --trust-sa '*' for any SA.
      if [[ -n "$trust_cluster" && -n "$trust_ns" && -n "$trust_sa" ]]; then
        payload="${payload},\"trustPolicy\":{\"kubernetes\":[{\"clusterId\":\"${trust_cluster}\",\"namespace\":\"${trust_ns}\",\"serviceAccountName\":\"${trust_sa}\"}]}"
      fi
      payload="${payload}}"

      _info "Creating IAM role ${BOLD}${name}${NC} ..."
      _api_post "/iam/roles" "$payload" >/dev/null
      _success "IAM role created."
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "ROLE_ID" "$id"
      _api_delete "/iam/roles/${id}" >/dev/null
      _success "IAM role ${id} deleted."
      ;;
    *) iam_help ;;
  esac
}

iam_policies() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/iam/policies")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}IAM Policies${NC}"
      echo ""
      echo "$data" | _format_table id name
      ;;
    create)
      _require_auth
      local name
      name=$(_parse_flag "--name" "$@")
      _require_arg "--name" "$name"
      _info "Creating IAM policy ${BOLD}${name}${NC} ..."
      _api_post "/iam/policies" "{\"name\":\"${name}\"}" >/dev/null
      _success "IAM policy created."
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "POLICY_ID" "$id"
      _api_delete "/iam/policies/${id}" >/dev/null
      _success "IAM policy ${id} deleted."
      ;;
    *) iam_help ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════
#                       SNAPSHOT COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_snapshot() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       snapshot_list "$@" ;;
    create)     snapshot_create "$@" ;;
    delete)     snapshot_delete "$@" ;;
    help|*)     snapshot_help ;;
  esac
}

snapshot_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin snapshot <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all compute snapshots
  create --volume VOLUME_ID --name NAME
                                    Create a snapshot from a volume
  delete ID                         Delete a snapshot
EOF
}

snapshot_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/snapshots")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Snapshots${NC}"
  echo ""
  echo "$data" | _format_table id name status volumeId sizeGb createdAt
}

snapshot_create() {
  _require_auth
  local volume name
  volume=$(_parse_flag "--volume" "$@")
  name=$(_parse_flag "--name" "$@")

  _require_arg "--volume" "$volume"
  _require_arg "--name" "$name"

  _info "Creating snapshot ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/compute/snapshots" "{\"volumeId\":\"${volume}\",\"name\":\"${name}\"}")
  _success "Snapshot created."
}

snapshot_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SNAPSHOT_ID" "$id"

  _info "Deleting snapshot ${BOLD}${id}${NC} ..."
  _api_delete "/compute/snapshots/${id}" >/dev/null
  _success "Snapshot ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       IMAGE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_image() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       image_list "$@" ;;
    get|show)   image_get "$@" ;;
    help|*)     image_help ;;
  esac
}

image_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin image <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all available images
  get ID                            Show image details
EOF
}

image_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/images")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Images${NC}"
  echo ""
  echo "$data" | _format_table id name platform architecture status
}

image_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "IMAGE_ID" "$id"

  local body
  body=$(_api_get "/compute/images/${id}")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       SUBNET COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_subnet() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       subnet_list "$@" ;;
    create)     subnet_create "$@" ;;
    delete)     subnet_delete "$@" ;;
    help|*)     subnet_help ;;
  esac
}

subnet_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin subnet <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all subnets
  create --name NAME --vpc VPC_ID --cidr CIDR
                                    Create a new subnet
  delete ID                         Delete a subnet
EOF
}

subnet_list() {
  _require_auth
  local body
  body=$(_api_get "/networking/subnets")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Subnets${NC}"
  echo ""
  echo "$data" | _format_table id name vpcId cidrBlock availabilityZone
}

subnet_create() {
  _require_auth
  local name vpc cidr
  name=$(_parse_flag "--name" "$@")
  vpc=$(_parse_flag "--vpc" "$@")
  cidr=$(_parse_flag "--cidr" "$@")

  _require_arg "--name" "$name"
  _require_arg "--vpc" "$vpc"
  _require_arg "--cidr" "$cidr"

  _info "Creating subnet ${BOLD}${name}${NC} ..."
  _api_post "/networking/subnets" "{\"name\":\"${name}\",\"vpcId\":\"${vpc}\",\"cidrBlock\":\"${cidr}\"}" >/dev/null
  _success "Subnet created."
}

subnet_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SUBNET_ID" "$id"

  _api_delete "/networking/subnets/${id}" >/dev/null
  _success "Subnet ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                      API KEYS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_apikey() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       apikey_list "$@" ;;
    create)     apikey_create "$@" ;;
    delete)     apikey_delete "$@" ;;
    regenerate) apikey_regenerate "$@" ;;
    help|*)     apikey_help ;;
  esac
}

apikey_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin apikey <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all API keys
  create --name NAME                Create a new API key
  delete ID                         Delete an API key
  regenerate ID                     Regenerate an API key
EOF
}

apikey_list() {
  _require_auth
  local body
  body=$(_api_get "/settings/api-keys")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}API Keys${NC}"
  echo ""
  echo "$data" | _format_table id name prefix lastUsed createdAt
}

apikey_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating API key ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/settings/api-keys" "{\"name\":\"${name}\"}")
  local data
  data=$(_extract_data "$body")

  _success "API key created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
  echo "  Key:  $(echo "$data" | _json_get '.key')"
  echo ""
  _warn "Save this key now. It will not be shown again."
}

apikey_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "API_KEY_ID" "$id"

  _api_delete "/settings/api-keys/${id}" >/dev/null
  _success "API key ${id} deleted."
}

apikey_regenerate() {
  _require_auth
  local id="${1:-}"
  _require_arg "API_KEY_ID" "$id"

  _info "Regenerating API key ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/settings/api-keys/${id}/regenerate")
  local data
  data=$(_extract_data "$body")

  _success "API key regenerated."
  echo ""
  echo "  New Key: $(echo "$data" | _json_get '.key')"
  echo ""
  _warn "Save this key now. It will not be shown again."
}

# ════════════════════════════════════════════════════════════════════════════
#                       BILLING COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_billing() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    subscription) billing_subscription "$@" ;;
    usage)        billing_usage "$@" ;;
    invoices)     billing_invoices "$@" ;;
    reminders)    billing_reminders "$@" ;;
    help|*)       billing_help ;;
  esac
}

billing_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin billing <subcommand> [options]

${BOLD}Subcommands:${NC}
  subscription                      Show current subscription
  usage                             Show usage summary
  invoices                          List invoices
  reminders                         Show dunning reminder cadence per OPEN invoice
                                    (reminderCount, lastReminderSentAt, days overdue)
EOF
}

billing_reminders() {
  _require_auth
  local body data
  body=$(_api_get "/billing/invoices")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Invoice Reminders (OPEN only)${NC}"
  echo ""
  if _has_jq; then
    echo "$data" | jq -r '
      .[] | select(.status == "OPEN") |
      [.number, .amount, .currency, (.reminderCount // 0),
       (.lastReminderSentAt // "-"),
       (if .dueDate then (((now - (.dueDate|fromdateiso8601))/86400) | floor | tostring + "d") else "-" end)
      ] | @tsv' \
      | column -t -s $'\t' -N "INVOICE,AMOUNT,CURRENCY,REMINDERS,LAST_SENT,OVERDUE"
  else
    echo "$data" | _json_pretty
  fi
}

billing_subscription() {
  _require_auth
  local body
  body=$(_api_get "/billing/subscription")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Subscription${NC}"
  echo ""
  echo "$data" | _json_pretty
}

billing_usage() {
  _require_auth
  local body
  body=$(_api_get "/billing/usage")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Usage${NC}"
  echo ""
  echo "$data" | _json_pretty
}

billing_invoices() {
  _require_auth
  local body
  body=$(_api_get "/billing/invoices")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Invoices${NC}"
  echo ""
  echo "$data" | _format_table id date amount status
}

# ════════════════════════════════════════════════════════════════════════════
#                       CONTAINERS (ECS) COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_container() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       container_list "$@" ;;
    create)     container_create "$@" ;;
    get|show)   container_get "$@" ;;
    delete)     container_delete "$@" ;;
    deploy)     container_deploy "$@" ;;
    restart)    container_restart "$@" ;;
    scale)      container_scale "$@" ;;
    help|*)     container_help ;;
  esac
}

container_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin container <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all container services
  create --name NAME --image IMAGE --cluster-id ID --task-def-id ID --port PORT
         [--cpu CPU] [--memory MEM] [--replicas N] [--env KEY=VALUE ...]
         [--source-repo REPO] [--source-branch BRANCH]
         [--endpoint-mode direct|loadbalancer] [--lb-id ID]
         [--monitoring-api-key KEY]
                                    Create a new container service (set --monitoring-api-key
                                    to enroll the service into Flux observability)
  get ID                            Show container service details
  delete ID                         Delete a container service
  deploy ID                         Deploy/update a container service
  restart ID                        Restart a container service
  scale ID --replicas N             Scale a container service
EOF
}

container_list() {
  _require_auth
  local body
  body=$(_api_get "/containers/services")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Container Services${NC}"
  echo ""
  echo "$data" | _format_table id name status publicIp port runningCount desiredCount image
}

container_create() {
  _require_auth
  local name image cpu memory replicas cluster_id task_def_id port
  local source_repo source_branch endpoint_mode lb_id monitoring_key
  name=$(_parse_flag "--name" "$@")
  image=$(_parse_flag "--image" "$@")
  cpu=$(_parse_flag "--cpu" "$@")
  memory=$(_parse_flag "--memory" "$@")
  replicas=$(_parse_flag "--replicas" "$@")
  cluster_id=$(_parse_flag "--cluster-id" "$@")
  task_def_id=$(_parse_flag "--task-def-id" "$@")
  port=$(_parse_flag "--port" "$@")
  source_repo=$(_parse_flag "--source-repo" "$@")
  source_branch=$(_parse_flag "--source-branch" "$@")
  endpoint_mode=$(_parse_flag "--endpoint-mode" "$@")
  lb_id=$(_parse_flag "--lb-id" "$@")
  monitoring_key=$(_parse_flag "--monitoring-api-key" "$@")

  _require_arg "--name" "$name"
  _require_arg "--cluster-id" "$cluster_id"
  _require_arg "--task-def-id" "$task_def_id"
  _require_arg "--port" "$port"

  [[ -z "$image" ]] && image="auto"

  local payload="{\"name\":\"${name}\",\"image\":\"${image}\",\"clusterId\":\"${cluster_id}\",\"taskDefinitionId\":\"${task_def_id}\",\"port\":${port},\"instanceType\":\"ecs.medium\""
  [[ -n "$cpu" ]]           && payload="${payload},\"cpu\":${cpu}"
  [[ -n "$memory" ]]        && payload="${payload},\"memory\":${memory}"
  [[ -n "$replicas" ]]      && payload="${payload},\"desiredCount\":${replicas}"
  [[ -n "$source_repo" ]]   && payload="${payload},\"sourceRepository\":\"${source_repo}\""
  [[ -n "$source_branch" ]] && payload="${payload},\"sourceBranch\":\"${source_branch}\""
  [[ -n "$endpoint_mode" ]] && payload="${payload},\"endpointMode\":\"${endpoint_mode}\""
  [[ -n "$lb_id" ]]         && payload="${payload},\"loadBalancerId\":\"${lb_id}\""

  # Parse --env flags (multiple allowed)
  local env_json="{"
  local env_count=0
  local prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--env" ]] && [[ "$arg" == *"="* ]]; then
      local key="${arg%%=*}"
      local val="${arg#*=}"
      [[ $env_count -gt 0 ]] && env_json="${env_json},"
      env_json="${env_json}\"${key}\":\"${val}\""
      env_count=$((env_count + 1))
    fi
    prev="$arg"
  done
  env_json="${env_json}}"
  [[ $env_count -gt 0 ]] && payload="${payload},\"environment\":${env_json}"

  if [[ -n "$monitoring_key" ]]; then
    payload="${payload},\"monitoring\":{\"enabled\":true,\"apiKey\":\"${monitoring_key}\"}"
  fi

  payload="${payload}}"

  _info "Creating container service ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/containers/services" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Container service created."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Status:   $(echo "$data" | _json_get '.status')"
  echo "  PublicIP: $(echo "$data" | _json_get '.publicIp')"
}

container_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"

  local body
  body=$(_api_get "/containers/services/${id}")
  _extract_data "$body" | _json_pretty
}

container_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"

  read -rp "Are you sure you want to delete container service ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting container service ${BOLD}${id}${NC} ..."
  _api_delete "/containers/services/${id}" >/dev/null
  _success "Container service ${id} deleted."
}

container_deploy() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"

  _info "Deploying container service ${BOLD}${id}${NC} ..."
  _api_post "/containers/services/${id}/deploy" >/dev/null
  _success "Deployment initiated for service ${id}."
}

container_restart() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"

  _info "Restarting container service ${BOLD}${id}${NC} ..."
  _api_post "/containers/services/${id}/restart" >/dev/null
  _success "Restart initiated for service ${id}."
}

container_scale() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "SERVICE_ID" "$id"

  local replicas
  replicas=$(_parse_flag "--replicas" "$@")
  _require_arg "--replicas" "$replicas"

  _info "Scaling container service ${BOLD}${id}${NC} to ${replicas} replicas ..."
  local body
  body=$(_api_post "/containers/services/${id}/scale" "{\"desiredCount\":${replicas}}")
  local data
  data=$(_extract_data "$body")

  _success "Container service ${id} scaled to ${replicas} replicas."
}

# ════════════════════════════════════════════════════════════════════════════
#                       CONTAINER CLUSTER COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_container_cluster() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       container_cluster_list "$@" ;;
    create)     container_cluster_create "$@" ;;
    get|show)   container_cluster_get "$@" ;;
    delete)     container_cluster_delete "$@" ;;
    help|*)     container_cluster_help ;;
  esac
}

container_cluster_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin container-cluster <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all container clusters
  create --name NAME --vpc-id VPC_ID [--region REGION]
                                    Create a new container cluster
  get ID                            Show container cluster details
  delete ID                         Delete a container cluster
EOF
}

container_cluster_list() {
  _require_auth
  local body
  body=$(_api_get "/containers/clusters")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Container Clusters${NC}"
  echo ""
  echo "$data" | _format_table id name status region
}

container_cluster_create() {
  _require_auth
  local name vpc_id region
  name=$(_parse_flag "--name" "$@")
  vpc_id=$(_parse_flag "--vpc-id" "$@")
  region=$(_parse_flag "--region" "$@")

  _require_arg "--name" "$name"
  _require_arg "--vpc-id" "$vpc_id"

  local payload="{\"name\":\"${name}\",\"vpcId\":\"${vpc_id}\""
  [[ -n "$region" ]] && payload="${payload},\"region\":\"${region}\""
  payload="${payload}}"

  _info "Creating container cluster ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/containers/clusters" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Container cluster created."
  echo ""
  echo "  ID:   $(echo "$data" | _json_get '.id')"
  echo "  Name: $(echo "$data" | _json_get '.name')"
}

container_cluster_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  local body
  body=$(_api_get "/containers/clusters/${id}")
  _extract_data "$body" | _json_pretty
}

container_cluster_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"

  read -rp "Are you sure you want to delete container cluster ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting container cluster ${BOLD}${id}${NC} ..."
  _api_delete "/containers/clusters/${id}" >/dev/null
  _success "Container cluster ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       TASK DEFINITION COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_task_def() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       task_def_list "$@" ;;
    create)     task_def_create "$@" ;;
    get|show)   task_def_get "$@" ;;
    delete)     task_def_delete "$@" ;;
    help|*)     task_def_help ;;
  esac
}

task_def_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin task-def <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all task definitions
  create --family FAMILY --image IMAGE [--cpu CPU] [--memory MEM]
         [--container-port PORT] [--host-port PORT] [--protocol PROTO]
                                    Create a new task definition
  get ID                            Show task definition details
  delete ID                         Delete a task definition
EOF
}

task_def_list() {
  _require_auth
  local body
  body=$(_api_get "/containers/task-definitions")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Task Definitions${NC}"
  echo ""
  echo "$data" | _format_table id family status cpu memory
}

task_def_create() {
  _require_auth
  local family image cpu memory container_port host_port protocol
  family=$(_parse_flag "--family" "$@")
  image=$(_parse_flag "--image" "$@")
  cpu=$(_parse_flag "--cpu" "$@")
  memory=$(_parse_flag "--memory" "$@")
  container_port=$(_parse_flag "--container-port" "$@")
  host_port=$(_parse_flag "--host-port" "$@")
  protocol=$(_parse_flag "--protocol" "$@")

  _require_arg "--family" "$family"
  _require_arg "--image" "$image"

  local payload="{\"family\":\"${family}\",\"image\":\"${image}\""
  [[ -n "$cpu" ]]    && payload="${payload},\"cpu\":${cpu}"
  [[ -n "$memory" ]] && payload="${payload},\"memory\":${memory}"
  if [[ -n "$container_port" ]]; then
    local proto="${protocol:-tcp}"
    local hp="${host_port:-$container_port}"
    payload="${payload},\"portMappings\":[{\"containerPort\":${container_port},\"hostPort\":${hp},\"protocol\":\"${proto}\"}]"
  fi
  payload="${payload}}"

  _info "Creating task definition ${BOLD}${family}${NC} ..."
  local body
  body=$(_api_post "/containers/task-definitions" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Task definition created."
  echo ""
  echo "  ID:     $(echo "$data" | _json_get '.id')"
  echo "  Family: $(echo "$data" | _json_get '.family')"
}

task_def_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "TASK_DEF_ID" "$id"

  local body
  body=$(_api_get "/containers/task-definitions/${id}")
  _extract_data "$body" | _json_pretty
}

task_def_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "TASK_DEF_ID" "$id"

  read -rp "Are you sure you want to delete task definition ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting task definition ${BOLD}${id}${NC} ..."
  _api_delete "/containers/task-definitions/${id}" >/dev/null
  _success "Task definition ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       CI/CD COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_cicd() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    pipelines)    cicd_pipelines "$@" ;;
    trigger)      cicd_trigger "$@" ;;
    logs)         cicd_logs "$@" ;;
    builds)       cicd_builds "$@" ;;
    deployments)  cicd_deployments "$@" ;;
    help|*)       cicd_help ;;
  esac
}

cicd_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin cicd <subcommand> [options]

${BOLD}Subcommands:${NC}
  pipelines list                    List all pipelines
  pipelines create --name NAME --repo REPO
                                    Create a new pipeline
  pipelines get ID                  Show pipeline details
  pipelines delete ID               Delete a pipeline
  trigger ID                        Trigger a pipeline run
  logs ID                           Get pipeline logs
  builds list                       List all builds
  deployments list                  List all deployments
EOF
}

cicd_pipelines() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/cicd/pipelines")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}CI/CD Pipelines${NC}"
      echo ""
      echo "$data" | _format_table id name status lastRun source
      ;;
    create)
      _require_auth
      local name repo
      name=$(_parse_flag "--name" "$@")
      repo=$(_parse_flag "--repo" "$@")
      _require_arg "--name" "$name"
      _require_arg "--repo" "$repo"
      _info "Creating pipeline ${BOLD}${name}${NC} ..."
      local body
      body=$(_api_post "/cicd/pipelines" "{\"name\":\"${name}\",\"repositoryId\":\"${repo}\"}")
      _success "Pipeline created."
      ;;
    get)
      _require_auth
      local id="${1:-}"
      _require_arg "PIPELINE_ID" "$id"
      local body
      body=$(_api_get "/cicd/pipelines/${id}")
      _extract_data "$body" | _json_pretty
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "PIPELINE_ID" "$id"
      _api_delete "/cicd/pipelines/${id}" >/dev/null
      _success "Pipeline ${id} deleted."
      ;;
    *) cicd_help ;;
  esac
}

cicd_trigger() {
  _require_auth
  local id="${1:-}"
  _require_arg "PIPELINE_ID" "$id"

  _info "Triggering pipeline ${BOLD}${id}${NC} ..."
  _api_post "/cicd/pipelines/${id}/trigger" >/dev/null
  _success "Pipeline ${id} triggered."
}

cicd_logs() {
  _require_auth
  local id="${1:-}"
  _require_arg "PIPELINE_ID" "$id"

  local body
  body=$(_api_get "/cicd/pipelines/${id}/logs")
  _extract_data "$body" | _json_pretty
}

cicd_builds() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/cicd/builds")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}CI/CD Builds${NC}"
      echo ""
      echo "$data" | _format_table id projectName status startTime
      ;;
    *) cicd_help ;;
  esac
}

cicd_deployments() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/cicd/deployments")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}CI/CD Deployments${NC}"
      echo ""
      echo "$data" | _format_table id applicationName status deploymentGroupName
      ;;
    *) cicd_help ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════
#                       GIT COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_git() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    repos)      git_repos "$@" ;;
    branches)   git_branches "$@" ;;
    commits)    git_commits "$@" ;;
    credentials) git_credentials "$@" ;;
    help|*)     git_help ;;
  esac
}

git_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin git <subcommand> [options]

${BOLD}Subcommands:${NC}
  repos list                        List all repositories
  repos create --name NAME          Create a new repository
  repos get ID                      Show repository details
  repos delete ID                   Delete a repository
  branches ID                       List branches for a repository
  commits ID                        List commits for a repository
  credentials                       Show Git credentials
EOF
}

git_repos() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/git/repositories")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}Git Repositories${NC}"
      echo ""
      echo "$data" | _format_table id name defaultBranch visibility cloneUrl
      ;;
    create)
      _require_auth
      local name
      name=$(_parse_flag "--name" "$@")
      _require_arg "--name" "$name"
      _info "Creating repository ${BOLD}${name}${NC} ..."
      local body
      body=$(_api_post "/git/repositories" "{\"name\":\"${name}\"}")
      _success "Repository created."
      _extract_data "$body" | _json_pretty
      ;;
    get)
      _require_auth
      local id="${1:-}"
      _require_arg "REPO_ID" "$id"
      local body
      body=$(_api_get "/git/repositories/${id}")
      _extract_data "$body" | _json_pretty
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "REPO_ID" "$id"
      read -rp "Are you sure you want to delete repository ${id}? [y/N] " confirm
      if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
      _api_delete "/git/repositories/${id}" >/dev/null
      _success "Repository ${id} deleted."
      ;;
    *) git_help ;;
  esac
}

git_branches() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"

  local body
  body=$(_api_get "/git/repositories/${id}/branches")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Branches (Repo: ${id})${NC}"
  echo ""
  echo "$data" | _format_table name
}

git_commits() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"

  local body
  body=$(_api_get "/git/repositories/${id}/commits")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Commits (Repo: ${id})${NC}"
  echo ""
  echo "$data" | _format_table sha message author date
}

git_credentials() {
  _require_auth
  local body
  body=$(_api_get "/git/credentials")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       SQS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_sqs() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       sqs_list "$@" ;;
    create)     sqs_create "$@" ;;
    get|show)   sqs_get "$@" ;;
    delete)     sqs_delete "$@" ;;
    send)       sqs_send "$@" ;;
    receive)    sqs_receive "$@" ;;
    purge)      sqs_purge "$@" ;;
    help|*)     sqs_help ;;
  esac
}

sqs_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin sqs <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all SQS queues
  create --name NAME [--type standard|fifo]
                                    Create a new queue
  get ID                            Show queue details
  delete ID                         Delete a queue
  send ID --body MESSAGE            Send a message to a queue
  receive ID                        Receive messages from a queue
  purge ID                          Purge all messages from a queue
EOF
}

sqs_list() {
  _require_auth
  local body
  body=$(_api_get "/sqs/queues")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}SQS Queues${NC}"
  echo ""
  echo "$data" | _format_table id name type messagesAvailable status
}

sqs_create() {
  _require_auth
  local name type
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$type" ]] && payload="${payload},\"type\":\"${type}\""
  payload="${payload}}"

  _info "Creating SQS queue ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/sqs/queues" "$payload")
  _success "Queue created."
  _extract_data "$body" | _json_pretty
}

sqs_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "QUEUE_ID" "$id"
  local body
  body=$(_api_get "/sqs/queues/${id}")
  _extract_data "$body" | _json_pretty
}

sqs_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "QUEUE_ID" "$id"
  _api_delete "/sqs/queues/${id}" >/dev/null
  _success "Queue ${id} deleted."
}

sqs_send() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "QUEUE_ID" "$id"
  local msg
  msg=$(_parse_flag "--body" "$@")
  _require_arg "--body" "$msg"

  _api_post "/sqs/queues/${id}/send" "{\"body\":\"${msg}\"}" >/dev/null
  _success "Message sent to queue ${id}."
}

sqs_receive() {
  _require_auth
  local id="${1:-}"
  _require_arg "QUEUE_ID" "$id"

  local body
  body=$(_api_post "/sqs/queues/${id}/receive" "{}")
  _extract_data "$body" | _json_pretty
}

sqs_purge() {
  _require_auth
  local id="${1:-}"
  _require_arg "QUEUE_ID" "$id"

  _api_post "/sqs/queues/${id}/purge" >/dev/null
  _success "Queue ${id} purged."
}

# ════════════════════════════════════════════════════════════════════════════
#                       SNS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_sns() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       sns_list "$@" ;;
    create)     sns_create "$@" ;;
    get|show)   sns_get "$@" ;;
    delete)     sns_delete "$@" ;;
    publish)    sns_publish "$@" ;;
    help|*)     sns_help ;;
  esac
}

sns_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin sns <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all SNS topics
  create --name NAME                Create a new topic
  get ID                            Show topic details
  delete ID                         Delete a topic
  publish ID --message MESSAGE      Publish a message to a topic
EOF
}

sns_list() {
  _require_auth
  local body
  body=$(_api_get "/sns/topics")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}SNS Topics${NC}"
  echo ""
  echo "$data" | _format_table id name subscriptionCount status
}

sns_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating SNS topic ${BOLD}${name}${NC} ..."
  _api_post "/sns/topics" "{\"name\":\"${name}\"}" >/dev/null
  _success "Topic created."
}

sns_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "TOPIC_ID" "$id"
  local body
  body=$(_api_get "/sns/topics/${id}")
  _extract_data "$body" | _json_pretty
}

sns_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "TOPIC_ID" "$id"
  _api_delete "/sns/topics/${id}" >/dev/null
  _success "Topic ${id} deleted."
}

sns_publish() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "TOPIC_ID" "$id"
  local msg
  msg=$(_parse_flag "--message" "$@")
  _require_arg "--message" "$msg"

  _api_post "/sns/topics/${id}/publish" "{\"message\":\"${msg}\"}" >/dev/null
  _success "Message published to topic ${id}."
}

# ════════════════════════════════════════════════════════════════════════════
#                       EVENTBRIDGE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_eventbridge() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    buses)      eb_buses "$@" ;;
    rules)      eb_rules "$@" ;;
    help|*)     eb_help ;;
  esac
}

eb_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin eventbridge <subcommand> [options]

${BOLD}Subcommands:${NC}
  buses list                        List all event buses
  buses create --name NAME          Create a new event bus
  buses delete ID                   Delete an event bus
  rules list                        List all event rules
  rules create --name NAME --bus BUS_ID --pattern PATTERN
                                    Create a new event rule
  rules delete ID                   Delete an event rule
EOF
}

eb_buses() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/eventbridge/event-buses")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}Event Buses${NC}"
      echo ""
      echo "$data" | _format_table id name rulesCount status
      ;;
    create)
      _require_auth
      local name
      name=$(_parse_flag "--name" "$@")
      _require_arg "--name" "$name"
      _api_post "/eventbridge/event-buses" "{\"name\":\"${name}\"}" >/dev/null
      _success "Event bus created."
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "BUS_ID" "$id"
      _api_delete "/eventbridge/event-buses/${id}" >/dev/null
      _success "Event bus ${id} deleted."
      ;;
    *) eb_help ;;
  esac
}

eb_rules() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list)
      _require_auth
      local body
      body=$(_api_get "/eventbridge/rules")
      local data
      data=$(_extract_data "$body")
      echo -e "${BOLD}Event Rules${NC}"
      echo ""
      echo "$data" | _format_table id name state eventBusId
      ;;
    create)
      _require_auth
      local name bus pattern
      name=$(_parse_flag "--name" "$@")
      bus=$(_parse_flag "--bus" "$@")
      pattern=$(_parse_flag "--pattern" "$@")
      _require_arg "--name" "$name"
      _api_post "/eventbridge/rules" "{\"name\":\"${name}\",\"eventBusId\":\"${bus}\",\"eventPattern\":\"${pattern}\"}" >/dev/null
      _success "Event rule created."
      ;;
    delete)
      _require_auth
      local id="${1:-}"
      _require_arg "RULE_ID" "$id"
      _api_delete "/eventbridge/rules/${id}" >/dev/null
      _success "Event rule ${id} deleted."
      ;;
    *) eb_help ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════
#                       DYNAMODB COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_dynamodb() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       dynamodb_list "$@" ;;
    create)     dynamodb_create "$@" ;;
    get|show)   dynamodb_get "$@" ;;
    delete)     dynamodb_delete "$@" ;;
    items)      dynamodb_items "$@" ;;
    help|*)     dynamodb_help ;;
  esac
}

dynamodb_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin dynamodb <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all DynamoDB tables
  create --name NAME --pk PK_NAME [--pk-type S|N]
                                    Create a new table
  get ID                            Show table details
  delete ID                         Delete a table
  items ID                          List items in a table
EOF
}

dynamodb_list() {
  _require_auth
  local body
  body=$(_api_get "/dynamodb/tables")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}DynamoDB Tables${NC}"
  echo ""
  echo "$data" | _format_table id name status itemCount
}

dynamodb_create() {
  _require_auth
  local name pk pktype
  name=$(_parse_flag "--name" "$@")
  pk=$(_parse_flag "--pk" "$@")
  pktype=$(_parse_flag "--pk-type" "$@")
  _require_arg "--name" "$name"
  _require_arg "--pk" "$pk"

  local payload="{\"name\":\"${name}\",\"partitionKey\":\"${pk}\""
  [[ -n "$pktype" ]] && payload="${payload},\"partitionKeyType\":\"${pktype}\""
  payload="${payload}}"

  _info "Creating DynamoDB table ${BOLD}${name}${NC} ..."
  _api_post "/dynamodb/tables" "$payload" >/dev/null
  _success "Table created."
}

dynamodb_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "TABLE_ID" "$id"
  local body
  body=$(_api_get "/dynamodb/tables/${id}")
  _extract_data "$body" | _json_pretty
}

dynamodb_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "TABLE_ID" "$id"
  read -rp "Are you sure you want to delete table ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
  _api_delete "/dynamodb/tables/${id}" >/dev/null
  _success "Table ${id} deleted."
}

dynamodb_items() {
  _require_auth
  local id="${1:-}"
  _require_arg "TABLE_ID" "$id"
  local body
  body=$(_api_get "/dynamodb/tables/${id}/items")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       MONGODB COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_mongodb() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       mongodb_list "$@" ;;
    create)     mongodb_create "$@" ;;
    get|show)   mongodb_get "$@" ;;
    delete)     mongodb_delete "$@" ;;
    help|*)     mongodb_help ;;
  esac
}

mongodb_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin mongodb <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all MongoDB clusters
  create --name NAME [--tier TIER] [--region REGION]
                                    Create a new cluster
  get ID                            Show cluster details
  delete ID                         Delete a cluster
EOF
}

mongodb_list() {
  _require_auth
  local body
  body=$(_api_get "/mongodb/clusters")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}MongoDB Clusters${NC}"
  echo ""
  echo "$data" | _format_table id name tier status region
}

mongodb_create() {
  _require_auth
  local name tier region
  name=$(_parse_flag "--name" "$@")
  tier=$(_parse_flag "--tier" "$@")
  region=$(_parse_flag "--region" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$tier" ]]   && payload="${payload},\"tier\":\"${tier}\""
  [[ -n "$region" ]] && payload="${payload},\"region\":\"${region}\""
  payload="${payload}}"

  _info "Creating MongoDB cluster ${BOLD}${name}${NC} ..."
  _api_post "/mongodb/clusters" "$payload" >/dev/null
  _success "Cluster created."
}

mongodb_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  local body
  body=$(_api_get "/mongodb/clusters/${id}")
  _extract_data "$body" | _json_pretty
}

mongodb_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  read -rp "Are you sure you want to delete MongoDB cluster ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
  _api_delete "/mongodb/clusters/${id}" >/dev/null
  _success "Cluster ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       REDIS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_redis() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       redis_list "$@" ;;
    create)     redis_create "$@" ;;
    get|show)   redis_get "$@" ;;
    delete)     redis_delete "$@" ;;
    help|*)     redis_help ;;
  esac
}

redis_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin redis <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all Redis clusters
  create --name NAME [--node-type TYPE] [--nodes COUNT]
                                    Create a new cluster
  get ID                            Show cluster details
  delete ID                         Delete a cluster
EOF
}

redis_list() {
  _require_auth
  local body
  body=$(_api_get "/redis/clusters")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Redis Clusters${NC}"
  echo ""
  echo "$data" | _format_table id name nodeType numNodes status
}

redis_create() {
  _require_auth
  local name node_type nodes
  name=$(_parse_flag "--name" "$@")
  node_type=$(_parse_flag "--node-type" "$@")
  nodes=$(_parse_flag "--nodes" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$node_type" ]] && payload="${payload},\"nodeType\":\"${node_type}\""
  [[ -n "$nodes" ]]     && payload="${payload},\"numNodes\":${nodes}"
  payload="${payload}}"

  _info "Creating Redis cluster ${BOLD}${name}${NC} ..."
  _api_post "/redis/clusters" "$payload" >/dev/null
  _success "Cluster created."
}

redis_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  local body
  body=$(_api_get "/redis/clusters/${id}")
  _extract_data "$body" | _json_pretty
}

redis_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "CLUSTER_ID" "$id"
  read -rp "Are you sure you want to delete Redis cluster ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
  _api_delete "/redis/clusters/${id}" >/dev/null
  _success "Cluster ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       EFS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_efs() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       efs_list "$@" ;;
    create)     efs_create "$@" ;;
    get|show)   efs_get "$@" ;;
    delete)     efs_delete "$@" ;;
    help|*)     efs_help ;;
  esac
}

efs_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin efs <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all EFS file systems
  create --name NAME [--performance generalPurpose|maxIO]
                                    Create a new file system
  get ID                            Show file system details
  delete ID                         Delete a file system
EOF
}

efs_list() {
  _require_auth
  local body
  body=$(_api_get "/efs/file-systems")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}EFS File Systems${NC}"
  echo ""
  echo "$data" | _format_table id name performanceMode status sizeInBytes
}

efs_create() {
  _require_auth
  local name perf
  name=$(_parse_flag "--name" "$@")
  perf=$(_parse_flag "--performance" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$perf" ]] && payload="${payload},\"performanceMode\":\"${perf}\""
  payload="${payload}}"

  _info "Creating EFS file system ${BOLD}${name}${NC} ..."
  _api_post "/efs/file-systems" "$payload" >/dev/null
  _success "File system created."
}

efs_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "FILE_SYSTEM_ID" "$id"
  local body
  body=$(_api_get "/efs/file-systems/${id}")
  _extract_data "$body" | _json_pretty
}

efs_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "FILE_SYSTEM_ID" "$id"
  read -rp "Are you sure you want to delete file system ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
  _api_delete "/efs/file-systems/${id}" >/dev/null
  _success "File system ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       GLACIER COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_glacier() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       glacier_list "$@" ;;
    create)     glacier_create "$@" ;;
    get|show)   glacier_get "$@" ;;
    delete)     glacier_delete "$@" ;;
    help|*)     glacier_help ;;
  esac
}

glacier_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin glacier <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all Glacier vaults
  create --name NAME                Create a new vault
  get ID                            Show vault details
  delete ID                         Delete a vault
EOF
}

glacier_list() {
  _require_auth
  local body
  body=$(_api_get "/glacier/vaults")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Glacier Vaults${NC}"
  echo ""
  echo "$data" | _format_table id name archiveCount sizeInBytes status
}

glacier_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _info "Creating Glacier vault ${BOLD}${name}${NC} ..."
  _api_post "/glacier/vaults" "{\"name\":\"${name}\"}" >/dev/null
  _success "Vault created."
}

glacier_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "VAULT_ID" "$id"
  local body
  body=$(_api_get "/glacier/vaults/${id}")
  _extract_data "$body" | _json_pretty
}

glacier_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "VAULT_ID" "$id"
  read -rp "Are you sure you want to delete vault ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; return; fi
  _api_delete "/glacier/vaults/${id}" >/dev/null
  _success "Vault ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       ARTIFACTS COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_artifacts() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       artifacts_list "$@" ;;
    create)     artifacts_create "$@" ;;
    delete)     artifacts_delete "$@" ;;
    packages)   artifacts_packages "$@" ;;
    help|*)     artifacts_help ;;
  esac
}

artifacts_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin artifacts <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all artifact repositories
  create --name NAME --format FORMAT
                                    Create a new repository
  delete ID                         Delete a repository
  packages ID                       List packages in a repository
EOF
}

artifacts_list() {
  _require_auth
  local body
  body=$(_api_get "/artifacts/repositories")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Artifact Repositories${NC}"
  echo ""
  echo "$data" | _format_table id name format packagesCount
}

artifacts_create() {
  _require_auth
  local name format
  name=$(_parse_flag "--name" "$@")
  format=$(_parse_flag "--format" "$@")
  _require_arg "--name" "$name"
  _require_arg "--format" "$format"

  _api_post "/artifacts/repositories" "{\"name\":\"${name}\",\"format\":\"${format}\"}" >/dev/null
  _success "Repository created."
}

artifacts_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"
  _api_delete "/artifacts/repositories/${id}" >/dev/null
  _success "Repository ${id} deleted."
}

artifacts_packages() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"
  local body
  body=$(_api_get "/artifacts/repositories/${id}/packages")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       CONTAINER REGISTRY COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_registry() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       registry_list "$@" ;;
    create)     registry_create "$@" ;;
    get|show)   registry_get "$@" ;;
    delete)     registry_delete "$@" ;;
    images)     registry_images "$@" ;;
    help|*)     registry_help ;;
  esac
}

registry_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin registry <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all container registry repositories
  create --name NAME                Create a new repository
  get ID                            Show repository details
  delete ID                         Delete a repository
  images ID                         List images in a repository
EOF
}

registry_list() {
  _require_auth
  local body
  body=$(_api_get "/container-registry/repositories")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Container Registry Repositories${NC}"
  echo ""
  echo "$data" | _format_table id name imageCount
}

registry_create() {
  _require_auth
  local name
  name=$(_parse_flag "--name" "$@")
  _require_arg "--name" "$name"

  _api_post "/container-registry/repositories" "{\"name\":\"${name}\"}" >/dev/null
  _success "Registry repository created."
}

registry_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"
  local body
  body=$(_api_get "/container-registry/repositories/${id}")
  _extract_data "$body" | _json_pretty
}

registry_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"
  _api_delete "/container-registry/repositories/${id}" >/dev/null
  _success "Repository ${id} deleted."
}

registry_images() {
  _require_auth
  local id="${1:-}"
  _require_arg "REPO_ID" "$id"
  local body
  body=$(_api_get "/container-registry/repositories/${id}/images")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       API GATEWAY COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_apigateway() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       apigw_list "$@" ;;
    create)     apigw_create "$@" ;;
    get|show)   apigw_get "$@" ;;
    delete)     apigw_delete "$@" ;;
    deploy)     apigw_deploy "$@" ;;
    help|*)     apigw_help ;;
  esac
}

apigw_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin api-gateway <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all API gateways
  create --name NAME [--type REST|HTTP]
                                    Create a new API gateway
  get ID                            Show API gateway details
  delete ID                         Delete an API gateway
  deploy ID                         Deploy an API gateway
EOF
}

apigw_list() {
  _require_auth
  local body
  body=$(_api_get "/api-gateway/apis")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}API Gateways${NC}"
  echo ""
  echo "$data" | _format_table id name type status endpoint
}

apigw_create() {
  _require_auth
  local name type
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$type" ]] && payload="${payload},\"type\":\"${type}\""
  payload="${payload}}"

  _info "Creating API gateway ${BOLD}${name}${NC} ..."
  _api_post "/api-gateway/apis" "$payload" >/dev/null
  _success "API gateway created."
}

apigw_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "API_ID" "$id"
  local body
  body=$(_api_get "/api-gateway/apis/${id}")
  _extract_data "$body" | _json_pretty
}

apigw_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "API_ID" "$id"
  _api_delete "/api-gateway/apis/${id}" >/dev/null
  _success "API gateway ${id} deleted."
}

apigw_deploy() {
  _require_auth
  local id="${1:-}"
  _require_arg "API_ID" "$id"

  _info "Deploying API gateway ${BOLD}${id}${NC} ..."
  _api_post "/api-gateway/apis/${id}/deploy" >/dev/null
  _success "API gateway ${id} deployed."
}

# ════════════════════════════════════════════════════════════════════════════
#                       SECRETS MANAGER COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_secrets() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       secrets_list "$@" ;;
    create)     secrets_create "$@" ;;
    get|show)   secrets_get "$@" ;;
    delete)     secrets_delete "$@" ;;
    rotate)     secrets_rotate "$@" ;;
    value)      secrets_value "$@" ;;
    help|*)     secrets_help ;;
  esac
}

secrets_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin secrets <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all secrets
  create --name NAME --value VALUE  Create a new secret
  get ID                            Show secret details
  value ID                          Get secret value
  rotate ID                         Rotate a secret
  delete ID                         Delete a secret
EOF
}

secrets_list() {
  _require_auth
  local body
  body=$(_api_get "/secrets")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Secrets${NC}"
  echo ""
  echo "$data" | _format_table id name status lastRotated createdAt
}

secrets_create() {
  _require_auth
  local name value
  name=$(_parse_flag "--name" "$@")
  value=$(_parse_flag "--value" "$@")
  _require_arg "--name" "$name"
  _require_arg "--value" "$value"

  _info "Creating secret ${BOLD}${name}${NC} ..."
  _api_post "/secrets" "{\"name\":\"${name}\",\"secretValue\":\"${value}\"}" >/dev/null
  _success "Secret created."
}

secrets_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECRET_ID" "$id"
  local body
  body=$(_api_get "/secrets/${id}")
  _extract_data "$body" | _json_pretty
}

secrets_value() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECRET_ID" "$id"
  local body
  body=$(_api_get "/secrets/${id}/value")
  _extract_data "$body" | _json_pretty
}

secrets_rotate() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECRET_ID" "$id"
  _api_post "/secrets/${id}/rotate" >/dev/null
  _success "Secret ${id} rotation initiated."
}

secrets_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SECRET_ID" "$id"
  _api_delete "/secrets/${id}" >/dev/null
  _success "Secret ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       SUPPORT COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_support() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       support_list "$@" ;;
    create)     support_create "$@" ;;
    get|show)   support_get "$@" ;;
    close)      support_close "$@" ;;
    reply)      support_reply "$@" ;;
    help|*)     support_help ;;
  esac
}

support_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin support <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all support tickets
  create --subject SUBJECT --body BODY [--priority low|medium|high|critical]
                                    Create a new ticket
  get ID                            Show ticket details
  reply ID --body MESSAGE           Reply to a ticket
  close ID                          Close a ticket
EOF
}

support_list() {
  _require_auth
  local body
  body=$(_api_get "/support/tickets")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Support Tickets${NC}"
  echo ""
  echo "$data" | _format_table id subject priority status createdAt
}

support_create() {
  _require_auth
  local subject body_text priority
  subject=$(_parse_flag "--subject" "$@")
  body_text=$(_parse_flag "--body" "$@")
  priority=$(_parse_flag "--priority" "$@")
  _require_arg "--subject" "$subject"
  _require_arg "--body" "$body_text"

  local payload="{\"subject\":\"${subject}\",\"body\":\"${body_text}\""
  [[ -n "$priority" ]] && payload="${payload},\"priority\":\"${priority}\""
  payload="${payload}}"

  _info "Creating support ticket ..."
  _api_post "/support/tickets" "$payload" >/dev/null
  _success "Ticket created."
}

support_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "TICKET_ID" "$id"
  local body
  body=$(_api_get "/support/tickets/${id}")
  _extract_data "$body" | _json_pretty
}

support_reply() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "TICKET_ID" "$id"
  local msg
  msg=$(_parse_flag "--body" "$@")
  _require_arg "--body" "$msg"

  _api_post "/support/tickets/${id}/messages" "{\"body\":\"${msg}\"}" >/dev/null
  _success "Reply added to ticket ${id}."
}

support_close() {
  _require_auth
  local id="${1:-}"
  _require_arg "TICKET_ID" "$id"
  _api_patch "/support/tickets/${id}/close" >/dev/null
  _success "Ticket ${id} closed."
}

# ════════════════════════════════════════════════════════════════════════════
#                       MARKETPLACE COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_marketplace() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)         marketplace_list "$@" ;;
    get|show)     marketplace_get "$@" ;;
    deploy)       marketplace_deploy "$@" ;;
    help|*)       marketplace_help ;;
  esac
}

marketplace_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin marketplace <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all marketplace products
  get ID                            Show product details
  deploy ID                         Deploy a marketplace product
EOF
}

marketplace_list() {
  _require_auth
  local body
  body=$(_api_get "/marketplace/products")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Marketplace Products${NC}"
  echo ""
  echo "$data" | _format_table id name category vendor price
}

marketplace_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "PRODUCT_ID" "$id"
  local body
  body=$(_api_get "/marketplace/products/${id}")
  _extract_data "$body" | _json_pretty
}

marketplace_deploy() {
  _require_auth
  local body
  body=$(_api_get "/marketplace/subscriptions")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       AUTO SCALING COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_autoscaling() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       as_list "$@" ;;
    create)     as_create "$@" ;;
    get|show)   as_get "$@" ;;
    delete)     as_delete "$@" ;;
    help|*)     as_help ;;
  esac
}

as_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin autoscaling <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all auto scaling groups
  create --name NAME --min MIN --max MAX --desired DESIRED
                                    Create a new auto scaling group
  get ID                            Show auto scaling group details
  delete ID                         Delete an auto scaling group
EOF
}

as_list() {
  _require_auth
  local body
  body=$(_api_get "/compute/auto-scaling")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Auto Scaling Groups${NC}"
  echo ""
  echo "$data" | _format_table id name minSize maxSize desiredCapacity status
}

as_create() {
  _require_auth
  local name min max desired
  name=$(_parse_flag "--name" "$@")
  min=$(_parse_flag "--min" "$@")
  max=$(_parse_flag "--max" "$@")
  desired=$(_parse_flag "--desired" "$@")
  _require_arg "--name" "$name"
  _require_arg "--min" "$min"
  _require_arg "--max" "$max"
  _require_arg "--desired" "$desired"

  _info "Creating auto scaling group ${BOLD}${name}${NC} ..."
  _api_post "/compute/auto-scaling" "{\"name\":\"${name}\",\"minSize\":${min},\"maxSize\":${max},\"desiredCapacity\":${desired}}" >/dev/null
  _success "Auto scaling group created."
}

as_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "ASG_ID" "$id"
  local body
  body=$(_api_get "/compute/auto-scaling/${id}")
  _extract_data "$body" | _json_pretty
}

as_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "ASG_ID" "$id"
  _api_delete "/compute/auto-scaling/${id}" >/dev/null
  _success "Auto scaling group ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       K8S PODS & SERVICES COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_pod() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       pod_list "$@" ;;
    get|show)   pod_get "$@" ;;
    delete)     pod_delete "$@" ;;
    logs)       pod_logs "$@" ;;
    help|*)     pod_help ;;
  esac
}

pod_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin pod <subcommand> [options]

${BOLD}Subcommands:${NC}
  list [--namespace NS]             List all pods
  get ID                            Show pod details
  delete ID                         Delete a pod
  logs ID [--tail N]                Get pod logs
EOF
}

pod_list() {
  _require_auth
  local ns
  ns=$(_parse_flag "--namespace" "$@")
  local endpoint="/kubernetes/pods"
  [[ -n "$ns" ]] && endpoint="${endpoint}?namespace=${ns}"

  local body
  body=$(_api_get "$endpoint")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Kubernetes Pods${NC}"
  echo ""
  echo "$data" | _format_table id name namespace status node containers restarts
}

pod_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "POD_ID" "$id"
  local body
  body=$(_api_get "/kubernetes/pods/${id}")
  _extract_data "$body" | _json_pretty
}

pod_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "POD_ID" "$id"
  _api_delete "/kubernetes/pods/${id}" >/dev/null
  _success "Pod ${id} deleted."
}

pod_logs() {
  _require_auth
  local id="${1:-}"; shift 2>/dev/null || true
  _require_arg "POD_ID" "$id"
  local tail
  tail=$(_parse_flag "--tail" "$@")

  local endpoint="/kubernetes/pods/${id}/logs"
  [[ -n "$tail" ]] && endpoint="${endpoint}?tailLines=${tail}"

  local body
  body=$(_api_get "$endpoint")
  local data
  data=$(_extract_data "$body")
  echo "$data" | _json_get '.logs'
}

cmd_k8s_svc() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       k8s_svc_list "$@" ;;
    get|show)   k8s_svc_get "$@" ;;
    create)     k8s_svc_create "$@" ;;
    delete)     k8s_svc_delete "$@" ;;
    help|*)     k8s_svc_help ;;
  esac
}

k8s_svc_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin k8s-svc <subcommand> [options]

${BOLD}Subcommands:${NC}
  list [--namespace NS]             List all K8s services
  get ID                            Show service details
  create --name NAME --namespace NS --type TYPE
                                    Create a new service
  delete ID                         Delete a service
EOF
}

k8s_svc_list() {
  _require_auth
  local ns
  ns=$(_parse_flag "--namespace" "$@")
  local endpoint="/kubernetes/services"
  [[ -n "$ns" ]] && endpoint="${endpoint}?namespace=${ns}"

  local body
  body=$(_api_get "$endpoint")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Kubernetes Services${NC}"
  echo ""
  echo "$data" | _format_table id name namespace type clusterIP
}

k8s_svc_get() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"
  local body
  body=$(_api_get "/kubernetes/services/${id}")
  _extract_data "$body" | _json_pretty
}

k8s_svc_create() {
  _require_auth
  local name ns type
  name=$(_parse_flag "--name" "$@")
  ns=$(_parse_flag "--namespace" "$@")
  type=$(_parse_flag "--type" "$@")
  _require_arg "--name" "$name"

  local payload="{\"name\":\"${name}\""
  [[ -n "$ns" ]]   && payload="${payload},\"namespace\":\"${ns}\""
  [[ -n "$type" ]] && payload="${payload},\"type\":\"${type}\""
  payload="${payload}}"

  _api_post "/kubernetes/services" "$payload" >/dev/null
  _success "K8s service created."
}

k8s_svc_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "SERVICE_ID" "$id"
  _api_delete "/kubernetes/services/${id}" >/dev/null
  _success "Service ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       CONSUMPTION COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_consumption() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    summary)    consumption_summary "$@" ;;
    trends)     consumption_trends "$@" ;;
    forecast)   consumption_forecast "$@" ;;
    prices)     consumption_prices "$@" ;;
    help|*)     consumption_help ;;
  esac
}

consumption_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin consumption <subcommand> [options]

${BOLD}Subcommands:${NC}
  summary                           Show usage summary
  trends                            Show cost trends
  forecast                          Show cost forecast
  prices                            Show service prices
EOF
}

consumption_summary() {
  _require_auth
  local body
  body=$(_api_get "/consumption/summary")
  _extract_data "$body" | _json_pretty
}

consumption_trends() {
  _require_auth
  local body
  body=$(_api_get "/consumption/trends")
  _extract_data "$body" | _json_pretty
}

consumption_forecast() {
  _require_auth
  local body
  body=$(_api_get "/consumption/forecast")
  _extract_data "$body" | _json_pretty
}

consumption_prices() {
  _require_auth
  local body
  body=$(_api_get "/consumption/prices")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                       AI SERVICES COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_ai() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    models)     ai_models "$@" ;;
    chat)       ai_chat "$@" ;;
    image)      ai_image "$@" ;;
    speak)      ai_speak "$@" ;;
    transcribe) ai_transcribe "$@" ;;
    embed)      ai_embed "$@" ;;
    kb)         cmd_ai_kb "$@" ;;
    guardrails) cmd_ai_guardrails "$@" ;;
    eval)       cmd_ai_eval "$@" ;;
    usage)      ai_usage "$@" ;;
    help|*)     ai_help ;;
  esac
}

cmd_ai_guardrails() {
  _require_auth
  local sub="${1:-show}"; shift 2>/dev/null || true
  case "$sub" in
    show)    _extract_data "$(_api_get "/ai/guardrails")" | _json_pretty ;;
    enable)  _extract_data "$(_api_request PUT "/ai/guardrails" '{"enabled":true}')" | _json_pretty ;;
    disable) _extract_data "$(_api_request PUT "/ai/guardrails" '{"enabled":false}')" | _json_pretty ;;
    test)
      local text; text=$(_parse_flag "--text" "$@")
      _require_arg "--text" "$text"
      _extract_data "$(_api_post "/ai/guardrails/test" "{\"text\":\"${text}\"}")" | _json_pretty
      ;;
    *) echo "Usage: devskin ai guardrails {show|enable|disable|test --text \"...\"}" ;;
  esac
}

cmd_ai_eval() {
  _require_auth
  local sub="${1:-list}"; shift 2>/dev/null || true
  case "$sub" in
    list)
      _extract_data "$(_api_get "/ai/evaluations")" | _format_table id name status totalCostUsd
      ;;
    show)
      local id; id=$(_parse_flag "--id" "$@")
      _require_arg "--id" "$id"
      _extract_data "$(_api_get "/ai/evaluations/${id}")" | _json_pretty
      ;;
    run)
      local payload; payload=$(_parse_flag "--json" "$@")
      _require_arg "--json" "$payload"
      _extract_data "$(_api_post "/ai/evaluations" "$payload")" | _json_pretty
      ;;
    delete)
      local id; id=$(_parse_flag "--id" "$@")
      _require_arg "--id" "$id"
      _api_delete "/ai/evaluations/${id}" | _json_pretty
      ;;
    *) echo "Usage: devskin ai eval {list|show --id ID|run --json '{...}'|delete --id ID}" ;;
  esac
}

ai_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin ai <subcommand> [options]

${BOLD}Models / Catalog:${NC}
  models                                       List available models (OpenAI GPT-5.x, Claude 4.x)

${BOLD}Chat / Generation:${NC}
  chat --model MODEL --message MSG             Send a chat message
  image --prompt "..." [--model gpt-image-1]   Generate an image (DALL·E 3 / GPT Image 2.0)
                  [--size 1024x1024] [--quality high]
  speak --text "..." [--voice nova]            Synthesize speech (TTS)
  transcribe --file path/to/audio.webm         Transcribe audio with Whisper
  embed --text "..." [--model text-embedding-3-small]  Create embedding vector

${BOLD}Knowledge Bases (RAG):${NC}
  kb list                                      List Knowledge Bases
  kb create --name N [--description D]         Create a new KB
  kb show --id KBID                            Show KB documents
  kb add --id KBID --file F                    Ingest a text document
  kb query --id KBID --query "..."             RAG query (returns answer + cited sources)
  kb delete --id KBID                          Delete a KB

${BOLD}Usage:${NC}
  usage                                        Show AI usage stats this month
EOF
}

ai_models() {
  _require_auth
  local body
  body=$(_api_get "/ai/models")
  _extract_data "$body" | _json_pretty
}

ai_chat() {
  _require_auth
  local model msg
  model=$(_parse_flag "--model" "$@")
  msg=$(_parse_flag "--message" "$@")
  _require_arg "--model" "$model"
  _require_arg "--message" "$msg"

  local body
  body=$(_api_post "/ai/chat" "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"${msg}\"}]}")
  _extract_data "$body" | _json_pretty
}

ai_image() {
  _require_auth
  local prompt model size quality n
  prompt=$(_parse_flag "--prompt" "$@")
  model=$(_parse_flag "--model" "$@")
  size=$(_parse_flag "--size" "$@")
  quality=$(_parse_flag "--quality" "$@")
  n=$(_parse_flag "--n" "$@")
  _require_arg "--prompt" "$prompt"

  local payload="{\"prompt\":\"${prompt}\""
  [[ -n "$model" ]]   && payload+=",\"model\":\"${model}\""
  [[ -n "$size" ]]    && payload+=",\"size\":\"${size}\""
  [[ -n "$quality" ]] && payload+=",\"quality\":\"${quality}\""
  [[ -n "$n" ]]       && payload+=",\"n\":${n}"
  payload+="}"

  local body
  body=$(_api_post "/ai/images/generate" "$payload")
  _extract_data "$body" | _json_pretty
}

ai_speak() {
  _require_auth
  local text voice model fmt
  text=$(_parse_flag "--text" "$@")
  voice=$(_parse_flag "--voice" "$@")
  model=$(_parse_flag "--model" "$@")
  fmt=$(_parse_flag "--format" "$@")
  _require_arg "--text" "$text"

  local payload="{\"text\":\"${text}\""
  [[ -n "$voice" ]] && payload+=",\"voice\":\"${voice}\""
  [[ -n "$model" ]] && payload+=",\"model\":\"${model}\""
  [[ -n "$fmt" ]]   && payload+=",\"format\":\"${fmt}\""
  payload+="}"

  local out="speech-$(date +%s).mp3"
  curl -sS -X POST "${API_BASE}/ai/text-to-speech" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" -o "$out"
  echo "Saved: $out"
}

ai_transcribe() {
  _require_auth
  local file lang
  file=$(_parse_flag "--file" "$@")
  lang=$(_parse_flag "--language" "$@")
  _require_arg "--file" "$file"
  [[ -f "$file" ]] || { echo "File not found: $file"; return 1; }

  local b64
  b64=$(base64 -w0 "$file")
  local payload="{\"audio\":\"${b64}\""
  [[ -n "$lang" ]] && payload+=",\"language\":\"${lang}\""
  payload+="}"

  local body
  body=$(_api_post "/ai/speech-to-text" "$payload")
  _extract_data "$body" | _json_pretty
}

ai_embed() {
  _require_auth
  local text model
  text=$(_parse_flag "--text" "$@")
  model=$(_parse_flag "--model" "$@")
  _require_arg "--text" "$text"
  local payload="{\"text\":\"${text}\""
  [[ -n "$model" ]] && payload+=",\"model\":\"${model}\""
  payload+="}"
  local body
  body=$(_api_post "/ai/embeddings" "$payload")
  _extract_data "$body" | _json_pretty
}

cmd_ai_kb() {
  local sub="${1:-list}"; shift 2>/dev/null || true
  case "$sub" in
    list)   ai_kb_list "$@" ;;
    create) ai_kb_create "$@" ;;
    show)   ai_kb_show "$@" ;;
    add)    ai_kb_add "$@" ;;
    query)  ai_kb_query "$@" ;;
    delete) ai_kb_delete "$@" ;;
    *)      ai_help ;;
  esac
}

ai_kb_list() {
  _require_auth
  local body
  body=$(_api_get "/ai/knowledge-bases")
  _extract_data "$body" | _format_table id name documentCount totalChunks
}

ai_kb_create() {
  _require_auth
  local name desc embed chat
  name=$(_parse_flag "--name" "$@")
  desc=$(_parse_flag "--description" "$@")
  embed=$(_parse_flag "--embedding-model" "$@")
  chat=$(_parse_flag "--chat-model" "$@")
  _require_arg "--name" "$name"
  local payload="{\"name\":\"${name}\""
  [[ -n "$desc" ]]  && payload+=",\"description\":\"${desc}\""
  [[ -n "$embed" ]] && payload+=",\"embeddingModel\":\"${embed}\""
  [[ -n "$chat" ]]  && payload+=",\"chatModel\":\"${chat}\""
  payload+="}"
  local body
  body=$(_api_post "/ai/knowledge-bases" "$payload")
  _extract_data "$body" | _json_pretty
}

ai_kb_show() {
  _require_auth
  local id
  id=$(_parse_flag "--id" "$@")
  _require_arg "--id" "$id"
  local body
  body=$(_api_get "/ai/knowledge-bases/${id}")
  _extract_data "$body" | _json_pretty
}

ai_kb_add() {
  _require_auth
  local id file filename
  id=$(_parse_flag "--id" "$@")
  file=$(_parse_flag "--file" "$@")
  _require_arg "--id" "$id"
  _require_arg "--file" "$file"
  [[ -f "$file" ]] || { echo "File not found: $file"; return 1; }
  filename=$(basename "$file")
  local text
  text=$(jq -Rs . < "$file")
  local payload="{\"filename\":\"${filename}\",\"text\":${text}}"
  local body
  body=$(_api_post "/ai/knowledge-bases/${id}/documents" "$payload")
  _extract_data "$body" | _json_pretty
}

ai_kb_query() {
  _require_auth
  local id query topk model
  id=$(_parse_flag "--id" "$@")
  query=$(_parse_flag "--query" "$@")
  topk=$(_parse_flag "--top-k" "$@")
  model=$(_parse_flag "--model" "$@")
  _require_arg "--id" "$id"
  _require_arg "--query" "$query"
  local payload="{\"query\":\"${query}\""
  [[ -n "$topk" ]]  && payload+=",\"topK\":${topk}"
  [[ -n "$model" ]] && payload+=",\"model\":\"${model}\""
  payload+="}"
  local body
  body=$(_api_post "/ai/knowledge-bases/${id}/query" "$payload")
  _extract_data "$body" | _json_pretty
}

ai_kb_delete() {
  _require_auth
  local id
  id=$(_parse_flag "--id" "$@")
  _require_arg "--id" "$id"
  local body
  body=$(_api_delete "/ai/knowledge-bases/${id}")
  echo "$body" | _json_pretty
}

ai_usage() {
  _require_auth
  local body
  body=$(_api_get "/ai/usage")
  _extract_data "$body" | _json_pretty
}

# ════════════════════════════════════════════════════════════════════════════
#                         LAKEHOUSE (DevskinLake) COMMANDS
# ════════════════════════════════════════════════════════════════════════════
# Note: ML/AI lakehouse subcommands (`lake ml ...`) are intentionally NOT
# exposed here — they are owned by another CLI agent.

cmd_lake() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    catalog)   lake_catalog "$@" ;;
    sql)       lake_sql "$@" ;;
    spark)     lake_spark "$@" ;;
    notebook|notebooks)
               lake_notebook "$@" ;;
    kafka|streaming)
               lake_kafka "$@" ;;
    airflow|workflow|workflows)
               lake_airflow "$@" ;;
    lineage)   lake_lineage "$@" ;;
    quality)   lake_quality "$@" ;;
    admin)     lake_admin "$@" ;;
    help|*)    lake_help ;;
  esac
}

lake_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin lake <subcommand> [options]

${BOLD}Catalog:${NC}
  lake catalog list                    List Lakehouse databases
  lake catalog create NAME [--description S] [--bucket BUCKET_ID]
                                       Create a new database
  lake catalog delete DB_ID            Delete a database (asks for confirmation)
  lake catalog tables DB_ID            List tables in a database
  lake catalog tables create DB_ID --name N --columns name:type,name:type
                                       Create an Iceberg table (schema cannot be patched)
  lake catalog tables delete TABLE_ID  Delete a table (drops underlying data)
  lake catalog optimize TABLE_ID [--sort-columns c1,c2,...]
                                       Run an Iceberg OPTIMIZE on a table
  lake catalog optimize-schedule TABLE_ID --schedule @hourly|@daily|@weekly|none
                                       Set/clear the optimize schedule
  lake catalog row-filters TABLE_ID --add ROLE:PREDICATE [--add ...]|--clear
                                       Manage row-level access filters
  lake catalog column-masks TABLE_ID --add COL:ROLE:hash|redact|partial [--add ...]|--clear
                                       Manage column masks
  lake catalog mv list DB_ID           List materialized views in a database
  lake catalog mv create DB_ID --name N --query "..." [--schedule @daily]
                                       Create a materialized view
  lake catalog mv refresh MV_ID        Refresh a materialized view
  lake catalog mv delete MV_ID         Delete a materialized view

${BOLD}SQL:${NC}
  lake sql run "QUERY"                 Submit a SQL query, poll until done
  lake sql list [--limit N]            List recent SQL queries
  lake sql cancel QUERY_ID             Cancel a running SQL query
  lake sql ask "QUESTION" [--database DB_ID] [--run]
                                       Genie NL->SQL: generate SQL via AI, optionally run
  lake sql saved list                  List saved queries
  lake sql saved create --name N --query FILE [--schedule @daily] [--description S]
                                       Save a query (file contents become the query)
  lake sql saved run ID                Execute a saved query
  lake sql saved delete ID             Delete a saved query

${BOLD}Spark Jobs:${NC}
  lake spark list                      List Spark jobs
  lake spark create --name N --code FILE [--language pyspark|scala|sql]
                  [--driver-cores N] [--driver-mem GB]
                  [--executor-cores N] [--executor-mem GB]
                  [--executors N] [--schedule CRON]
                                       Create a Spark job
  lake spark run JOB_ID                Trigger a job run
  lake spark runs JOB_ID               List runs of a job
  lake spark logs JOB_ID RUN_ID        Print driver logs for a single run

${BOLD}Data-Platform VMs:${NC} (deprecated managed paths — now marketplace VMs)
  JupyterLab → \`devskin marketplace deploy mp-030 --name my-jupyter\`
  Apache Kafka → \`devskin marketplace deploy mp-040 --name my-kafka\`
  Apache Airflow → \`devskin marketplace deploy mp-050 --name my-airflow\`
  The old \`lake notebook|kafka|airflow\` subcommands exit 1 with a pointer
  to the marketplace flow.

${BOLD}Lineage & Quality:${NC}
  lake lineage                         Show data lineage graph
  lake quality list                    List data-quality rules
  lake quality create --name N --expectations FILE [--table TABLE_ID]
                  [--schedule CRON]
                                       Create a data-quality rule (JSON file)

${BOLD}Admin:${NC}
  lake admin status                    Show health of the Lakehouse stack
  lake admin deploy                    Deploy/upgrade the entire stack
  lake admin cost                      Show current vs previous month cost per area
  lake admin warehouse                 Show Trino warehouse status (workers/running/queued)
EOF
}

# ── Catalog ─────────────────────────────────────────────────────────────────
lake_catalog() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)               lake_catalog_list "$@" ;;
    create)             lake_catalog_create "$@" ;;
    delete|remove|rm)   lake_catalog_delete "$@" ;;
    tables)             lake_catalog_tables "$@" ;;
    optimize)           lake_catalog_optimize "$@" ;;
    optimize-schedule)  lake_catalog_optimize_schedule "$@" ;;
    row-filters)        lake_catalog_row_filters "$@" ;;
    column-masks)       lake_catalog_column_masks "$@" ;;
    mv)                 lake_catalog_mv "$@" ;;
    help|*)             echo "Usage: devskin lake catalog {list|create|delete|tables|optimize|optimize-schedule|row-filters|column-masks|mv}" ;;
  esac
}

lake_catalog_list() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/catalog/databases")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Lakehouse Databases${NC}"
  echo ""
  echo "$data" | _format_table id name s3Location createdAt
}

lake_catalog_create() {
  _require_auth
  local name="${1:-}"; shift 2>/dev/null || true
  _require_arg "NAME" "$name"
  local description bucket
  description=$(_parse_flag "--description" "$@")
  bucket=$(_parse_flag "--bucket" "$@")

  local payload="{\"name\":\"${name}\""
  [[ -n "$description" ]] && payload+=",\"description\":\"${description}\""
  [[ -n "$bucket" ]]      && payload+=",\"bucketId\":\"${bucket}\""
  payload+="}"

  _info "Creating Lakehouse database ${BOLD}${name}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/catalog/databases" "$payload")
  data=$(_extract_data "$body")
  _success "Database created."
  echo ""
  echo "  ID:          $(echo "$data" | _json_get '.id')"
  echo "  Name:        $(echo "$data" | _json_get '.name')"
  echo "  S3 Location: $(echo "$data" | _json_get '.s3Location')"
}

lake_catalog_delete() {
  _require_auth
  local db_id="${1:-}"
  _require_arg "DB_ID" "$db_id"

  read -rp "Are you sure you want to delete Lakehouse database ${db_id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting Lakehouse database ${BOLD}${db_id}${NC} ..."
  _api_delete "/lakehouse/catalog/databases/${db_id}" >/dev/null
  _success "Database deleted."
}

lake_catalog_tables() {
  # First arg can be `create` / `delete` (sub-action) or a database id (legacy
  # list behaviour). Anything else falls through to the list path.
  local first="${1:-}"
  case "$first" in
    create)             shift; lake_catalog_tables_create "$@"; return $? ;;
    delete|remove|rm)   shift; lake_catalog_tables_delete "$@"; return $? ;;
  esac

  _require_auth
  local db_id="${first}"
  _require_arg "DB_ID" "$db_id"
  local body data
  body=$(_api_get "/lakehouse/catalog/databases/${db_id}/tables")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Tables in database ${db_id}${NC}"
  echo ""
  echo "$data" | _format_table id name format rowCount sizeBytes
}

lake_catalog_tables_create() {
  _require_auth
  local db_id="${1:-}"; shift 2>/dev/null || true
  _require_arg "DB_ID" "$db_id"

  local name columns
  name=$(_parse_flag "--name" "$@")
  columns=$(_parse_flag "--columns" "$@")
  _require_arg "--name" "$name"
  _require_arg "--columns" "$columns"

  # Build columns JSON from "id:bigint,created_at:timestamp,user_id:varchar".
  local cols_json="["
  local first=1
  local IFS=','
  for spec in $columns; do
    local col_name="${spec%%:*}"
    local col_type="${spec#*:}"
    if [[ -z "$col_name" || -z "$col_type" || "$col_name" == "$col_type" ]]; then
      _fatal "Invalid column spec '${spec}' — expected name:type."
    fi
    [[ $first -eq 1 ]] || cols_json+=","
    cols_json+="{\"name\":\"${col_name}\",\"type\":\"${col_type}\"}"
    first=0
  done
  cols_json+="]"
  unset IFS

  local payload="{\"name\":\"${name}\",\"columns\":${cols_json}}"
  _info "Creating table ${BOLD}${name}${NC} in database ${db_id} ..."
  local body data
  body=$(_api_post "/lakehouse/catalog/databases/${db_id}/tables" "$payload")
  data=$(_extract_data "$body")
  _success "Table created."
  echo ""
  echo "  ID:          $(echo "$data" | _json_get '.id')"
  echo "  Name:        $(echo "$data" | _json_get '.name')"
  echo "  Format:      $(echo "$data" | _json_get '.format')"
  echo "  S3 Location: $(echo "$data" | _json_get '.s3Location')"
}

lake_catalog_tables_delete() {
  _require_auth
  local table_id="${1:-}"
  _require_arg "TABLE_ID" "$table_id"

  read -rp "Are you sure you want to delete table ${table_id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting table ${BOLD}${table_id}${NC} ..."
  _api_delete "/lakehouse/catalog/tables/${table_id}" >/dev/null
  _success "Table deleted."
}

# ── SQL ─────────────────────────────────────────────────────────────────────
lake_sql() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    run)               lake_sql_run "$@" ;;
    list|ls)           lake_sql_list "$@" ;;
    cancel|kill)       lake_sql_cancel "$@" ;;
    ask)               lake_sql_ask "$@" ;;
    saved)             lake_sql_saved "$@" ;;
    help|*)            echo "Usage: devskin lake sql {run|list|cancel|ask|saved}" ;;
  esac
}

lake_sql_run() {
  _require_auth
  local query="${1:-}"
  _require_arg "QUERY" "$query"

  # Encode query as JSON string (handles newlines, quotes safely).
  local query_json payload
  if _has_jq; then
    query_json=$(printf '%s' "$query" | jq -Rs .)
  else
    # Fallback: naive escaping (replace " and \).
    local esc
    esc="${query//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    query_json="\"${esc}\""
  fi
  payload="{\"query\":${query_json}}"

  _info "Submitting SQL query ..."
  local body data qid
  body=$(_api_post "/lakehouse/sql/queries" "$payload")
  data=$(_extract_data "$body")
  qid=$(echo "$data" | _json_get '.id')
  if [[ -z "$qid" || "$qid" == "null" || "$qid" == "None" ]]; then
    _error "Could not parse query id from response."
    echo "$body" | _json_pretty
    return 1
  fi

  _info "Query submitted (id=${qid}). Polling status..."
  local status="pending" attempts=0
  while [[ "$status" != "succeeded" && "$status" != "failed" && "$status" != "cancelled" && $attempts -lt 60 ]]; do
    sleep 2
    attempts=$((attempts + 1))
    body=$(_api_get "/lakehouse/sql/queries/${qid}")
    data=$(_extract_data "$body")
    status=$(echo "$data" | _json_get '.status')
    [[ "$status" == "null" || "$status" == "None" ]] && status="pending"
  done

  echo ""
  echo "  Query ID:    ${qid}"
  echo "  Status:      ${status}"
  echo "  Rows:        $(echo "$data" | _json_get '.rowCount')"
  echo "  Bytes Read:  $(echo "$data" | _json_get '.bytesScanned')"
  echo "  Duration ms: $(echo "$data" | _json_get '.durationMs')"
  if [[ "$status" == "failed" ]]; then
    echo "  Error:       $(echo "$data" | _json_get '.errorMessage')"
  fi
}

lake_sql_list() {
  _require_auth
  local limit
  limit=$(_parse_flag "--limit" "$@")
  local path="/lakehouse/sql/queries"
  [[ -n "$limit" ]] && path="${path}?limit=${limit}"
  local body data
  body=$(_api_get "$path")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Recent SQL Queries${NC}"
  echo ""
  echo "$data" | _format_table id status rowCount durationMs createdAt
}

lake_sql_cancel() {
  _require_auth
  local qid="${1:-}"
  _require_arg "QUERY_ID" "$qid"
  _info "Cancelling query ${BOLD}${qid}${NC} ..."
  _api_post "/lakehouse/sql/queries/${qid}/cancel" "{}" >/dev/null
  _success "Cancel signal sent."
}

# ── Spark ──────────────────────────────────────────────────────────────────
lake_spark() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls)           lake_spark_list "$@" ;;
    create)            lake_spark_create "$@" ;;
    run)               lake_spark_run "$@" ;;
    runs)              lake_spark_runs "$@" ;;
    logs)              lake_spark_logs "$@" ;;
    help|*)            echo "Usage: devskin lake spark {list|create|run|runs|logs}" ;;
  esac
}

lake_spark_list() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/spark/jobs")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Spark Jobs${NC}"
  echo ""
  echo "$data" | _format_table id name language scheduleCron status
}

lake_spark_create() {
  _require_auth
  local name code_file language driver_cores driver_mem executor_cores executor_mem executors schedule
  name=$(_parse_flag "--name" "$@")
  code_file=$(_parse_flag "--code" "$@")
  language=$(_parse_flag "--language" "$@")
  driver_cores=$(_parse_flag "--driver-cores" "$@")
  driver_mem=$(_parse_flag "--driver-mem" "$@")
  executor_cores=$(_parse_flag "--executor-cores" "$@")
  executor_mem=$(_parse_flag "--executor-mem" "$@")
  executors=$(_parse_flag "--executors" "$@")
  schedule=$(_parse_flag "--schedule" "$@")

  _require_arg "--name" "$name"
  _require_arg "--code" "$code_file"
  [[ -f "$code_file" ]] || _fatal "Code file not found: ${code_file}"

  language="${language:-pyspark}"

  # Encode the source file as a JSON string.
  local code_json
  if _has_jq; then
    code_json=$(jq -Rs . < "$code_file")
  else
    _fatal "jq is required to encode the source file. Please install jq."
  fi

  local payload="{\"name\":\"${name}\",\"language\":\"${language}\",\"code\":${code_json}"
  [[ -n "$driver_cores" ]]   && payload+=",\"driverCores\":${driver_cores}"
  [[ -n "$driver_mem" ]]     && payload+=",\"driverMemoryGb\":${driver_mem}"
  [[ -n "$executor_cores" ]] && payload+=",\"executorCores\":${executor_cores}"
  [[ -n "$executor_mem" ]]   && payload+=",\"executorMemoryGb\":${executor_mem}"
  [[ -n "$executors" ]]      && payload+=",\"numExecutors\":${executors}"
  [[ -n "$schedule" ]]       && payload+=",\"scheduleCron\":\"${schedule}\""
  payload+="}"

  _info "Creating Spark job ${BOLD}${name}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/spark/jobs" "$payload")
  data=$(_extract_data "$body")
  _success "Spark job created."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Language: $(echo "$data" | _json_get '.language')"
  echo "  Schedule: $(echo "$data" | _json_get '.scheduleCron')"
}

lake_spark_run() {
  _require_auth
  local job_id="${1:-}"
  _require_arg "JOB_ID" "$job_id"
  _info "Triggering Spark job ${BOLD}${job_id}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/spark/jobs/${job_id}/run" "{}")
  data=$(_extract_data "$body")
  _success "Run started."
  echo "  Run ID: $(echo "$data" | _json_get '.id')"
  echo "  Status: $(echo "$data" | _json_get '.status')"
}

lake_spark_runs() {
  _require_auth
  local job_id="${1:-}"
  _require_arg "JOB_ID" "$job_id"
  local body data
  body=$(_api_get "/lakehouse/spark/jobs/${job_id}/runs")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Runs of Spark Job ${job_id}${NC}"
  echo ""
  echo "$data" | _format_table id status startedAt finishedAt durationMs
}

lake_spark_logs() {
  _require_auth
  local job_id="${1:-}" run_id="${2:-}"
  _require_arg "JOB_ID" "$job_id"
  _require_arg "RUN_ID" "$run_id"
  local body data
  body=$(_api_get "/lakehouse/spark/jobs/${job_id}/runs/${run_id}/logs")
  data=$(_extract_data "$body")
  # Backend returns { logs: "..." }; print plain text without JSON wrapping.
  echo "$data" | _json_get '.logs'
}

# ── Notebook (DEPRECATED) ──────────────────────────────────────────────────
# JupyterLab now ships as a marketplace VM (mp-030, tpl-206). The legacy
# /lakehouse/notebooks endpoints still exist but the supported flow is to
# deploy a Jupyter VM via marketplace.
_lake_notebook_deprecated() {
  echo "JupyterLab is now deployed as a marketplace VM (mp-030)." >&2
  echo "" >&2
  echo "  Spin up your own JupyterLab:" >&2
  echo "    devskin marketplace deploy mp-030 --name my-jupyter" >&2
  echo "" >&2
  echo "  Then open https://<vm-public-ip>:8888/lab and use the token" >&2
  echo "  shown on the Connect screen of the VM." >&2
  echo "  See full instructions: devskin marketplace get mp-030" >&2
  return 1
}

lake_notebook()        { _lake_notebook_deprecated; }
lake_notebook_list()   { _lake_notebook_deprecated; }
lake_notebook_create() { _lake_notebook_deprecated; }
lake_notebook_start()  { _lake_notebook_deprecated; }
lake_notebook_stop()   { _lake_notebook_deprecated; }

# ── Kafka (DEPRECATED) ─────────────────────────────────────────────────────
# Apache Kafka now ships as a marketplace VM (mp-040, tpl-204). The legacy
# /lakehouse/streaming endpoints still exist but the supported flow is to
# deploy a Kafka VM via marketplace.
_lake_kafka_deprecated() {
  echo "Apache Kafka is now deployed as a marketplace VM (mp-040)." >&2
  echo "" >&2
  echo "  Spin up your own Kafka cluster:" >&2
  echo "    devskin marketplace deploy mp-040 --name my-kafka" >&2
  echo "" >&2
  echo "  Then connect with kafkacat / kafka-python using" >&2
  echo "  bootstrap-server <vm-public-ip>:9092." >&2
  echo "  See full instructions: devskin marketplace get mp-040" >&2
  return 1
}

lake_kafka()        { _lake_kafka_deprecated; }
lake_kafka_list()   { _lake_kafka_deprecated; }
lake_kafka_create() { _lake_kafka_deprecated; }
lake_kafka_topic()  { _lake_kafka_deprecated; }

# ── Airflow (DEPRECATED) ───────────────────────────────────────────────────
# Workflows endpoints were removed from the platform. Apache Airflow now ships
# as a marketplace VM (mp-050) — every command in this subtree exits 1 with a
# pointer to the new flow.
_lake_airflow_deprecated() {
  echo "Apache Airflow is now deployed as a marketplace VM (mp-050)." >&2
  echo "" >&2
  echo "  Spin up your own Airflow:" >&2
  echo "    devskin marketplace deploy mp-050 --name my-airflow" >&2
  echo "" >&2
  echo "  Then drop DAG files at /opt/airflow/dags/ on the VM via SSH." >&2
  echo "  See full instructions: devskin marketplace get mp-050" >&2
  return 1
}

lake_airflow()         { _lake_airflow_deprecated; }
lake_airflow_list()    { _lake_airflow_deprecated; }
lake_airflow_upload()  { _lake_airflow_deprecated; }
lake_airflow_trigger() { _lake_airflow_deprecated; }

# ── Lineage ────────────────────────────────────────────────────────────────
lake_lineage() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/lineage/graph")
  data=$(_extract_data "$body")

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$data" | _json_pretty
    return
  fi

  echo -e "${BOLD}Lakehouse Data Lineage${NC}"
  echo ""
  local node_count edge_count
  if _has_jq; then
    node_count=$(echo "$data" | jq '.nodes | length // 0' 2>/dev/null)
    edge_count=$(echo "$data" | jq '.edges | length // 0' 2>/dev/null)
  else
    node_count="?"; edge_count="?"
  fi
  echo "  Nodes: ${node_count}"
  echo "  Edges: ${edge_count}"
  echo ""
  echo "Use --json for the full graph."
}

# ── Quality ────────────────────────────────────────────────────────────────
lake_quality() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls)           lake_quality_list "$@" ;;
    create)            lake_quality_create "$@" ;;
    help|*)            echo "Usage: devskin lake quality {list|create}" ;;
  esac
}

lake_quality_list() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/quality/rules")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Data-Quality Rules${NC}"
  echo ""
  echo "$data" | _format_table id name tableId scheduleCron status
}

lake_quality_create() {
  _require_auth
  local name expectations_file table schedule
  name=$(_parse_flag "--name" "$@")
  expectations_file=$(_parse_flag "--expectations" "$@")
  table=$(_parse_flag "--table" "$@")
  schedule=$(_parse_flag "--schedule" "$@")

  _require_arg "--name" "$name"
  _require_arg "--expectations" "$expectations_file"
  [[ -f "$expectations_file" ]] || _fatal "Expectations file not found: ${expectations_file}"

  # The expectations file must contain a JSON array of objects.
  local expectations_json
  expectations_json=$(cat "$expectations_file")
  if _has_jq; then
    if ! echo "$expectations_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      _fatal "Expectations file must contain a JSON array of expectation objects."
    fi
  fi

  local payload="{\"name\":\"${name}\",\"expectations\":${expectations_json}"
  [[ -n "$table" ]]    && payload+=",\"tableId\":\"${table}\""
  [[ -n "$schedule" ]] && payload+=",\"scheduleCron\":\"${schedule}\""
  payload+="}"

  _info "Creating quality rule ${BOLD}${name}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/quality/rules" "$payload")
  data=$(_extract_data "$body")
  _success "Quality rule created."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Table:    $(echo "$data" | _json_get '.tableId')"
  echo "  Schedule: $(echo "$data" | _json_get '.scheduleCron')"
}

# ── Admin ──────────────────────────────────────────────────────────────────
lake_admin() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    status)            lake_admin_status "$@" ;;
    deploy|upgrade)    lake_admin_deploy "$@" ;;
    cost|costs)        lake_admin_cost "$@" ;;
    warehouse)         lake_admin_warehouse "$@" ;;
    help|*)            echo "Usage: devskin lake admin {status|deploy|cost|warehouse}" ;;
  esac
}

lake_admin_status() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/admin/status")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Lakehouse Stack Status${NC}"
  echo ""
  echo "$data" | _json_pretty
}

lake_admin_deploy() {
  _require_auth
  _warn "This will (re)deploy the entire Lakehouse stack on the platform's internal cluster."
  read -rp "Continue with deploy/upgrade? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi
  _info "Triggering Lakehouse deploy ..."
  local body data
  body=$(_api_post "/lakehouse/admin/deploy" "{}")
  data=$(_extract_data "$body")
  _success "Deploy triggered."
  echo ""
  echo "$data" | _json_pretty
}

lake_admin_cost() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/admin/cost")
  data=$(_extract_data "$body")
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$data" | _json_pretty
    return
  fi
  echo -e "${BOLD}Lakehouse Cost (current vs previous month)${NC}"
  echo ""
  if _has_jq; then
    local rows
    rows=$(echo "$data" | jq -r '.areas // . | (if type=="array" then .[] else . end) | "\(.area // .name)\t\(.currentMonth // .current // 0)\t\(.previousMonth // .previous // 0)\t\(.delta // 0)"' 2>/dev/null)
    printf "  %-20s %-15s %-15s %-10s\n" "AREA" "CURRENT" "PREVIOUS" "DELTA"
    printf "  %-20s %-15s %-15s %-10s\n" "----" "-------" "--------" "-----"
    while IFS=$'\t' read -r area cur prev delta; do
      [[ -z "$area" || "$area" == "null" ]] && continue
      printf "  %-20s %-15s %-15s %-10s\n" "$area" "$cur" "$prev" "$delta"
    done <<< "$rows"
  else
    echo "$data" | _json_pretty
  fi
}

lake_admin_warehouse() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/admin/warehouse")
  data=$(_extract_data "$body")
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$data" | _json_pretty
    return
  fi
  echo -e "${BOLD}Trino Warehouse Status${NC}"
  echo ""
  echo "  Status:           $(echo "$data" | _json_get '.status')"
  echo "  Workers:          $(echo "$data" | _json_get '.workers')"
  echo "  Active Workers:   $(echo "$data" | _json_get '.activeWorkers')"
  echo "  Running Queries:  $(echo "$data" | _json_get '.runningQueries')"
  echo "  Queued Queries:   $(echo "$data" | _json_get '.queuedQueries')"
  echo "  Coordinator:      $(echo "$data" | _json_get '.coordinator')"
}

# ── Catalog: optimize ───────────────────────────────────────────────────────
lake_catalog_optimize() {
  _require_auth
  local table_id="${1:-}"
  if [[ -z "$table_id" || "$table_id" == --* ]]; then
    _fatal "Missing TABLE_ID. Usage: devskin lake catalog optimize TABLE_ID [--sort-columns c1,c2,...]"
  fi
  shift || true
  local sort_columns
  sort_columns=$(_parse_flag "--sort-columns" "$@")

  local payload="{}"
  if [[ -n "$sort_columns" ]]; then
    # Convert "c1,c2" to JSON array.
    local cols_json
    if _has_jq; then
      cols_json=$(echo "$sort_columns" | jq -Rsc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    else
      cols_json="[$(echo "$sort_columns" | sed 's/[^,]*/"&"/g')]"
    fi
    payload="{\"sortColumns\":${cols_json}}"
  fi

  _info "Submitting OPTIMIZE for table ${BOLD}${table_id}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/catalog/tables/${table_id}/optimize" "$payload")
  data=$(_extract_data "$body")
  _success "Optimize submitted."
  echo ""
  echo "  Spark App ID:   $(echo "$data" | _json_get '.appId')"
  echo "  Run ID:         $(echo "$data" | _json_get '.runId')"
  echo "  Status:         $(echo "$data" | _json_get '.status')"
}

lake_catalog_optimize_schedule() {
  _require_auth
  local table_id="${1:-}"
  if [[ -z "$table_id" || "$table_id" == --* ]]; then
    _fatal "Missing TABLE_ID. Usage: devskin lake catalog optimize-schedule TABLE_ID --schedule @hourly|@daily|@weekly|none"
  fi
  shift || true
  local schedule
  schedule=$(_parse_flag "--schedule" "$@")
  _require_arg "--schedule" "$schedule"

  local sched_value
  if [[ "$schedule" == "none" || "$schedule" == "off" ]]; then
    sched_value="null"
  else
    sched_value="\"${schedule}\""
  fi
  local payload="{\"schedule\":${sched_value}}"

  _info "Setting optimize schedule for table ${BOLD}${table_id}${NC} -> ${schedule} ..."
  local body data
  body=$(_api_put "/lakehouse/catalog/tables/${table_id}/optimize-schedule" "$payload")
  data=$(_extract_data "$body")
  _success "Schedule updated."
  echo "  Schedule: $(echo "$data" | _json_get '.schedule')"
}

# ── Catalog: governance (row filters / column masks) ───────────────────────
_collect_repeated_flag() {
  # Echoes one VALUE per line, in order, for every "$flag VALUE" in args.
  local flag="$1"; shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$flag" && $# -ge 2 ]]; then
      echo "$2"
      shift 2
    else
      shift
    fi
  done
}

_has_clear_flag() {
  for arg in "$@"; do
    [[ "$arg" == "--clear" ]] && return 0
  done
  return 1
}

lake_catalog_row_filters() {
  _require_auth
  local table_id="${1:-}"
  if [[ -z "$table_id" || "$table_id" == --* ]]; then
    _fatal "Missing TABLE_ID. Usage: devskin lake catalog row-filters TABLE_ID --add ROLE:PREDICATE [...] | --clear"
  fi
  shift || true

  if _has_clear_flag "$@"; then
    _info "Clearing row filters on table ${BOLD}${table_id}${NC} ..."
    _api_put "/lakehouse/catalog/tables/${table_id}/row-filters" '{"rowFilters":[]}' >/dev/null
    _success "Row filters cleared."
    return
  fi

  local items_json="["
  local first=1 entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local role="" predicate="$entry"
    if [[ "$entry" == *:* ]]; then
      role="${entry%%:*}"
      predicate="${entry#*:}"
    fi
    local pred_json role_json
    if _has_jq; then
      pred_json=$(printf '%s' "$predicate" | jq -Rs .)
      role_json=$(printf '%s' "$role" | jq -Rs .)
    else
      pred_json="\"${predicate//\"/\\\"}\""
      role_json="\"${role//\"/\\\"}\""
    fi
    if [[ $first -eq 0 ]]; then items_json+=","; fi
    if [[ -n "$role" ]]; then
      items_json+="{\"role\":${role_json},\"predicate\":${pred_json}}"
    else
      items_json+="{\"predicate\":${pred_json}}"
    fi
    first=0
  done < <(_collect_repeated_flag "--add" "$@")

  if [[ $first -eq 1 ]]; then
    _fatal "Provide at least one --add ROLE:PREDICATE, or --clear to reset."
  fi
  items_json+="]"

  local payload="{\"rowFilters\":${items_json}}"
  _info "Updating row filters on table ${BOLD}${table_id}${NC} ..."
  local body data
  body=$(_api_put "/lakehouse/catalog/tables/${table_id}/row-filters" "$payload")
  data=$(_extract_data "$body")
  _success "Row filters updated."
  echo "$data" | _json_pretty
}

lake_catalog_column_masks() {
  _require_auth
  local table_id="${1:-}"
  if [[ -z "$table_id" || "$table_id" == --* ]]; then
    _fatal "Missing TABLE_ID. Usage: devskin lake catalog column-masks TABLE_ID --add COL:ROLE:hash|redact|partial [...] | --clear"
  fi
  shift || true

  if _has_clear_flag "$@"; then
    _info "Clearing column masks on table ${BOLD}${table_id}${NC} ..."
    _api_put "/lakehouse/catalog/tables/${table_id}/column-masks" '{"columnMasks":[]}' >/dev/null
    _success "Column masks cleared."
    return
  fi

  local items_json="["
  local first=1 entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Format: COL:ROLE:MASKTYPE  (ROLE is optional => COL::MASKTYPE or COL:MASKTYPE)
    local col="" role="" mask_type=""
    IFS=':' read -r col role mask_type <<< "$entry"
    if [[ -z "$mask_type" ]]; then
      # Two-segment form: COL:MASKTYPE
      mask_type="$role"
      role=""
    fi
    if [[ -z "$col" || -z "$mask_type" ]]; then
      _fatal "Invalid column-mask entry '${entry}'. Expected COL:ROLE:hash|redact|partial."
    fi
    case "$mask_type" in
      hash|redact|partial) : ;;
      *) _fatal "Invalid mask type '${mask_type}'. Must be one of: hash, redact, partial." ;;
    esac
    local col_json role_json mask_json
    if _has_jq; then
      col_json=$(printf '%s' "$col" | jq -Rs .)
      role_json=$(printf '%s' "$role" | jq -Rs .)
      mask_json=$(printf '%s' "$mask_type" | jq -Rs .)
    else
      col_json="\"${col//\"/\\\"}\""
      role_json="\"${role//\"/\\\"}\""
      mask_json="\"${mask_type//\"/\\\"}\""
    fi
    if [[ $first -eq 0 ]]; then items_json+=","; fi
    if [[ -n "$role" ]]; then
      items_json+="{\"column\":${col_json},\"role\":${role_json},\"maskType\":${mask_json}}"
    else
      items_json+="{\"column\":${col_json},\"maskType\":${mask_json}}"
    fi
    first=0
  done < <(_collect_repeated_flag "--add" "$@")

  if [[ $first -eq 1 ]]; then
    _fatal "Provide at least one --add COL:ROLE:hash|redact|partial, or --clear to reset."
  fi
  items_json+="]"

  local payload="{\"columnMasks\":${items_json}}"
  _info "Updating column masks on table ${BOLD}${table_id}${NC} ..."
  local body data
  body=$(_api_put "/lakehouse/catalog/tables/${table_id}/column-masks" "$payload")
  data=$(_extract_data "$body")
  _success "Column masks updated."
  echo "$data" | _json_pretty
}

# ── Catalog: materialized views ────────────────────────────────────────────
lake_catalog_mv() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls)           lake_catalog_mv_list "$@" ;;
    create)            lake_catalog_mv_create "$@" ;;
    refresh)           lake_catalog_mv_refresh "$@" ;;
    delete|remove|rm)  lake_catalog_mv_delete "$@" ;;
    help|*)            echo "Usage: devskin lake catalog mv {list|create|refresh|delete}" ;;
  esac
}

lake_catalog_mv_list() {
  _require_auth
  local db_id="${1:-}"
  _require_arg "DB_ID" "$db_id"
  local body data
  body=$(_api_get "/lakehouse/catalog/databases/${db_id}/materialized-views")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Materialized Views in database ${db_id}${NC}"
  echo ""
  echo "$data" | _format_table id name refreshSchedule lastRefreshed status
}

lake_catalog_mv_create() {
  _require_auth
  local db_id="${1:-}"
  if [[ -z "$db_id" || "$db_id" == --* ]]; then
    _fatal "Missing DB_ID. Usage: devskin lake catalog mv create DB_ID --name N --query \"SELECT...\" [--schedule @daily]"
  fi
  shift || true
  local name query schedule
  name=$(_parse_flag "--name" "$@")
  query=$(_parse_flag "--query" "$@")
  schedule=$(_parse_flag "--schedule" "$@")
  _require_arg "--name" "$name"
  _require_arg "--query" "$query"

  local query_json
  if _has_jq; then
    query_json=$(printf '%s' "$query" | jq -Rs .)
  else
    local esc="${query//\\/\\\\}"; esc="${esc//\"/\\\"}"
    query_json="\"${esc}\""
  fi

  local payload="{\"name\":\"${name}\",\"query\":${query_json}"
  [[ -n "$schedule" ]] && payload+=",\"refreshSchedule\":\"${schedule}\""
  payload+="}"

  _info "Creating materialized view ${BOLD}${name}${NC} in db ${db_id} ..."
  local body data
  body=$(_api_post "/lakehouse/catalog/databases/${db_id}/materialized-views" "$payload")
  data=$(_extract_data "$body")
  _success "Materialized view created."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Schedule: $(echo "$data" | _json_get '.refreshSchedule')"
  echo "  Status:   $(echo "$data" | _json_get '.status')"
}

lake_catalog_mv_refresh() {
  _require_auth
  local mv_id="${1:-}"
  _require_arg "MV_ID" "$mv_id"
  _info "Refreshing materialized view ${BOLD}${mv_id}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/catalog/materialized-views/${mv_id}/refresh" "{}")
  data=$(_extract_data "$body")
  _success "Refresh triggered."
  echo "  Run ID: $(echo "$data" | _json_get '.runId')"
  echo "  Status: $(echo "$data" | _json_get '.status')"
}

lake_catalog_mv_delete() {
  _require_auth
  local mv_id="${1:-}"
  _require_arg "MV_ID" "$mv_id"
  _info "Deleting materialized view ${BOLD}${mv_id}${NC} ..."
  _api_delete "/lakehouse/catalog/materialized-views/${mv_id}" >/dev/null
  _success "Materialized view deleted."
}

# ── SQL: ask (Genie NL->SQL) ────────────────────────────────────────────────
lake_sql_ask() {
  _require_auth
  local question="${1:-}"
  _require_arg "QUESTION" "$question"
  shift || true

  local database run=0
  database=$(_parse_flag "--database" "$@")
  for arg in "$@"; do
    [[ "$arg" == "--run" ]] && run=1
  done

  local q_json
  if _has_jq; then
    q_json=$(printf '%s' "$question" | jq -Rs .)
  else
    local esc="${question//\\/\\\\}"; esc="${esc//\"/\\\"}"
    q_json="\"${esc}\""
  fi
  local payload="{\"question\":${q_json}"
  [[ -n "$database" ]] && payload+=",\"databaseId\":\"${database}\""
  payload+="}"

  _info "Asking Genie ..."
  local body data sql
  body=$(_api_post "/lakehouse/sql/ask" "$payload")
  data=$(_extract_data "$body")
  sql=$(echo "$data" | _json_get '.sql')
  if [[ -z "$sql" || "$sql" == "null" || "$sql" == "None" ]]; then
    _error "Genie did not return a SQL statement."
    echo "$body" | _json_pretty
    return 1
  fi
  echo ""
  echo -e "${BOLD}Generated SQL:${NC}"
  echo ""
  echo "  ${sql}"
  echo ""

  if [[ $run -eq 1 ]]; then
    _info "Submitting generated SQL ..."
    lake_sql_run "$sql"
  else
    echo "Run with --run to submit it."
  fi
}

# ── SQL: saved queries ──────────────────────────────────────────────────────
lake_sql_saved() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls)           lake_sql_saved_list "$@" ;;
    create)            lake_sql_saved_create "$@" ;;
    run)               lake_sql_saved_run "$@" ;;
    delete|remove|rm)  lake_sql_saved_delete "$@" ;;
    help|*)            echo "Usage: devskin lake sql saved {list|create|run|delete}" ;;
  esac
}

lake_sql_saved_list() {
  _require_auth
  local body data
  body=$(_api_get "/lakehouse/sql/saved")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Saved Queries${NC}"
  echo ""
  echo "$data" | _format_table id name scheduleCron lastRunAt
}

lake_sql_saved_create() {
  _require_auth
  local name query_file schedule description
  name=$(_parse_flag "--name" "$@")
  query_file=$(_parse_flag "--query" "$@")
  schedule=$(_parse_flag "--schedule" "$@")
  description=$(_parse_flag "--description" "$@")

  _require_arg "--name" "$name"
  _require_arg "--query" "$query_file"
  [[ -f "$query_file" ]] || _fatal "Query file not found: ${query_file}"

  local query_json
  if _has_jq; then
    query_json=$(jq -Rs . < "$query_file")
  else
    _fatal "jq is required to encode the query file. Please install jq."
  fi

  local payload="{\"name\":\"${name}\",\"query\":${query_json}"
  [[ -n "$schedule" ]]    && payload+=",\"scheduleCron\":\"${schedule}\""
  [[ -n "$description" ]] && payload+=",\"description\":\"${description}\""
  payload+="}"

  _info "Saving query ${BOLD}${name}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/sql/saved" "$payload")
  data=$(_extract_data "$body")
  _success "Query saved."
  echo ""
  echo "  ID:       $(echo "$data" | _json_get '.id')"
  echo "  Name:     $(echo "$data" | _json_get '.name')"
  echo "  Schedule: $(echo "$data" | _json_get '.scheduleCron')"
}

lake_sql_saved_run() {
  _require_auth
  local id="${1:-}"
  _require_arg "ID" "$id"
  _info "Running saved query ${BOLD}${id}${NC} ..."
  local body data
  body=$(_api_post "/lakehouse/sql/saved/${id}/run" "{}")
  data=$(_extract_data "$body")
  _success "Run started."
  echo "  Query ID: $(echo "$data" | _json_get '.queryId')"
  echo "  Status:   $(echo "$data" | _json_get '.status')"
}

lake_sql_saved_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "ID" "$id"
  _info "Deleting saved query ${BOLD}${id}${NC} ..."
  _api_delete "/lakehouse/sql/saved/${id}" >/dev/null
  _success "Saved query deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                       OUTPUT FORMAT HELPERS
# ════════════════════════════════════════════════════════════════════════════

OUTPUT_FORMAT="${DEVSKIN_OUTPUT:-table}"

# Check for --json or --output flags anywhere in args
_check_output_format() {
  for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
      OUTPUT_FORMAT="json"
      return
    fi
  done
}

# ════════════════════════════════════════════════════════════════════════════
#                         FLEX COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_flex() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list)       flex_list "$@" ;;
    create)     flex_create "$@" ;;
    deploy)     flex_deploy "$@" ;;
    logs)       flex_logs "$@" ;;
    scale)      flex_scale "$@" ;;
    delete)     flex_delete "$@" ;;
    info|get|show) flex_info "$@" ;;
    env)        flex_env "$@" ;;
    help|*)     flex_help ;;
  esac
}

flex_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin flex <subcommand> [options]

${BOLD}Subcommands:${NC}
  list                              List all Flex services
  create --name NAME --source-type TYPE [--source-repo-url URL] [--source-branch BR] [--source-image IMG] [--port P] [--cpu N] [--memory MB] [--min N] [--max N]
                                    Create a new Flex service
  info ID                           Show Flex service details
  deploy ID [--source-image IMG]    Trigger a new deploy
  logs ID [--tail 200]              Fetch service logs
  scale ID --min N --max M [--concurrency K]
                                    Change scaling limits
  env ID --set KEY=VALUE [--set ...]
                                    Update environment variables
  delete ID                         Delete a Flex service
EOF
}

flex_list() {
  _require_auth
  local body
  body=$(_api_get "/flex/services")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Flex Services${NC}"
  echo ""
  echo "$data" | _format_table id name status sourceType url minInstances maxInstances
}

flex_create() {
  _require_auth
  local name source_type source_repo_url source_branch source_image port cpu memory min_instances max_instances concurrency
  name=$(_parse_flag "--name" "$@")
  source_type=$(_parse_flag "--source-type" "$@")
  source_repo_url=$(_parse_flag "--source-repo-url" "$@")
  source_branch=$(_parse_flag "--source-branch" "$@")
  source_image=$(_parse_flag "--source-image" "$@")
  port=$(_parse_flag "--port" "$@")
  cpu=$(_parse_flag "--cpu" "$@")
  memory=$(_parse_flag "--memory" "$@")
  min_instances=$(_parse_flag "--min" "$@")
  max_instances=$(_parse_flag "--max" "$@")
  concurrency=$(_parse_flag "--concurrency" "$@")

  _require_arg "--name" "$name"
  _require_arg "--source-type" "$source_type"

  local payload="{\"name\":\"${name}\",\"sourceType\":\"${source_type}\""
  [[ -n "$source_repo_url" ]] && payload="${payload},\"sourceRepoUrl\":\"${source_repo_url}\""
  [[ -n "$source_branch" ]]   && payload="${payload},\"sourceBranch\":\"${source_branch}\""
  [[ -n "$source_image" ]]    && payload="${payload},\"sourceImage\":\"${source_image}\""
  [[ -n "$port" ]]            && payload="${payload},\"port\":${port}"
  [[ -n "$cpu" ]]             && payload="${payload},\"cpu\":${cpu}"
  [[ -n "$memory" ]]          && payload="${payload},\"memory\":${memory}"
  [[ -n "$min_instances" ]]   && payload="${payload},\"minInstances\":${min_instances}"
  [[ -n "$max_instances" ]]   && payload="${payload},\"maxInstances\":${max_instances}"
  [[ -n "$concurrency" ]]     && payload="${payload},\"concurrency\":${concurrency}"
  payload="${payload}}"

  _info "Creating Flex service ${BOLD}${name}${NC} ..."
  local body
  body=$(_api_post "/flex/services" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Flex service created."
  echo ""
  echo "  ID:     $(echo "$data" | _json_get '.id')"
  echo "  Name:   $(echo "$data" | _json_get '.name')"
  echo "  Status: $(echo "$data" | _json_get '.status')"
  echo "  URL:    $(echo "$data" | _json_get '.url')"
}

flex_info() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"

  local body
  body=$(_api_get "/flex/services/${id}")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}Flex Service Details${NC}"
  echo ""
  echo "  ID:               $(echo "$data" | _json_get '.id')"
  echo "  Name:             $(echo "$data" | _json_get '.name')"
  echo "  Status:           $(echo "$data" | _json_get '.status')"
  echo "  Region:           $(echo "$data" | _json_get '.region')"
  echo "  URL:              $(echo "$data" | _json_get '.url')"
  echo "  Source Type:      $(echo "$data" | _json_get '.sourceType')"
  echo "  Source Repo:      $(echo "$data" | _json_get '.sourceRepoUrl')"
  echo "  Source Branch:    $(echo "$data" | _json_get '.sourceBranch')"
  echo "  Source Image:     $(echo "$data" | _json_get '.sourceImage')"
  echo "  Port:             $(echo "$data" | _json_get '.port')"
  echo "  CPU:              $(echo "$data" | _json_get '.cpu')"
  echo "  Memory (MB):      $(echo "$data" | _json_get '.memory')"
  echo "  Min Instances:    $(echo "$data" | _json_get '.minInstances')"
  echo "  Max Instances:    $(echo "$data" | _json_get '.maxInstances')"
  echo "  Concurrency:      $(echo "$data" | _json_get '.concurrency')"
  echo "  Autoscaling:      $(echo "$data" | _json_get '.autoscalingEnabled')"
  echo "  Service Mode:     $(echo "$data" | _json_get '.serviceMode')"
  echo "  Created:          $(echo "$data" | _json_get '.createdAt')"
}

flex_deploy() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"
  shift 2>/dev/null || true

  local source_image source_type source_repo_url
  source_image=$(_parse_flag "--source-image" "$@")
  source_type=$(_parse_flag "--source-type" "$@")
  source_repo_url=$(_parse_flag "--source-repo-url" "$@")

  local payload="{"
  local first=1
  if [[ -n "$source_type" ]]; then
    payload="${payload}\"sourceType\":\"${source_type}\""
    first=0
  fi
  if [[ -n "$source_repo_url" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"sourceRepoUrl\":\"${source_repo_url}\""
    first=0
  fi
  if [[ -n "$source_image" ]]; then
    [[ $first -eq 0 ]] && payload="${payload},"
    payload="${payload}\"sourceImage\":\"${source_image}\""
    first=0
  fi
  payload="${payload}}"

  _info "Triggering deploy for Flex service ${BOLD}${id}${NC} ..."
  local body
  body=$(_api_post "/flex/services/${id}/deploy" "$payload")
  local data
  data=$(_extract_data "$body")

  _success "Deploy triggered."
  echo ""
  echo "  Status:   $(echo "$data" | _json_get '.status')"
  echo "  Revision: $(echo "$data" | _json_get '.id')"
}

flex_logs() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"
  shift 2>/dev/null || true

  local tail
  tail=$(_parse_flag "--tail" "$@")
  tail="${tail:-200}"

  _info "Fetching logs for Flex service ${BOLD}${id}${NC} (tail=${tail}) ..."
  local body
  body=$(_api_get "/flex/services/${id}/logs?tail=${tail}")
  local data
  data=$(_extract_data "$body")
  echo "$data" | _json_pretty
}

flex_scale() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"
  shift 2>/dev/null || true

  local min max concurrency
  min=$(_parse_flag "--min" "$@")
  max=$(_parse_flag "--max" "$@")
  concurrency=$(_parse_flag "--concurrency" "$@")

  _require_arg "--min" "$min"
  _require_arg "--max" "$max"

  local payload="{\"minInstances\":${min},\"maxInstances\":${max}"
  [[ -n "$concurrency" ]] && payload="${payload},\"concurrency\":${concurrency}"
  payload="${payload}}"

  _info "Scaling Flex service ${BOLD}${id}${NC} (min=${min}, max=${max}) ..."
  _api_patch "/flex/services/${id}/scale" "$payload" >/dev/null
  _success "Flex service scaled."
}

flex_env() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"
  shift 2>/dev/null || true

  # Collect all --set KEY=VALUE pairs
  local env_json=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--set" && $# -ge 2 ]]; then
      local kv="$2"
      local key="${kv%%=*}"
      local value="${kv#*=}"
      if [[ -z "$key" || "$key" == "$kv" ]]; then
        _fatal "Invalid --set value. Expected KEY=VALUE, got: ${kv}"
      fi
      # Escape double quotes and backslashes in value
      value="${value//\\/\\\\}"
      value="${value//\"/\\\"}"
      if [[ -n "$env_json" ]]; then
        env_json="${env_json},"
      fi
      env_json="${env_json}\"${key}\":\"${value}\""
      shift 2
    else
      shift
    fi
  done

  if [[ -z "$env_json" ]]; then
    _fatal "No environment variables provided. Use ${BOLD}--set KEY=VALUE${NC} (repeatable)."
  fi

  local payload="{\"envVars\":{${env_json}}}"

  _info "Updating environment variables for Flex service ${BOLD}${id}${NC} ..."
  _api_patch "/flex/services/${id}/env" "$payload" >/dev/null
  _success "Flex service environment updated."
}

flex_delete() {
  _require_auth
  local id="${1:-}"
  _require_arg "FLEX_SERVICE_ID" "$id"

  read -rp "Are you sure you want to delete Flex service ${id}? [y/N] " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    return
  fi

  _info "Deleting Flex service ${BOLD}${id}${NC} ..."
  _api_delete "/flex/services/${id}" >/dev/null
  _success "Flex service ${id} deleted."
}

# ════════════════════════════════════════════════════════════════════════════
#                          MAIN HELP
# ════════════════════════════════════════════════════════════════════════════

show_help() {
  cat <<EOF

${BOLD}DevskinCloud CLI v${VERSION}${NC}
Manage your cloud infrastructure from the command line.

${BOLD}Usage:${NC} devskin <command> [subcommand] [options]

${BOLD}General:${NC}
  configure              Set API URL and authentication token
  login                  Authenticate with email and password
  logout                 Remove saved token
  whoami                 Show current authenticated user
  version                Show CLI version

${BOLD}Compute:${NC}
  compute list           List instances
  compute create         Create instance  (--name, --type, --image)
  compute get ID         Show instance details
  compute start ID       Start instance
  compute stop ID        Stop instance
  compute reboot ID      Reboot instance
  compute terminate ID   Terminate instance
  compute ssh ID         SSH into instance

${BOLD}Database:${NC}
  db list                List databases
  db create              Create database  (--name, --engine, --class, --storage)
  db get ID              Show database details
  db start|stop|reboot   Manage database state
  db delete ID           Delete database
  db snapshot ID         Create snapshot  (--name)

${BOLD}Storage:${NC}
  storage list           List buckets
  storage create         Create bucket    (--name)
  storage get ID         Show bucket details
  storage delete ID      Delete bucket

${BOLD}Volumes:${NC}
  volume list            List volumes
  volume create          Create volume    (--name, --size, --type)
  volume get ID          Show volume details
  volume attach V_ID I_ID  Attach volume to instance
  volume detach V_ID     Detach volume
  volume delete ID       Delete volume

${BOLD}Snapshots:${NC}
  snapshot list          List snapshots
  snapshot create        Create snapshot  (--volume, --name)
  snapshot delete ID     Delete snapshot

${BOLD}Images:${NC}
  image list             List images
  image get ID           Show image details

${BOLD}Networking:${NC}
  vpc list               List VPCs
  vpc create             Create VPC       (--name, --cidr)
  vpc delete ID          Delete VPC
  subnet list            List subnets
  subnet create          Create subnet    (--name, --vpc, --cidr)
  subnet delete ID       Delete subnet
  elastic-ip list        List elastic IPs
  elastic-ip allocate    Allocate elastic IP
  elastic-ip release ID  Release elastic IP
  elastic-ip associate   Associate elastic IP
  elastic-ip disassociate  Disassociate elastic IP
  sg list                List security groups
  sg create              Create security group  (--name, --vpc)
  sg delete ID           Delete security group
  lb list                List load balancers
  lb create              Create load balancer   (--name, --type)
  lb delete ID           Delete load balancer

${BOLD}CDN:${NC}
  cdn list               List distributions
  cdn create             Create distribution   (--origin)
  cdn delete ID          Delete distribution
  cdn invalidate ID      Invalidate cache      (--paths)
  cdn toggle ID          Enable/disable distribution

${BOLD}Functions:${NC}
  function list          List functions
  function create        Create function  (--name, --runtime)
  function get ID        Show function details
  function invoke ID     Invoke function  (--payload)
  function delete ID     Delete function

${BOLD}Kubernetes:${NC}
  k8s list               List clusters
  k8s create             Create cluster   (--name, --version, [--nodes, --region, --vpc-id])
  k8s get ID             Show cluster details
  k8s delete ID          Delete cluster
  k8s namespace-costs ID Per-namespace cost breakdown (use --all for cross-cluster)
  k8s optimize list      List optimization recommendations
  k8s optimize show ID   Show recommendation detail
  k8s optimize apply ID  Apply recommendation (modifies the cluster)
  k8s optimize dismiss ID  Dismiss a recommendation
  k8s optimize savings   Aggregated savings + top 10
  k8s optimize scan      Admin: trigger a fresh analyzer pass

${BOLD}DNS:${NC}
  dns list               List hosted zones
  dns create             Create zone      (--name)
  dns get ID             Show zone details
  dns delete ID          Delete zone
  dns records ZONE_ID    List records
  dns add-record ZONE_ID Add record       (--name, --type, --value)
  dns del-record Z_ID R_ID  Delete record

${BOLD}Monitoring:${NC}
  alarm list             List alarms
  alarm create           Create alarm     (--name, --metric, --threshold)
  alarm get ID           Show alarm details
  alarm toggle ID        Toggle alarm
  alarm delete ID        Delete alarm
  log list               List log groups
  log create             Create log group (--name)
  log delete ID          Delete log group
  log export ID          Export logs       (--from, --to)

${BOLD}Security:${NC}
  cert list              List certificates
  cert request           Request certificate  (--domain)
  cert get ID            Show certificate details
  cert renew ID          Renew certificate
  cert delete ID         Delete certificate
  keypair list           List key pairs
  keypair create         Create key pair  (--name)
  keypair delete ID      Delete key pair

${BOLD}IAM:${NC}
  iam users list         List IAM users
  iam users create       Create IAM user  (--name, --email)
  iam users delete ID    Delete IAM user
  iam groups list        List IAM groups
  iam groups create      Create IAM group (--name)
  iam groups delete ID   Delete IAM group
  iam roles list         List IAM roles
  iam roles create       Create IAM role  (--name)
  iam roles delete ID    Delete IAM role
  iam policies list      List IAM policies
  iam policies create    Create policy    (--name)
  iam policies delete ID Delete policy

${BOLD}Containers (ECS):${NC}
  container list         List container services
  container create       Create service   (--name, --image)
  container get ID       Show service details
  container delete ID    Delete service
  container deploy ID    Deploy/update service
  container restart ID   Restart service

${BOLD}Container Clusters:${NC}
  container-cluster list         List container clusters
  container-cluster create       Create cluster   (--name, --vpc-id)
  container-cluster get ID       Show cluster details
  container-cluster delete ID    Delete cluster

${BOLD}Task Definitions:${NC}
  task-def list          List task definitions
  task-def create        Create task def  (--family, --image, [--cpu, --memory, --container-port, --host-port, --protocol])
  task-def get ID        Show task definition details
  task-def delete ID     Delete task definition

${BOLD}Flex (Managed Apps):${NC}
  flex list              List Flex services
  flex create            Create Flex service  (--name, --source-type, [--source-repo-url, --source-branch, --source-image, --port, --cpu, --memory, --min, --max])
  flex info ID           Show Flex service details
  flex deploy ID         Trigger a new deploy   ([--source-image])
  flex logs ID           Fetch service logs     ([--tail])
  flex scale ID          Change scaling limits  (--min, --max, [--concurrency])
  flex env ID            Update env vars        (--set KEY=VALUE ...)
  flex delete ID         Delete Flex service

${BOLD}CI/CD:${NC}
  cicd pipelines list    List pipelines
  cicd pipelines create  Create pipeline  (--name, --repo)
  cicd pipelines get ID  Show pipeline details
  cicd trigger ID        Trigger pipeline
  cicd logs ID           Get pipeline logs
  cicd builds list       List builds
  cicd deployments list  List deployments

${BOLD}Git:${NC}
  git repos list         List repositories
  git repos create       Create repo      (--name)
  git repos get ID       Show repo details
  git repos delete ID    Delete repo
  git branches ID        List branches
  git commits ID         List commits
  git credentials        Show Git credentials

${BOLD}Messaging:${NC}
  sqs list               List SQS queues
  sqs create             Create queue     (--name)
  sqs send ID            Send message     (--body)
  sqs receive ID         Receive messages
  sqs delete ID          Delete queue
  sns list               List SNS topics
  sns create             Create topic     (--name)
  sns publish ID         Publish message  (--message)
  sns delete ID          Delete topic
  eventbridge buses list List event buses
  eventbridge rules list List event rules

${BOLD}NoSQL & Cache:${NC}
  dynamodb list          List DynamoDB tables
  dynamodb create        Create table     (--name, --pk)
  dynamodb get ID        Show table details
  dynamodb items ID      List items
  dynamodb delete ID     Delete table
  mongodb list           List MongoDB clusters
  mongodb create         Create cluster   (--name)
  mongodb delete ID      Delete cluster
  redis list             List Redis clusters
  redis create           Create cluster   (--name)
  redis delete ID        Delete cluster

${BOLD}Storage Services:${NC}
  efs list               List EFS file systems
  efs create             Create file system (--name)
  efs delete ID          Delete file system
  glacier list           List Glacier vaults
  glacier create         Create vault     (--name)
  glacier delete ID      Delete vault

${BOLD}Artifacts & Registry:${NC}
  artifacts list         List artifact repositories
  artifacts create       Create repo      (--name, --format)
  artifacts packages ID  List packages
  registry list          List container registry repos
  registry create        Create repo      (--name)
  registry images ID     List images

${BOLD}API Gateway:${NC}
  api-gateway list       List API gateways
  api-gateway create     Create gateway   (--name)
  api-gateway deploy ID  Deploy gateway
  api-gateway delete ID  Delete gateway

${BOLD}Secrets Manager:${NC}
  secrets list           List secrets
  secrets create         Create secret    (--name, --value)
  secrets value ID       Get secret value
  secrets rotate ID      Rotate secret
  secrets delete ID      Delete secret

${BOLD}Auto Scaling:${NC}
  autoscaling list       List auto scaling groups
  autoscaling create     Create group     (--name, --min, --max, --desired)
  autoscaling delete ID  Delete group

${BOLD}K8s Pods & Services:${NC}
  pod list               List pods        [--namespace NS]
  pod get ID             Show pod details
  pod logs ID            Get pod logs     [--tail N]
  pod delete ID          Delete pod
  k8s-svc list           List K8s services [--namespace NS]
  k8s-svc create         Create service   (--name)
  k8s-svc delete ID      Delete service

${BOLD}Support:${NC}
  support list           List tickets
  support create         Create ticket    (--subject, --body)
  support get ID         Show ticket details
  support reply ID       Reply to ticket  (--body)
  support close ID       Close ticket

${BOLD}Marketplace:${NC}
  marketplace list       List products
  marketplace get ID     Show product details
  marketplace subscribe ID    Subscribe
  marketplace unsubscribe ID  Unsubscribe

${BOLD}Consumption:${NC}
  consumption summary    Usage summary
  consumption trends     Cost trends
  consumption forecast   Cost forecast
  consumption prices     Service prices

${BOLD}AI Services:${NC}
  ai models              List AI models (OpenAI GPT-5.x, Claude 4.x)
  ai chat                Chat with AI            (--model, --message)
  ai image               Generate image          (--prompt, --model, --size, --quality, --n)
  ai speak               Synthesize speech (TTS) (--text, --voice, --format)
  ai transcribe          Transcribe audio (STT)  (--file, --language)
  ai embed               Create embeddings       (--text, --model)
  ai kb list             List Knowledge Bases (RAG)
  ai kb create           Create a Knowledge Base (--name, --description)
  ai kb add              Ingest a doc            (--id, --file)
  ai kb query            RAG query               (--id, --query, --top-k)
  ai kb delete           Delete a Knowledge Base (--id)
  ai usage               Show AI usage stats
  ai guardrails show     Show org guardrail policy
  ai guardrails enable   Enable guardrails
  ai guardrails disable  Disable guardrails
  ai guardrails test     Dry-run text against the policy (--text "...")
  ai eval list           List evaluations
  ai eval run            Run an evaluation matrix (--json '{...}')
  ai eval show           Show an evaluation (--id ID)
  ai eval delete         Delete an evaluation (--id ID)

${BOLD}Lakehouse (DevskinLake):${NC}
  lake catalog list             List Lakehouse databases
  lake catalog create NAME      Create database (--description, --bucket)
  lake catalog tables DB_ID     List tables in a database
  lake catalog optimize T_ID    Run Iceberg OPTIMIZE on a table
  lake catalog optimize-schedule T_ID --schedule @daily
                                Set/clear the optimize schedule
  lake catalog row-filters T_ID --add ROLE:PREDICATE | --clear
  lake catalog column-masks T_ID --add COL:ROLE:hash|redact|partial | --clear
  lake catalog mv list DB_ID    List materialized views
  lake catalog mv create DB_ID  Create MV (--name, --query, --schedule)
  lake catalog mv refresh MV_ID Refresh a materialized view
  lake catalog mv delete MV_ID  Delete a materialized view
  lake sql run "QUERY"          Submit a SQL query and poll until done
  lake sql list                 List recent SQL queries
  lake sql ask "QUESTION"       Genie NL->SQL (--database, --run)
  lake sql saved list           List saved queries
  lake sql saved create         Save a query (--name, --query FILE, --schedule)
  lake sql saved run ID         Run a saved query
  lake sql saved delete ID      Delete a saved query
  lake spark list               List Spark jobs
  lake spark create             Create Spark job (--name, --code FILE, --language)
  lake spark run JOB_ID         Trigger a Spark job run
  lake notebook list            List notebooks
  lake notebook create          Create notebook (--name, --kernel)
  lake notebook start ID        Start notebook pod (prints URL)
  lake kafka list               List Kafka clusters
  lake kafka create             Create Kafka cluster (--name)
  lake kafka topic CLUSTER_ID   Create topic (--name, --partitions, --replication)
  lake airflow list             List Airflow DAGs
  lake airflow upload           Upload DAG (--name, --code FILE, --schedule)
  lake airflow trigger DAG_ID   Trigger a DAG run
  lake lineage                  Show data lineage graph
  lake quality list             List data-quality rules
  lake quality create           Create rule (--name, --expectations FILE)
  lake admin status             Show health of the Lakehouse stack
  lake admin deploy             Deploy/upgrade the entire Lakehouse stack
  lake admin cost               Cost summary (current vs previous month per area)
  lake admin warehouse          Trino warehouse status (workers/queries)

${BOLD}Billing:${NC}
  billing subscription   Show subscription
  billing usage          Show usage
  billing invoices       List invoices

${BOLD}Admin:${NC}
  zone list              List infrastructure zones
  zone create            Create zone      (--slug, --name)
  zone get ID            Show zone details
  zone delete ID         Delete zone

${BOLD}Settings:${NC}
  apikey list            List API keys
  apikey create          Create API key   (--name)
  apikey delete ID       Delete API key
  apikey regenerate ID   Regenerate API key

${BOLD}Global Options:${NC}
  --json                 Output raw JSON instead of tables
  --help, -h             Show help for any command

${BOLD}Environment Variables:${NC}
  DEVSKIN_API_URL        Override the API base URL
  DEVSKIN_OUTPUT         Default output format (table|json)

${BOLD}Examples:${NC}
  devskin configure
  devskin compute list
  devskin compute create --name web-1 --type t3.micro --image ami-ubuntu-22
  devskin compute ssh i-12345
  devskin db create --name mydb --engine postgres --class db.t3.micro --storage 20
  devskin volume create --name data-vol --size 100 --type gp3
  devskin cert request --domain example.com --sans "*.example.com"
  devskin container list
  devskin cicd pipelines list
  devskin git repos list
  devskin sqs list
  devskin secrets list
  devskin pod list --namespace default
  devskin ai models

EOF
}

# ════════════════════════════════════════════════════════════════════════════
#                          ADMIN COMMANDS
# ════════════════════════════════════════════════════════════════════════════

cmd_admin() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    delinquent-orgs|delinquent) admin_delinquent_orgs "$@" ;;
    help|*)
      cat <<EOF
${BOLD}Usage:${NC} devskin admin <subcommand> [options]

${BOLD}Subcommands:${NC}
  delinquent-orgs                   List orgs with at least one OPEN invoice past dueDate
                                    (requires platform admin auth)
EOF
      ;;
  esac
}

admin_delinquent_orgs() {
  _require_auth
  local body data
  body=$(_api_get "/admin/delinquent-orgs")
  data=$(_extract_data "$body")
  echo -e "${BOLD}Delinquent Organizations${NC}"
  echo ""
  echo "$data" | _format_table organizationId name overdueInvoices oldestOverdueDays totalOutstanding currency
}

# ════════════════════════════════════════════════════════════════════════════
#                          MAIN DISPATCHER
# ════════════════════════════════════════════════════════════════════════════

main() {
  # Check global output format
  _check_output_format "$@"

  # Strip --json from arguments
  local args=()
  for arg in "$@"; do
    [[ "$arg" != "--json" ]] && args+=("$arg")
  done
  set -- "${args[@]}"

  local command="${1:-help}"
  shift 2>/dev/null || true

  case "$command" in
    configure)           cmd_configure "$@" ;;
    login)               cmd_login "$@" ;;
    logout)              cmd_logout "$@" ;;
    whoami)              cmd_whoami "$@" ;;

    compute|ec2)         cmd_compute "$@" ;;
    db|database|rds)     cmd_db "$@" ;;
    storage|s3)          cmd_storage "$@" ;;
    volume|vol)          cmd_volume "$@" ;;
    snapshot|snap)       cmd_snapshot "$@" ;;
    image|ami)           cmd_image "$@" ;;

    vpc)                 cmd_vpc "$@" ;;
    subnet)              cmd_subnet "$@" ;;
    elastic-ip|eip)      cmd_elastic_ip "$@" ;;
    sg|security-group)   cmd_sg "$@" ;;
    lb|load-balancer)    cmd_lb "$@" ;;

    cdn|cloudfront)      cmd_cdn "$@" ;;
    function|lambda|fn)  cmd_function "$@" ;;
    k8s|kubernetes|eks)  cmd_k8s "$@" ;;
    k8s-deploy)          cmd_k8s_deploy "$@" ;;

    dns|route53)         cmd_dns "$@" ;;
    alarm|alarms)        cmd_alarm "$@" ;;
    log|logs)            cmd_log "$@" ;;

    cert|certificate)    cmd_cert "$@" ;;
    keypair|key-pair)    cmd_keypair "$@" ;;
    iam)                 cmd_iam "$@" ;;

    zone|zones)          cmd_zone "$@" ;;
    billing)             cmd_billing "$@" ;;
    apikey|api-key)      cmd_apikey "$@" ;;

    # New service commands
    container|containers|ecs)    cmd_container "$@" ;;
    container-cluster)           cmd_container_cluster "$@" ;;
    task-def|task-definition)    cmd_task_def "$@" ;;
    flex)                        cmd_flex "$@" ;;
    cicd|pipeline|pipelines)     cmd_cicd "$@" ;;
    git|gitea)                   cmd_git "$@" ;;
    sqs|queue|queues)            cmd_sqs "$@" ;;
    sns|topic|topics)            cmd_sns "$@" ;;
    eventbridge|eb)              cmd_eventbridge "$@" ;;
    dynamodb|dynamo)             cmd_dynamodb "$@" ;;
    mongodb|mongo)               cmd_mongodb "$@" ;;
    redis|elasticache)           cmd_redis "$@" ;;
    efs)                         cmd_efs "$@" ;;
    glacier)                     cmd_glacier "$@" ;;
    artifacts|artifact)          cmd_artifacts "$@" ;;
    registry|ecr)                cmd_registry "$@" ;;
    api-gateway|apigw)           cmd_apigateway "$@" ;;
    secrets|secret)              cmd_secrets "$@" ;;
    support|ticket|tickets)      cmd_support "$@" ;;
    marketplace)                 cmd_marketplace "$@" ;;
    autoscaling|asg)             cmd_autoscaling "$@" ;;
    pod|pods)                    cmd_pod "$@" ;;
    k8s-svc|k8s-service)        cmd_k8s_svc "$@" ;;
    consumption|cost)            cmd_consumption "$@" ;;
    ai)                          cmd_ai "$@" ;;
    lake|lakehouse|devskinlake)  cmd_lake "$@" ;;
    admin)                       cmd_admin "$@" ;;

    version|--version|-v)
      echo "devskin v${VERSION}"
      ;;

    help|--help|-h)
      show_help
      ;;

    *)
      _error "Unknown command: ${command}"
      echo ""
      echo "Run 'devskin --help' for usage information."
      exit 1
      ;;
  esac
}

main "$@"
