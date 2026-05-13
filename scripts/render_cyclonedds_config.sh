#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$REPO_ROOT"

if [ -f .env ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|\#*) continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$key=$value"
        fi
    done < .env
fi

: "${JETSON_TAILSCALE_IP:=100.125.121.125}"
: "${JETSON_DDS_PRUNE_DELAY:=5s}"
: "${PI_DDS_WIFI_INTERFACE:=wlan0}"
: "${PI_DDS_TAILSCALE_INTERFACE:=tailscale0}"
export JETSON_TAILSCALE_IP
export JETSON_DDS_PRUNE_DELAY
export PI_DDS_WIFI_INTERFACE
export PI_DDS_TAILSCALE_INTERFACE

template="config/cyclonedds.xml.template"
target="config/cyclonedds.xml"

if [ ! -f "$template" ]; then
    echo "[render_cyclonedds] Missing template: $template" >&2
    exit 1
fi

python3 - <<'PY'
import os
from pathlib import Path
from xml.sax.saxutils import escape

template = Path("config/cyclonedds.xml.template")
target = Path("config/cyclonedds.xml")

values = {
    "JETSON_TAILSCALE_IP": os.environ["JETSON_TAILSCALE_IP"],
    "JETSON_DDS_PRUNE_DELAY": os.environ["JETSON_DDS_PRUNE_DELAY"],
    "PI_DDS_WIFI_INTERFACE": os.environ["PI_DDS_WIFI_INTERFACE"],
    "PI_DDS_TAILSCALE_INTERFACE": os.environ["PI_DDS_TAILSCALE_INTERFACE"],
}

content = template.read_text(encoding="utf-8")
for key, value in values.items():
    content = content.replace("${" + key + "}", escape(value))

target.write_text(content, encoding="utf-8")
print(f"[render_cyclonedds] Wrote {target}")
for key, value in values.items():
    print(f"[render_cyclonedds] {key}={value}")
PY
