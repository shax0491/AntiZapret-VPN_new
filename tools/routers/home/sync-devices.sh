#!/bin/sh
# раз в минуту (cron): если поменялся состав политики «Mihomo» или IP её устройств, перезапустился mihomo или Кинетик
# выкинул наши правила при пересборке iptables - поставить их заново
MACS=$(sh /opt/etc/mihomo/macs.sh | sort)
# правило QUIC (режим router) стоит в POSTROUTING по IP устройств - смена IP тоже повод переставить
IPS=$(for m in $MACS; do awk -v m=$m '$4==m && $3=="0x2" {print $1}' /proc/net/arp; done | sort -u)
NOW="$(echo $MACS) | $(echo $IPS) | $(pidof mihomo)"
OK=1
[ -n "$MACS" ] && {
	/opt/sbin/iptables -t nat -C PREROUTING -j MIHOMO 2>/dev/null || OK=0
	if [ "$(cat /opt/etc/mihomo/quic-mode 2>/dev/null || echo router)" = proxmox ]; then
		/opt/sbin/iptables -t mangle -C PREROUTING -j MIHOMO_QUICRT 2>/dev/null || OK=0
	else
		/opt/sbin/iptables -t mangle -C POSTROUTING -j MIHOMO_QUIC 2>/dev/null || OK=0
		/opt/sbin/iptables -t filter -C FORWARD -j MIHOMO_QREJ 2>/dev/null || OK=0
	fi
	/opt/sbin/iptables -t mangle -C POSTROUTING -j NFQWS 2>/dev/null || OK=0
}
[ "$OK" = 1 ] && [ "$NOW" = "$(cat /tmp/mihomo-devices 2>/dev/null)" ] && exit 0
sh /opt/etc/ndm/netfilter.d/91-nfqws.sh
sh /opt/etc/ndm/netfilter.d/90-mihomo.sh && echo "$NOW" > /tmp/mihomo-devices
logger -t mihomo "rules re-applied: $NOW ok=$OK"
