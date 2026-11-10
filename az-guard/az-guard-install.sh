#!/usr/bin/env bash
# az-guard-install.sh — installer for az-guard components:
#   --dualstack  IPv6 Dual-Stack (sysctl forwarding, v6 BASE_RULES for proton)
#   --guard      Egress-Guard (generates /etc/az-guard.conf, audit/dry-run/apply/commit)
#   --reverse    Reverse-tunnel template only (no tunnel is brought up)
#
# Idempotent, root-only. Secrets are never printed.
#
# Usage: az-guard-install.sh [--dualstack y|n] [--guard y|n] [--reverse y|n]
#                            [--yes] [--no-apply] [--ingress-ip IP] [--help]
# Environment:
#   AZ_ROOT=<dir>  prefix for /etc and /root (test mode; empty on a real system)

set -u
set -o pipefail

AZ_ROOT="${AZ_ROOT:-}"
ETC_DIR="$AZ_ROOT/etc"
ROOT_DIR="$AZ_ROOT/root"
CONF_FILE="$ETC_DIR/az-guard.conf"
WG_DIR="$ETC_DIR/wireguard"
SYSCTL_FILE="$ETC_DIR/sysctl.d/99-az-dualstack.conf"
NETD_SRC="90-az-foreign-rules.networkd.conf"
NETD_DIR="$ETC_DIR/systemd/networkd.conf.d"
NETD_DST="$NETD_DIR/90-az-foreign-rules.conf"
GUARD_DIR="$ROOT_DIR/az-guard"
LOG_FILE="${AZ_ROOT}/var/log/az-guard-install.log"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

DUALSTACK="n"
GUARD="n"
REVERSE="n"
ASSUME_YES=0
NO_APPLY=0
INGRESS_IP_ARG=""
HAS_IPV6=0

EGRESS_IFACES=""
INGRESS_IPS_VAL=""
LAYERS_VAL=""
BASE_RULES_VAL=""

# Client-side layer interfaces. Only existing interfaces with addresses are used.
CLIENT_LAYERS="antizapret antizapret2 vpn vpn2 awg1 antizapret-udp antizapret-tcp vpn-udp vpn-tcp"

usage() {
    cat <<'EOF'
Usage: az-guard-install.sh [options]

  --dualstack y|n   Enable IPv6 Dual-Stack support (default n)
  --guard y|n       Enable Egress-Guard (default n)
  --reverse y|n     Install reverse-tunnel template azr1.conf.example (default n)
  --yes             Do not ask for confirmation before --apply
  --no-apply        Generate configs and files only; never touch ip rules
  --ingress-ip IP   Public IP of this node for INGRESS_IPS
                    (default: src of `ip -4 route get 1.1.1.1`)
  -h, --help        Show this help

Environment:
  AZ_ROOT=<dir>     Prefix for /etc and /root (test mode). Empty on a real host.
EOF
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "Error: $*"
    exit 1
}

# ---------------------------------------------------------------- files ----

install_files() {
    if [[ -d "$GUARD_DIR" ]]; then
        local backup="$ROOT_DIR/az-guard.bak-$(date +%Y%m%d-%H%M%S-%N)"
        mv -- "$GUARD_DIR" "$backup" || die "cannot back up $GUARD_DIR to $backup"
        log "Info: previous $GUARD_DIR moved to $backup"
    fi
    mkdir -p -- "$GUARD_DIR" || die "cannot create $GUARD_DIR"
    local src dst
    for src in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.example; do
        [[ -e $src ]] || continue
        case "$(basename -- "$src")" in
            *.test.sh) continue ;;    # never ship the test into /root/az-guard
        esac
        dst="$GUARD_DIR/$(basename -- "$src")"
        if [[ $src == *.example ]]; then
            install -m 600 "$src" "$dst" || die "cannot install $dst"
        else
            install -m 700 "$src" "$dst" || die "cannot install $dst"
        fi
    done
    log "Info: az-guard scripts installed to $GUARD_DIR"
}

# ------------------------------------------------------------- dualstack ---

ipv6_works() {
    command -v ip >/dev/null 2>&1 || return 1
    command -v curl >/dev/null 2>&1 || return 1
    ip -6 route show default 2>/dev/null | grep -q '.' || return 1
    curl -6 -s -m 6 "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep -q '^ip=' || return 1
    return 0
}

proton_has_ipv6() {
    [[ -f $WG_DIR/proton.conf ]] || return 1
    ip link show dev proton >/dev/null 2>&1 || return 1
    grep -Eq '^[[:space:]]*Address[[:space:]]*=.*:' "$WG_DIR/proton.conf"
}

setup_dualstack() {
    if ! ipv6_works; then
        log "Warning! Working native IPv6 not detected (no default v6 route or no v6 internet). Dual-Stack NOT enabled, HAS_IPV6=0."
        HAS_IPV6=0
        return 0
    fi
    HAS_IPV6=1
    mkdir -p -- "$(dirname -- "$SYSCTL_FILE")"
    if [[ ! -f $SYSCTL_FILE ]] || ! grep -q '^net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1$' "$SYSCTL_FILE"; then
        printf 'net.ipv6.conf.all.forwarding = 1\n' > "$SYSCTL_FILE"
        log "Info: wrote $SYSCTL_FILE"
    fi
    if [[ -z $AZ_ROOT ]]; then
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 \
            || log "Warning! 'sysctl -p $SYSCTL_FILE' failed — apply net.ipv6.conf.all.forwarding=1 manually."
    fi
    log "Info: Dual-Stack enabled (HAS_IPV6=1). Proton profiles were not modified."
}

# ----------------------------------------------------------------- guard ---

collect_egress() {
    # Egress = Proton/WARP server-side wg interfaces from /etc/wireguard/*.conf,
    # excluding client layers and the reverse tunnel.
    local f base
    EGRESS_IFACES=""
    for f in "$WG_DIR"/*.conf; do
        [[ -e $f ]] || continue
        base="$(basename -- "$f" .conf)"
        case "$base" in
            antizapret|antizapret2|antizapret-udp|antizapret-tcp| \
            vpn|vpn2|vpn-udp|vpn-tcp|azr1|awg*|azr*)
                continue ;;
        esac
        ip link show dev "$base" >/dev/null 2>&1 || continue
        case " $EGRESS_IFACES " in
            *" $base "*) ;;
            *) EGRESS_IFACES="${EGRESS_IFACES:+$EGRESS_IFACES }$base" ;;
        esac
    done
}

add_base_rule() {
    # $1 = -4|-6, $2 = ip rule args; appended to BASE_RULES_VAL postročno, deduped
    local line="$1|$2"
    if printf '%s\n' "$BASE_RULES_VAL" | grep -qxF -- "$line"; then
        return 0
    fi
    BASE_RULES_VAL="${BASE_RULES_VAL:+$BASE_RULES_VAL
}$line"
}

build_conf() {
    collect_egress
    if [[ -z $EGRESS_IFACES ]]; then
        log "Warning! No egress interfaces (Proton/WARP) found in $WG_DIR. Egress-Guard step skipped."
        return 1
    fi

    if [[ -n $INGRESS_IP_ARG ]]; then
        INGRESS_IPS_VAL="$INGRESS_IP_ARG"
    else
        INGRESS_IPS_VAL="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    fi
    if [[ -z $INGRESS_IPS_VAL ]]; then
        log "Warning! Cannot determine node public IP and --ingress-ip not given. Egress-Guard step skipped."
        return 1
    fi

    local layer v4 v6
    LAYERS_VAL=""
    for layer in $CLIENT_LAYERS; do
        ip link show dev "$layer" >/dev/null 2>&1 || continue
        v4="$(ip -4 -o route show dev "$layer" proto kernel scope link 2>/dev/null | awk '{print $1}' | paste -sd, -)"
        v6=""
        if [[ $HAS_IPV6 == 1 ]]; then
            v6="$(ip -6 -o route show dev "$layer" proto kernel 2>/dev/null \
                | awk '$1 !~ /^fe80::/ && $1 ~ /\// {print $1}' | paste -sd, -)"
        fi
        [[ -z $v4 && -z $v6 ]] && continue
        LAYERS_VAL="${LAYERS_VAL:+$LAYERS_VAL }$layer:$layer:$v4:$v6"
    done

    if [[ -z $LAYERS_VAL ]]; then
        log "Warning! No client layer interfaces with addresses found (antizapret/vpn/awg1/openvpn tun). Egress-Guard step skipped."
        return 1
    fi

    BASE_RULES_VAL=""
    if [[ $HAS_IPV6 == 1 ]] && proton_has_ipv6; then
        add_base_rule "-6" "oif proton lookup 51820 priority 1000"
    fi

    mkdir -p -- "$(dirname -- "$CONF_FILE")"
    {
        echo "# Generated by az-guard-install.sh on $(date -Is). Do not edit by hand."
        echo "HAS_IPV6=$HAS_IPV6"
        echo "EGRESS_IFACES=\"$EGRESS_IFACES\""
        echo "INGRESS_IPS=\"$INGRESS_IPS_VAL\""
        echo "PANEL_PORT=9100"
        echo "LAYERS=\"$LAYERS_VAL\""
        echo "BASE_RULES=\"$BASE_RULES_VAL\""
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    log "Info: wrote $CONF_FILE"
    return 0
}

install_networkd_dropin() {
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        mkdir -p -- "$NETD_DIR"
        install -m 644 "$SCRIPT_DIR/$NETD_SRC" "$NETD_DST" \
            || log "Warning! cannot install $NETD_DST"
        log "Info: installed $NETD_DST (networkd picks it up on next reconfigure/restart; no restart triggered)."
    else
        log "Warning! systemd-networkd is not active; drop-in NOT installed. If networkd is used on this host, install $SCRIPT_DIR/$NETD_SRC to $NETD_DST manually."
    fi
}

run_guard() {
    local apply="$GUARD_DIR/az-egress-guard-apply.sh"
    local audit="$GUARD_DIR/az-audit.sh"

    if [[ ! -x $apply || ! -x $audit ]]; then
        log "Error: $apply or $audit missing. Egress-Guard step skipped."
        return 1
    fi

    build_conf || return 0    # warning already logged; skip guard, continue install

    install_networkd_dropin

    if [[ -n $AZ_ROOT ]]; then
        log "Info: AZ_ROOT test mode: audit/dry-run/apply skipped (they act on the real host)."
        return 0
    fi

    log "Info: baseline audit (failures are expected before apply)..."
    "$audit" --conf "$CONF_FILE" || true

    log "Info: dry-run..."
    if ! "$apply" --conf "$CONF_FILE" --dry-run; then
        log "Error: dry-run failed; nothing was applied."
        return 1
    fi

    if [[ $NO_APPLY == 1 ]]; then
        log "Info: --no-apply given, stopping here (no ip rule changes)."
        return 0
    fi

    if [[ $ASSUME_YES == 0 ]]; then
        local ans=""
        read -rp "Apply egress-guard rules now? [y/n]: " -e -i y ans </dev/tty
        if [[ $ans != "y" ]]; then
            log "Info: apply cancelled by user; nothing was changed."
            return 0
        fi
    fi

    log "Info: applying rules in 10 seconds (Ctrl-C to abort; --apply arms a 300 s auto-rollback)."
    sleep 10

    "$apply" --conf "$CONF_FILE" --apply \
        || log "Warning! --apply returned non-zero; the 300 s auto-rollback is counting down."

    if "$audit" --conf "$CONF_FILE"; then
        "$apply" --conf "$CONF_FILE" --commit
        log "Info: audit passed; egress-guard committed and services enabled."
        return 0
    fi

    log "Error: audit FAILED after apply. Auto-rollback (300 s) stays armed — fix the problem and rerun this installer, or reboot to revert. Details: $LOG_FILE"
    return 3
}

# --------------------------------------------------------------- reverse ---

install_reverse_template() {
    mkdir -p -- "$WG_DIR"
    install -m 600 "$SCRIPT_DIR/azr1.conf.example" "$WG_DIR/azr1.conf.example" \
        || die "cannot install $WG_DIR/azr1.conf.example"
    log "Info: reverse-tunnel template installed to $WG_DIR/azr1.conf.example."
    log "Info: the tunnel itself is created from AdminPanel; wg-quick@azr1 was NOT enabled or started."
}

# ------------------------------------------------------------------ main ---

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dualstack)  [[ $# -ge 2 ]] || die "--dualstack needs y|n";  DUALSTACK="$2";     shift 2 ;;
            --guard)      [[ $# -ge 2 ]] || die "--guard needs y|n";      GUARD="$2";         shift 2 ;;
            --reverse)    [[ $# -ge 2 ]] || die "--reverse needs y|n";    REVERSE="$2";       shift 2 ;;
            --yes)        ASSUME_YES=1;  shift ;;
            --no-apply)   NO_APPLY=1;    shift ;;
            --ingress-ip) [[ $# -ge 2 ]] || die "--ingress-ip needs an IP"; INGRESS_IP_ARG="$2"; shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
    done

    local v
    for v in "$DUALSTACK" "$GUARD" "$REVERSE"; do
        [[ $v =~ ^(y|n)$ ]] || die "flags accept only y or n (got: '$v')"
    done

    if [[ $EUID -ne 0 && -z $AZ_ROOT ]]; then
        die "must run as root (or set AZ_ROOT=<dir> for test mode)."
    fi
    command -v ip >/dev/null 2>&1 || die "iproute2 (ip) not found."

    mkdir -p -- "$(dirname -- "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log "Info: az-guard-install.sh started (dualstack=$DUALSTACK guard=$GUARD reverse=$REVERSE no_apply=$NO_APPLY AZ_ROOT=${AZ_ROOT:-/})"

    install_files

    local rc=0

    if [[ $DUALSTACK == y ]]; then
        setup_dualstack
    fi

    if [[ $GUARD == y ]]; then
        run_guard || rc=$?
    fi

    if [[ $REVERSE == y ]]; then
        install_reverse_template
    fi

    if [[ $rc -eq 0 ]]; then
        log "Info: done. conf: $CONF_FILE; scripts: $GUARD_DIR; log: $LOG_FILE"
    else
        log "Error: finished with errors (code $rc). See $LOG_FILE"
    fi
    exit "$rc"
}

main "$@"
