#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

TUNNEL_VERSION="v0.0.10"
BIN_DIR="$SCRIPT_DIR/bin"
TUNNEL_BIN="$BIN_DIR/tunnel-client"
PROFILE_FILE="$SCRIPT_DIR/profiles/codex-local.yaml"
port=""
health_port=""
action="run"
force=0

usage() {
  cat <<'USAGE'
Usage: ./openai-tunnel.sh [options]

Options:
  --init                 First-time setup: save credentials, install client, run doctor
  --install              Install the pinned OpenAI tunnel-client only
  --doctor               Run tunnel-client doctor against the generated profile
  --port PORT            Local MCP server port (default: .env PORT, then 3000)
  --health-port PORT     tunnel-client health/Admin UI port (default: 8080)
  --force                Restart an existing tunnel listener on the health port
  -h, --help             Show this help
USAGE
}

while (($#)); do
  case "$1" in
    --init) action=init; shift ;;
    --install) action=install; shift ;;
    --doctor) action=doctor; shift ;;
    --port) [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }; port=$2; shift 2 ;;
    --health-port) [[ $# -ge 2 ]] || { echo "--health-port requires a value" >&2; exit 2; }; health_port=$2; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

get_env_value() {
  local key=$1 line value
  [[ -f .env ]] || return 0
  line=$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" .env || true)
  [[ -n $line ]] || return 0
  value=${line#*=}
  value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
  printf '%s' "$value"
}

set_env_value() {
  local key=$1 value=$2 tmp
  [[ -f .env ]] || cp .env.example .env
  tmp=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" && $0 !~ "^[[:space:]]*#" {
      print key "=" value; found = 1; next
    }
    { print }
    END { if (!found) print key "=" value }
  ' .env > "$tmp"
  mv "$tmp" .env
}

download() {
  local url=$1 out=$2
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$out" "$url"
  else echo "curl or wget is required" >&2; exit 1; fi
}

archive_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "tunnel-client-${TUNNEL_VERSION}-linux-amd64.zip" ;;
    aarch64|arm64) echo "tunnel-client-${TUNNEL_VERSION}-linux-arm64.zip" ;;
    *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

install_tunnel_client() {
  [[ ! -x $TUNNEL_BIN ]] || { echo "tunnel-client already installed: $TUNNEL_BIN"; return 0; }
  local archive base tmp expected actual extracted
  archive=$(archive_name)
  base="https://github.com/openai/tunnel-client/releases/download/${TUNNEL_VERSION}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  echo "Downloading tunnel-client $TUNNEL_VERSION ($archive)..."
  download "$base/$archive" "$tmp/$archive"
  download "$base/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt"
  expected=$(awk -v name="$archive" '$2 == name {print $1; exit}' "$tmp/SHA256SUMS.txt")
  [[ -n $expected ]] || { echo "Checksum for $archive not found" >&2; exit 1; }
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
  else echo "sha256sum or shasum is required" >&2; exit 1; fi
  [[ $actual == "$expected" ]] || { echo "Checksum verification failed for $archive" >&2; exit 1; }
  mkdir -p "$tmp/extracted"
  if command -v unzip >/dev/null 2>&1; then unzip -q "$tmp/$archive" -d "$tmp/extracted"
  elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e "$tmp/$archive" "$tmp/extracted"
  else echo "unzip or python3 is required" >&2; exit 1; fi
  extracted=$(find "$tmp/extracted" -type f -name tunnel-client -print -quit)
  [[ -n $extracted ]] || { echo "tunnel-client binary not found in archive" >&2; exit 1; }
  mkdir -p "$BIN_DIR"
  cp "$extracted" "$TUNNEL_BIN"
  chmod 0755 "$TUNNEL_BIN"
  echo "Installed: $TUNNEL_BIN"
}

get_tunnel_bin() {
  if [[ -x $TUNNEL_BIN ]]; then printf '%s' "$TUNNEL_BIN"
  elif command -v tunnel-client >/dev/null 2>&1; then command -v tunnel-client
  else install_tunnel_client >&2; printf '%s' "$TUNNEL_BIN"; fi
}

port_pids() {
  local target=$1
  if command -v lsof >/dev/null 2>&1; then lsof -nP -tiTCP:"$target" -sTCP:LISTEN 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then fuser -n tcp "$target" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true
  elif command -v ss >/dev/null 2>&1; then ss -ltnp "sport = :$target" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
  fi
}

http_ok() {
  local url=$1
  if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 3 "$url" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then wget -q --timeout=3 -O /dev/null "$url" >/dev/null 2>&1
  else return 1; fi
}

resolve_settings() {
  [[ -n $port ]] || port="${PORT:-$(get_env_value PORT)}"; port=${port:-3000}
  [[ -n $health_port ]] || health_port="${OPENAI_TUNNEL_HEALTH_PORT:-$(get_env_value OPENAI_TUNNEL_HEALTH_PORT)}"; health_port=${health_port:-8080}
}

build_mcp_url() {
  local token="${MCP_TOKEN:-$(get_env_value MCP_TOKEN)}"
  if [[ -n $token ]]; then printf 'http://127.0.0.1:%s/mcp/%s' "$port" "$token"
  else printf 'http://127.0.0.1:%s/mcp' "$port"; fi
}

ensure_profile() {
  local tunnel_id=$1 mcp_url=$2
  mkdir -p "$(dirname "$PROFILE_FILE")"
  cat > "$PROFILE_FILE" <<EOF
config_version: 1
control_plane:
  tunnel_id: $tunnel_id
  api_key: env:OPENAI_TUNNEL_API_KEY
log:
  level: info
  format: struct-text
health:
  listen_addr: 127.0.0.1:$health_port
mcp:
  server_urls:
    - channel: main
      url: $mcp_url
EOF
}

resolve_settings
if [[ $action == install ]]; then install_tunnel_client; exit 0; fi

if [[ $action == init ]]; then
  [[ -f .env ]] || cp .env.example .env
  tunnel_id=$(get_env_value OPENAI_TUNNEL_ID)
  api_key=$(get_env_value OPENAI_TUNNEL_API_KEY)
  echo "OpenAI Secure MCP Tunnel setup"
  echo "Credentials: https://platform.openai.com/settings/organization/tunnels"
  [[ -n $tunnel_id ]] || read -r -p "OPENAI_TUNNEL_ID (tunnel_...): " tunnel_id
  if [[ -z $api_key ]]; then read -r -s -p "OPENAI_TUNNEL_API_KEY: " api_key; echo; fi
  [[ $tunnel_id =~ ^tunnel_[0-9a-f]{32}$ ]] || { echo "Invalid OPENAI_TUNNEL_ID" >&2; exit 1; }
  [[ -n $api_key ]] || { echo "OPENAI_TUNNEL_API_KEY cannot be empty" >&2; exit 1; }
  set_env_value OPENAI_TUNNEL_ID "$tunnel_id"
  set_env_value OPENAI_TUNNEL_API_KEY "$api_key"
  install_tunnel_client
  mcp_url=$(build_mcp_url)
  ensure_profile "$tunnel_id" "$mcp_url"
  export OPENAI_TUNNEL_API_KEY="$api_key" CONTROL_PLANE_API_KEY="$api_key" CONTROL_PLANE_TUNNEL_ID="$tunnel_id"
  "$TUNNEL_BIN" doctor --profile-file "$PROFILE_FILE" --explain
  echo "Setup complete. Run: bash ./start.sh, then bash ./openai-tunnel.sh"
  exit 0
fi

tunnel_id="${OPENAI_TUNNEL_ID:-$(get_env_value OPENAI_TUNNEL_ID)}"
api_key="${OPENAI_TUNNEL_API_KEY:-$(get_env_value OPENAI_TUNNEL_API_KEY)}"
[[ -n $tunnel_id && -n $api_key ]] || { echo "OpenAI tunnel is not configured. Run: bash ./openai-tunnel.sh --init" >&2; exit 1; }
bin=$(get_tunnel_bin)
mcp_url=$(build_mcp_url)
ensure_profile "$tunnel_id" "$mcp_url"
export OPENAI_TUNNEL_API_KEY="$api_key" CONTROL_PLANE_API_KEY="$api_key" CONTROL_PLANE_TUNNEL_ID="$tunnel_id"

if [[ $action == doctor ]]; then exec "$bin" doctor --profile-file "$PROFILE_FILE" --explain; fi

mapfile -t pids < <(port_pids "$health_port")
if ((${#pids[@]})); then
  if ((force)); then for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; sleep 1
  else echo "Health port $health_port is already in use by PID(s): ${pids[*]}. Use --force or change OPENAI_TUNNEL_HEALTH_PORT." >&2; exit 1; fi
fi

if ! http_ok "http://127.0.0.1:$port/health"; then
  echo "Warning: MCP server is not responding at http://127.0.0.1:$port/health" >&2
  [[ -t 0 ]] || { echo "Start bash ./start.sh first." >&2; exit 1; }
  read -r -p "Start the tunnel anyway? (y/N) " answer
  [[ $answer =~ ^[yY]$ ]] || exit 1
fi

printf '\n=== OpenAI Secure MCP Tunnel ===\n'
echo "Tunnel ID: $tunnel_id"
echo "MCP local: $mcp_url"
echo "Tunnel Admin UI: http://127.0.0.1:$health_port/ui"
echo "Press Ctrl+C to stop."
exec "$bin" run --profile-file "$PROFILE_FILE"
