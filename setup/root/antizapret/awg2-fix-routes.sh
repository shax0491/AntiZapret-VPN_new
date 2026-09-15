#!/bin/bash
# AmneziaWG 2.0 PostUp hook: pins each peer's kernel route to this interface.
#
# Address = .../24 on both an AmneziaWG 2.0 interface (antizapret2/vpn2) and an
# older AmneziaWG 1.5 interface (antizapret-awg/vpn-awg, or any other WireGuard-
# family interface reusing the same subnet, e.g. from a pre-existing install)
# each add an identical, same-length kernel route for that /24. Only one of
# the two can win, and whichever loses gets all its return traffic silently
# black-holed - the handshake still succeeds (that's a separate UDP exchange),
# but no data ever reaches the client. This is undetectable without comparing
# `ip route` against `awg show <iface> allowed-ips`.
#
# Fix: a /32 host route per peer always outranks a /24, regardless of which
# interface's /24 was installed first. Safe to run repeatedly (idempotent) and
# safe even with no subnet conflict at all (harmless no-op duplicate of the
# already-correct route).
set -uo pipefail
IFACE="${1:-%i}"
awg show "$IFACE" allowed-ips 2>/dev/null | while read -r _pubkey cidr; do
	ip="${cidr%/*}"
	[ -n "$ip" ] && ip route replace "$ip/32" dev "$IFACE" metric 50
done
