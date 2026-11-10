#!/usr/bin/env bash
# az-guard-install.test.sh — self-test for az-guard-install.sh.
# Runs the installer in AZ_ROOT mode with --no-apply (never touches ip rules).
# Requires root + iproute2 (creates dummy interfaces, cleans them up).

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
INSTALLER="$HERE/az-guard-install.sh"

CREATED_IFACES=()
TMP_DIR=""

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

cleanup() {
    local ifc
    for ifc in "${CREATED_IFACES[@]}"; do
        ip link del "$ifc" 2>/dev/null || true
    done
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# --- 1. syntax on all scripts -------------------------------------------
for s in "$HERE"/*.sh; do
    bash -n "$s" || fail "bash -n $s"
done
ok "bash -n on all scripts"

# --- 2. environment ------------------------------------------------------
command -v ip >/dev/null 2>&1 || { echo "SKIP: iproute2 not available"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "SKIP: root required (dummy interfaces)"; exit 0; }

TMP_DIR="$(mktemp -d)"
export AZ_ROOT="$TMP_DIR"
mkdir -p "$AZ_ROOT/etc/wireguard" "$AZ_ROOT/var/log"

# --- 3. fake wireguard configs (egress + client layers) -------------------
cat > "$AZ_ROOT/etc/wireguard/proton.conf" <<'EOF'
[Interface]
Address = 10.2.0.2/32, 2a07:b944::2:2/128
EOF
printf '[Interface]\nAddress = 10.3.0.2/32\n' > "$AZ_ROOT/etc/wireguard/warp-antizapret.conf"
printf '[Interface]\nAddress = 10.99.0.1/24\n' > "$AZ_ROOT/etc/wireguard/antizapret.conf"
printf '[Interface]\n' > "$AZ_ROOT/etc/wireguard/vpn.conf"

# --- 4. dummy interfaces --------------------------------------------------
mkif() {
    local ifc="$1"
    ip link show dev "$ifc" >/dev/null 2>&1 && return 0
    ip link add "$ifc" type dummy 2>/dev/null || return 1
    CREATED_IFACES+=("$ifc")
    ip link set dev "$ifc" up 2>/dev/null || true   # kernel-маршрут подсети появляется только у поднятого интерфейса
}
mkif proton          || fail "cannot create dummy proton"
mkif warp-antizapret || fail "cannot create dummy warp-antizapret"
mkif antizapret      || fail "cannot create dummy antizapret"
mkif vpn             || fail "cannot create dummy vpn"
mkif antizapret2     || fail "cannot create dummy antizapret2"
ip addr add 10.200.0.1/24 dev antizapret 2>/dev/null || true
ip addr add 10.201.0.1/24 dev vpn 2>/dev/null || true
# antizapret2 deliberately has NO addresses — must be dropped from LAYERS.

CONF="$AZ_ROOT/etc/az-guard.conf"

# --- 5. full run, no apply ------------------------------------------------
"$INSTALLER" --dualstack y --guard y --reverse y --yes --no-apply --ingress-ip 203.0.113.10 \
    || fail "installer run 1 (rc=$?)"
ok "installer run 1"

[[ -f $CONF ]] || fail "$CONF not generated"
ok "conf generated"

grep -q '^INGRESS_IPS="203.0.113.10"' "$CONF" || fail "--ingress-ip not honored"
ok "--ingress-ip honored"

grep -q '^EGRESS_IFACES="[^"]*proton' "$CONF" || fail "proton missing from EGRESS_IFACES"
grep -q 'warp-antizapret' "$CONF" || fail "warp-antizapret missing from EGRESS_IFACES"
if grep '^EGRESS_IFACES=' "$CONF" | tr ' ' '\n' | grep -qx 'antizapret'; then
    fail "client layer 'antizapret' leaked into EGRESS_IFACES"
fi
if grep '^EGRESS_IFACES=' "$CONF" | tr ' ' '\n' | grep -qx 'vpn'; then
    fail "client layer 'vpn' leaked into EGRESS_IFACES"
fi
ok "EGRESS_IFACES correct (proton, warp-antizapret; client layers excluded)"

grep -q 'antizapret:antizapret:10\.200\.0\.0/24' "$CONF" || fail "antizapret layer with v4 cidr missing"
ok "LAYERS contain antizapret with v4 cidr"

if grep -q 'antizapret2' "$CONF"; then
    fail "antizapret2 (no addresses) must be excluded from LAYERS"
fi
ok "empty layer antizapret2 dropped"

if grep -q 'vpn-udp' "$CONF"; then
    fail "nonexistent interface vpn-udp must not appear in LAYERS"
fi
ok "nonexistent interfaces not in LAYERS"

[[ -f $AZ_ROOT/etc/wireguard/azr1.conf.example ]] || fail "reverse-tunnel template not installed"
ok "reverse template installed"

[[ -x $AZ_ROOT/root/az-guard/az-egress-guard-apply.sh ]] || fail "scripts not copied"
[[ -x $AZ_ROOT/root/az-guard/az-audit.sh ]] || fail "az-audit.sh not copied"
ok "scripts copied to \$AZ_ROOT/root/az-guard"

# --- 6. HAS_IPV6 mirrors installer logic ----------------------------------
if ip -6 route show default 2>/dev/null | grep -q '.' \
    && curl -6 -s -m 6 "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='; then
    grep -q '^HAS_IPV6=1' "$CONF" || fail "HAS_IPV6 should be 1 on a v6-capable host"
    ok "HAS_IPV6=1 (working v6 detected)"
else
    grep -q '^HAS_IPV6=0' "$CONF" || fail "HAS_IPV6 must be 0 without working v6"
    ok "HAS_IPV6=0 (no working v6 — dualstack gracefully disabled)"
fi

# --- 7. idempotency --------------------------------------------------------
cp "$CONF" "$TMP_DIR/conf.run1"
"$INSTALLER" --dualstack y --guard y --reverse y --yes --no-apply --ingress-ip 203.0.113.10 \
    || fail "installer run 2 (rc=$?)"
diff <(grep -v '^# Generated by az-guard-install.sh' "$TMP_DIR/conf.run1") \
     <(grep -v '^# Generated by az-guard-install.sh' "$CONF") \
    || fail "config not idempotent between runs"
ok "second run idempotent"

ls -d "$AZ_ROOT"/root/az-guard.bak-* >/dev/null 2>&1 || fail "no backup of previous /root/az-guard created"
ok "previous az-guard dir backed up"

# --- 8. --dualstack n forces HAS_IPV6=0 ------------------------------------
"$INSTALLER" --dualstack n --guard y --reverse n --yes --no-apply --ingress-ip 203.0.113.10 \
    || fail "installer run 3 (rc=$?)"
grep -q '^HAS_IPV6=0' "$CONF" || fail "--dualstack n must produce HAS_IPV6=0"
ok "--dualstack n => HAS_IPV6=0"

echo "PASS: all az-guard-install tests"
