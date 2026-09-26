#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
port="${PORT:-}"
usage() { printf '%s\n' 'Usage: ./tunnel.sh [--port PORT]' '' 'Starts a Cloudflare Quick Tunnel to the local MCP server.'; }
while (($#)); do case "$1" in --port) [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }; port=$2; shift 2 ;; -h|--help) usage; exit 0 ;; *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;; esac; done
if [[ -z $port && -f .env ]]; then port=$(grep -m1 -E '^[[:space:]]*PORT[[:space:]]*=' .env | cut -d= -f2- | tr -d '[:space:]' || true); fi
port=${port:-3000}
command -v cloudflared >/dev/null 2>&1 || { echo "cloudflared was not found on PATH." >&2; echo "Install it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" >&2; exit 1; }
printf '\n=== Cloudflare Quick Tunnel ===\n'
echo "Local: http://127.0.0.1:$port"
echo "Append /mcp/<MCP_TOKEN> to the public URL when creating the ChatGPT connector."
exec cloudflared tunnel --url "http://127.0.0.1:$port"
