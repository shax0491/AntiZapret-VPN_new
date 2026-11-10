#!/usr/bin/env bash
# mh-ipv6.sh — toggle the IPv6 flag for /opt/mh-app config builds.
#
# Usage: mh-ipv6.sh on|off|status
#
# Writes /opt/mh-app/ipv6.flag (1/0) and rebuilds client configs:
#   python3 /opt/mh-app/build_configs.py
# During the build, the template's `ipv6:` lines are rewritten per the flag.

set -u

MODE="${1:-}"
APP_DIR="/opt/mh-app"
FLAG_FILE="$APP_DIR/ipv6.flag"
BUILDER="$APP_DIR/build_configs.py"

usage() {
    cat <<'EOF'
Usage: mh-ipv6.sh on|off|status

  on      Enable IPv6 in generated mihomo configs
          (enable ONLY if your ISP delegates a prefix (PD) AND the router
          distributes IPv6 in LAN through mihomo — otherwise IPv6 traffic
          will bypass mihomo and leak past the VPN)
  off     Disable IPv6 in generated configs
  status  Show current flag state
EOF
}

if [[ $MODE != "on" && $MODE != "off" && $MODE != "status" ]]; then
    usage
    exit 2
fi

if [[ ! -d $APP_DIR ]]; then
    echo "Error: $APP_DIR not found on this host." >&2
    exit 1
fi

if [[ $MODE == "status" ]]; then
    if [[ -f $FLAG_FILE ]]; then
        echo "ipv6 flag: $(cat "$FLAG_FILE")"
    else
        echo "ipv6 flag: not set (default: off)"
    fi
    exit 0
fi

if [[ $MODE == "on" ]]; then
    {
        echo "Warning! Enable IPv6 only if the ISP delegates a prefix (PD) AND the router"
        echo "distributes IPv6 in LAN through mihomo. Otherwise IPv6 traffic will bypass"
        echo "mihomo and leak past the VPN."
    } >&2
    echo 1 > "$FLAG_FILE"
else
    echo 0 > "$FLAG_FILE"
fi

python3 "$BUILDER"
rc=$?

if [[ $rc -eq 0 ]]; then
    echo "Done. ipv6.flag=$(cat "$FLAG_FILE"), configs rebuilt."
else
    echo "Error: build_configs.py failed (code $rc)." >&2
fi
exit "$rc"
