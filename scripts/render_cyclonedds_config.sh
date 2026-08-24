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

: "${JETSON_TAILSCALE_IP:=}"
: "${JETSON_DDS_DISCOVERY_PORT:=7410}"
: "${ENABLE_JETSON_DDS_PEER:=0}"
: "${PI_DDS_WIFI_INTERFACE:=wlan0}"
: "${PI_DDS_TAILSCALE_INTERFACE:=tailscale0}"
export JETSON_TAILSCALE_IP
export JETSON_DDS_DISCOVERY_PORT
export ENABLE_JETSON_DDS_PEER
export PI_DDS_WIFI_INTERFACE
export PI_DDS_TAILSCALE_INTERFACE

case "${ENABLE_JETSON_DDS_PEER,,}" in
    1|true|yes|on)
        if [ -z "$JETSON_TAILSCALE_IP" ]; then
            echo "[render_cyclonedds] JETSON_TAILSCALE_IP is required when the Jetson DDS peer is enabled." >&2
            exit 1
        fi
        ;;
esac

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
    "ENABLE_JETSON_DDS_PEER": os.environ["ENABLE_JETSON_DDS_PEER"],
    "JETSON_TAILSCALE_IP": os.environ["JETSON_TAILSCALE_IP"],
    "JETSON_DDS_DISCOVERY_PORT": os.environ["JETSON_DDS_DISCOVERY_PORT"],
    "PI_DDS_WIFI_INTERFACE": os.environ["PI_DDS_WIFI_INTERFACE"],
    "PI_DDS_TAILSCALE_INTERFACE": os.environ["PI_DDS_TAILSCALE_INTERFACE"],
}

jetson_enabled = values["ENABLE_JETSON_DDS_PEER"].strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

if jetson_enabled:
    tailscale_interface_xml = (
        f'                <NetworkInterface name="{escape(values["PI_DDS_TAILSCALE_INTERFACE"])}" '
        'priority="default" multicast="false" />'
    )
    jetson_peers_xml = (
        "            <Peers>\n"
        "                <!-- Jetson Orin over Tailscale. -->\n"
        f'                <Peer Address="{escape(values["JETSON_TAILSCALE_IP"])}:'
        f'{escape(values["JETSON_DDS_DISCOVERY_PORT"])}" />\n'
        "            </Peers>"
    )
else:
    tailscale_interface_xml = "                <!-- Jetson DDS peer disabled; tailscale0 omitted. -->"
    jetson_peers_xml = "            <!-- Jetson DDS peer disabled. -->"

content = template.read_text(encoding="utf-8")
for key, value in values.items():
    content = content.replace("${" + key + "}", escape(value))
content = content.replace("${TAILSCALE_INTERFACE_XML}", tailscale_interface_xml)
content = content.replace("${JETSON_PEERS_XML}", jetson_peers_xml)

target.write_text(content, encoding="utf-8")
print(f"[render_cyclonedds] Wrote {target}")
for key, value in values.items():
    print(f"[render_cyclonedds] {key}={value}")
PY
