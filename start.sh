#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

workspace="${WORKSPACE_PATH:-}"
port="${PORT:-}"
force=0
open_ui=0

usage() {
  cat <<'USAGE'
Usage: ./start.sh [options]

Options:
  --workspace PATH   Default project/workspace path (overrides WORKSPACE_PATH)
  --port PORT        MCP server port (default: PORT from .env, then 3000)
  --force            Stop any process already listening on the server port
  --open-ui          Open the local Admin UI with xdg-open
  -h, --help         Show this help
USAGE
}

while (($#)); do
  case "$1" in
    --workspace) [[ $# -ge 2 ]] || { echo "--workspace requires a path" >&2; exit 2; }; workspace=$2; shift 2 ;;
    --port) [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }; port=$2; shift 2 ;;
    --force) force=1; shift ;;
    --open-ui) open_ui=1; shift ;;
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

port_pids() {
  local target=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -tiTCP:"$target" -sTCP:LISTEN 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$target" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$target" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
  fi
}

stop_pid() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$pid" 2>/dev/null || true
}

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example. Edit WORKSPACE_PATH and MCP_TOKEN before exposing the server."
fi

[[ -n $workspace ]] || workspace=$(get_env_value WORKSPACE_PATH)
[[ -n $workspace ]] || workspace=$SCRIPT_DIR
[[ -n $port ]] || port=$(get_env_value PORT)
port=${port:-3000}
admin_port="${ADMIN_PORT:-$(get_env_value ADMIN_PORT)}"; admin_port=${admin_port:-3001}

command -v node >/dev/null 2>&1 || { echo "node is required (Node.js 18+)" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm is required" >&2; exit 1; }

export WORKSPACE_PATH="$workspace" PORT="$port" ADMIN_PORT="$admin_port"
printf '\n=== ChatGPT Local Coder ===\n'
echo "Default cwd: $workspace"
echo "Port: $port"
echo "Admin UI: http://127.0.0.1:${admin_port}/ui"

mapfile -t existing_pids < <(port_pids "$port")
if ((${#existing_pids[@]})); then
  echo "Port $port is already in use by PID(s): ${existing_pids[*]}"
  if ((force)); then
    for pid in "${existing_pids[@]}"; do stop_pid "$pid"; done
  else
    echo "Run again with --force to replace the existing listener." >&2
    exit 1
  fi
fi

[[ -f dist/index.js ]] || npm run build
if ((open_ui)) && command -v xdg-open >/dev/null 2>&1; then (sleep 1; xdg-open "http://127.0.0.1:${admin_port}/ui" >/dev/null 2>&1 || true) & fi
echo "Starting server. Press Ctrl+C to stop."
exec node dist/index.js
