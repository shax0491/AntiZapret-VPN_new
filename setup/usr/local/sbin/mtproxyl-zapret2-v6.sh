#!/bin/bash
# IPv6-копия правил mtproxyl-zapret2 (таблица ip6 MTProtoL): те же очереди nfqws2, фильтр по нативному IPv6 узла
set -e
TABLE="MTProtoL"; FWMARK="0x40000000"; PORT="443"; QNUM="200-201"; CT_MARK="0x00040000"; COMBINED_MARK="0x40040000"
BYPASS_MATCH="tcp flags & (fin | syn | rst | ack) == ack"
LIMIT_MATCH="tcp flags & (fin | syn | rst) == 0 ct packets > 64"
EXCLUDE_IFACES="awg1"
# после загрузки нативный IPv6 появляется позже старта юнита: ждём до 90 с (иначе таблица ip6 MTProtoL не создаётся)
for _ in $(seq 1 45); do
	A6=$(ip -6 addr show scope global | awk '/inet6/ && !/fd[0-9a-f][0-9a-f]:/ && !/ tentative/ {sub("/.*","",$2); print $2; exit}')
	[ -n "$A6" ] && break; sleep 2
done
[ -n "$A6" ] || { echo "mtproxyl-zapret2-v6: нет глобального IPv6, пропуск"; exit 0; }
nft delete table ip6 "$TABLE" 2>/dev/null || true
nft add table ip6 "$TABLE"
nft "add chain ip6 $TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip6 $TABLE predefrag meta mark $COMBINED_MARK counter accept"
nft "add rule ip6 $TABLE predefrag meta mark and $FWMARK != 0x00000000 counter notrack"
nft "add chain ip6 $TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip6 $TABLE output meta mark and $COMBINED_MARK == $COMBINED_MARK ct mark set $CT_MARK counter accept"
nft "add chain ip6 $TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
for i in $EXCLUDE_IFACES; do nft "add rule ip6 $TABLE postrouting oifname \"$i\" counter accept"; done
nft "add rule ip6 $TABLE postrouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip6 $TABLE postrouting $LIMIT_MATCH counter accept"
nft "add rule ip6 $TABLE postrouting meta mark and $FWMARK == 0x00000000 ip6 saddr $A6 tcp sport $PORT counter queue num $QNUM bypass"
nft "add chain ip6 $TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip6 $TABLE prerouting ct state invalid counter drop"
for i in $EXCLUDE_IFACES; do nft "add rule ip6 $TABLE prerouting iifname \"$i\" counter accept"; done
nft "add rule ip6 $TABLE prerouting $BYPASS_MATCH ct mark $CT_MARK counter accept"
nft "add rule ip6 $TABLE prerouting $LIMIT_MATCH counter accept"
nft "add rule ip6 $TABLE prerouting meta mark and $FWMARK == 0x00000000 ip6 daddr $A6 tcp dport $PORT counter queue num $QNUM bypass"
echo "mtproxyl-zapret2-v6: table ip6 $TABLE applied ($A6)"
