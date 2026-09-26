#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
port="${PORT:-}"

usage() { printf '%s\n' 'Usage: ./stop.sh [--port PORT]' '' 'Stops the process listening on the ChatGPT Local Coder server port.'; }
while (($#)); do
  case "$1" in
    --port) [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }; port=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
get_env_value() { local key=$1 line value; [[ -f .env ]] || return 0; line=$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" .env || true); [[ -n $line ]] || return 0; value=${line#*=}; value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'); value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}; printf '%s' "$value"; }
port_pids() { local target=$1; if command -v lsof >/dev/null 2>&1; then lsof -nP -tiTCP:"$target" -sTCP:LISTEN 2>/dev/null || true; elif command -v fuser >/dev/null 2>&1; then fuser -n tcp "$target" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true; elif command -v ss >/dev/null 2>&1; then ss -ltnp "sport = :$target" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u; fi; }
[[ -n $port ]] || port=$(get_env_value PORT); port=${port:-3000}
mapfile -t pids < <(port_pids "$port")
if ((${#pids[@]} == 0)); then echo "No process is listening on port $port."; exit 0; fi
for pid in "${pids[@]}"; do echo "Stopping PID $pid..."; kill "$pid" 2>/dev/null || true; done
sleep 0.5
for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true; done
echo "Stopped listener(s) on port $port."
