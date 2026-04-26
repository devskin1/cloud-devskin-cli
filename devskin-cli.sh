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
                                    Create a new instance
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
  local name type image keypair vpc subnet sg
  name=$(_parse_flag "--name" "$@")
  type=$(_parse_flag "--type" "$@")
  image=$(_parse_flag "--image" "$@")
  keypair=$(_parse_flag "--keypair" "$@")
  vpc=$(_parse_flag "--vpc" "$@")
  subnet=$(_parse_flag "--subnet" "$@")
  sg=$(_parse_flag "--sg" "$@")

  _require_arg "--name" "$name"
  _require_arg "--type" "$type"
  _require_arg "--image" "$image"

  local payload="{\"name\":\"${name}\",\"instanceType\":\"${type}\",\"imageId\":\"${image}\""
  [[ -n "$keypair" ]] && payload="${payload},\"keyPairId\":\"${keypair}\""
  [[ -n "$vpc" ]]     && payload="${payload},\"vpcId\":\"${vpc}\""
  [[ -n "$subnet" ]]  && payload="${payload},\"subnetId\":\"${subnet}\""
  [[ -n "$sg" ]]      && payload="${payload},\"securityGroupId\":\"${sg}\""
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
    list)       k8s_list "$@" ;;
    create)     k8s_create "$@" ;;
    get|show)   k8s_get "$@" ;;
    oidc)       k8s_oidc "$@" ;;
    delete)     k8s_delete "$@" ;;
    help|*)     k8s_help ;;
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
                                    Create a new cluster
  get ID                            Show cluster details
  oidc ID                           Show the cluster's OIDC issuer + JWKS URL (for IRSA setup)
  delete ID                         Delete a cluster
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

k8s_create() {
  _require_auth
  local name version nodes region vpc_id max_pods cni addons
  name=$(_parse_flag "--name" "$@")
  version=$(_parse_flag "--version" "$@")
  nodes=$(_parse_flag "--nodes" "$@")
  region=$(_parse_flag "--region" "$@")
  vpc_id=$(_parse_flag "--vpc-id" "$@")
  max_pods=$(_parse_flag "--max-pods" "$@")
  cni=$(_parse_flag "--cni" "$@")
  addons=$(_parse_flag "--addons" "$@")

  _require_arg "--name" "$name"
  _require_arg "--version" "$version"

  local payload="{\"name\":\"${name}\",\"version\":\"${version}\""
  [[ -n "$nodes" ]]    && payload="${payload},\"nodeCount\":${nodes}"
  [[ -n "$region" ]]   && payload="${payload},\"region\":\"${region}\""
  [[ -n "$vpc_id" ]]   && payload="${payload},\"vpcId\":\"${vpc_id}\""
  [[ -n "$max_pods" ]] && payload="${payload},\"maxPods\":${max_pods}"
  [[ -n "$cni" ]]      && payload="${payload},\"cni\":\"${cni}\""

  if [[ -n "$addons" ]]; then
    # Build addons object from comma-separated list
    # CLI alias → backend field name
    local addon_map='{"metrics-server":"metricsServer","ingress-nginx":"ingressNginx","cert-manager":"certManager","kyverno":"kyverno","cilium":"cilium","longhorn":"longhorn","velero":"velero","irsa":"irsa","local-path":"localPathStorage"}'
    local addons_json="{"
    local first=1
    IFS=',' read -ra ADDR <<< "$addons"
    for a in "${ADDR[@]}"; do
      a=$(echo "$a" | tr -d '[:space:]')
      local key
      key=$(echo "$addon_map" | _json_get ".[\"$a\"]")
      [[ -z "$key" || "$key" == "null" ]] && key="$a"
      [[ $first -eq 0 ]] && addons_json="${addons_json},"
      addons_json="${addons_json}\"${key}\":true"
      first=0
    done
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
EOF
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
                                    Create a new container service
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
  local source_repo source_branch endpoint_mode lb_id
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
    usage)      ai_usage "$@" ;;
    help|*)     ai_help ;;
  esac
}

ai_help() {
  cat <<EOF
${BOLD}Usage:${NC} devskin ai <subcommand> [options]

${BOLD}Subcommands:${NC}
  models                            List available AI models
  chat --model MODEL --message MSG  Send a chat message
  usage                             Show AI usage stats
EOF
}

ai_models() {
  _require_auth
  local body
  body=$(_api_get "/ai/models")
  local data
  data=$(_extract_data "$body")

  echo -e "${BOLD}AI Models${NC}"
  echo ""
  echo "$data" | _format_table id name provider status
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

ai_usage() {
  _require_auth
  local body
  body=$(_api_get "/ai/usage")
  _extract_data "$body" | _json_pretty
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
  ai models              List AI models
  ai chat                Chat with AI     (--model, --message)
  ai usage               Show AI usage

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
