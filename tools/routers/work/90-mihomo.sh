#!/bin/sh
# mihomo: устройства из политики Кинетика «Mihomo» (веб-интерфейс -> Приоритеты подключений) идут через mihomo:
# их DNS -> mihomo :7874, TCP -> redir-port 7892 (nat REDIRECT), QUIC (UDP 443) -> zapret роутера или туннель до zapret-gw.
# Устройства определяются по MAC. Кинетик вызывает этот хук при пересборке iptables; sync-devices.sh (cron, раз в
# минуту) вызывает его, когда меняется состав политики. TPROXY на этой прошивке не используем.
[ "$type" = "ip6tables" ] && exit 0
IPT=/opt/sbin/iptables; PORT=7892
MACS=$(ndmc -c "show running-config" 2>/dev/null | awk '/^ip hotspot/{h=1} h&&/^!/{h=0} h&&/ policy Mihomo$/{print $2}')
pidof mihomo >/dev/null || MACS=""
# QUIC (UDP 443) этих устройств. Режим в /opt/etc/mihomo/quic-mode: router (по умолчанию) - напрямую через zapret
# роутера, первые 8 пакетов в nfqws (очередь 301); proxmox - в туннель до zapret-gw (метка 0x10000000 -> таблица 112).
# router: правило в mangle POSTROUTING, как в nfqws-keenetic. В FORWARD второй пакет QUIC Initial (Chrome/YouTube делят
# его на два) уходил мимо очереди через FASTNAT Кинетика, nfqws ждал сборки и не делал desync. В POSTROUTING нет -m mac,
# поэтому устройства берутся по IP из ARP-таблицы (sync-devices.sh переставляет правила при смене IP).
QMODE=$(cat /opt/etc/mihomo/quic-mode 2>/dev/null || echo router)
if [ -z "$table" ] || [ "$table" = "mangle" ]; then
	$IPT -w -t mangle -D POSTROUTING -j MIHOMO_QUIC 2>/dev/null; $IPT -w -t mangle -D FORWARD -j MIHOMO_QUIC 2>/dev/null; $IPT -w -t mangle -F MIHOMO_QUIC 2>/dev/null; $IPT -w -t mangle -X MIHOMO_QUIC 2>/dev/null
	$IPT -w -t mangle -D PREROUTING -j MIHOMO_QUICRT 2>/dev/null; $IPT -w -t mangle -F MIHOMO_QUICRT 2>/dev/null; $IPT -w -t mangle -X MIHOMO_QUICRT 2>/dev/null
	/opt/sbin/ip rule del fwmark 0x10000000/0x10000000 lookup 112 2>/dev/null; /opt/sbin/ip route flush table 112 2>/dev/null
	/opt/sbin/ip rule del fwmark 0x10000000/0x10000000 lookup 111 2>/dev/null
	if [ -n "$MACS" ] && [ "$QMODE" = "proxmox" ]; then
		$IPT -w -t mangle -N MIHOMO_QUICRT
		for m in $MACS; do $IPT -w -t mangle -A MIHOMO_QUICRT -m mac --mac-source $m -p udp --dport 443 ! -d 192.168.0.0/16 -j MARK --set-xmark 0x10000000/0x10000000; done
		$IPT -w -t mangle -I PREROUTING -j MIHOMO_QUICRT
		/opt/sbin/ip rule add fwmark 0x10000000/0x10000000 lookup 112 priority 5
		/opt/sbin/ip route replace default dev nwg13 table 112
	fi
fi
if [ -z "$table" ] || [ "$table" = "filter" ]; then
	$IPT -w -t filter -D FORWARD -j MIHOMO_QUIC 2>/dev/null; $IPT -w -t filter -F MIHOMO_QUIC 2>/dev/null; $IPT -w -t filter -X MIHOMO_QUIC 2>/dev/null
	# QUIC устройств политики отбиваем (как дома): приложения (Gemini, ИИ и т.п.) сразу переходят на TCP -> mihomo -> VPN.
	# Исключение - сети из quic-allow.txt (видеосерверы YouTube): там QUIC идёт как раньше, через zapret.
	$IPT -w -t filter -D FORWARD -p udp --dport 443 -j MIHOMO_QREJ 2>/dev/null; $IPT -w -t filter -F MIHOMO_QREJ 2>/dev/null; $IPT -w -t filter -X MIHOMO_QREJ 2>/dev/null
	if [ -n "$MACS" ]; then
		$IPT -w -t filter -N MIHOMO_QREJ
		for net in $(grep -vE "^[[:space:]]*(#|$)" /opt/etc/mihomo/quic-allow.txt 2>/dev/null); do $IPT -w -t filter -A MIHOMO_QREJ -d $net -j RETURN; done
		for m in $MACS; do $IPT -w -t filter -A MIHOMO_QREJ -m mac --mac-source $m -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable; done
		$IPT -w -t filter -I FORWARD -p udp --dport 443 -j MIHOMO_QREJ
	fi
fi
[ -n "$table" ] && [ "$table" != "nat" ] && exit 0
$IPT -w -t nat -D PREROUTING -j MIHOMO 2>/dev/null
$IPT -w -t nat -F MIHOMO 2>/dev/null || $IPT -w -t nat -N MIHOMO
[ -z "$MACS" ] && exit 0
for m in $MACS; do
	$IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p udp --dport 53 -j REDIRECT --to-ports 7874
	$IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p tcp --dport 53 -j REDIRECT --to-ports 7874
done
for net in 198.51.100.0/24 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 255.255.255.255/32; do
	$IPT -w -t nat -A MIHOMO -d $net -j RETURN
done
for m in $MACS; do $IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p tcp -j REDIRECT --to-ports $PORT; done
$IPT -w -t nat -I PREROUTING -j MIHOMO
