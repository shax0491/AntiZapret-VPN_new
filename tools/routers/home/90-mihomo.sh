#!/bin/sh
# mihomo: устройства из политики Кинетика «Mihomo» (веб-интерфейс -> Приоритеты подключений) идут через mihomo:
# их DNS -> mihomo :7874, TCP -> redir-port 7892 (nat REDIRECT), QUIC (UDP 443): к YouTube - zapret роутера, остальное отклоняется (-> TCP).
# Устройства определяются по MAC. Кинетик вызывает этот хук при пересборке iptables; sync-devices.sh (cron, раз в
# минуту) вызывает его, когда меняется состав политики. TPROXY на этой прошивке не используем.
[ "$type" = "ip6tables" ] && exit 0
IPT=/opt/sbin/iptables; PORT=7892
MACS=$(sh /opt/etc/mihomo/macs.sh)
# WG-сервер Кинетика (удалённые клиенты): их трафик тоже через mihomo - заблокированное через VPN, остальное из дома напрямую.
# Интерфейсы - в /opt/etc/mihomo/wg-ifaces (по одному, пустой файл = выключено). Домашняя сеть 192.168.1.0/24 видна им ещё и как
# 192.168.201.0/24 (NETMAP): в конфиге клиента 192.168.1.0/24 не нужен и не ломает локальную сеть 192.168.1.x там, где он сидит.
WGIF=$(grep -oE '^[a-z0-9]+' /opt/etc/mihomo/wg-ifaces 2>/dev/null)
pidof mihomo >/dev/null || { MACS=""; WGIF=""; }
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
	# QUIC мимо mihomo: mihomo ловит только TCP, а UDP 443 уходил напрямую с российского IP - Claude/ChatGPT/Gemini в
	# приложениях на телефонах отказывали. Напрямую (через запрет) оставляем QUIC только к видеосерверам YouTube
	# (/opt/etc/mihomo/quic-allow.txt), остальной сразу отклоняем: приложение переходит на TCP, а TCP идёт через mihomo.
	$IPT -w -t filter -D FORWARD -j MIHOMO_QREJ 2>/dev/null; $IPT -w -t filter -F MIHOMO_QREJ 2>/dev/null; $IPT -w -t filter -X MIHOMO_QREJ 2>/dev/null
	if [ -n "$MACS" ] && [ "$QMODE" = "router" ]; then
		ALLOW=$(grep -vE "^\s*(#|$)" /opt/etc/mihomo/quic-allow.txt 2>/dev/null)
		$IPT -w -t filter -N MIHOMO_QREJ
		for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 $ALLOW; do $IPT -w -t filter -A MIHOMO_QREJ -p udp --dport 443 -d $net -j RETURN; done
		for m in $MACS; do $IPT -w -t filter -A MIHOMO_QREJ -m mac --mac-source $m -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable; done
		$IPT -w -t filter -I FORWARD -j MIHOMO_QREJ
	fi
fi
if [ -z "$table" ] || [ "$table" = "filter" ]; then
	$IPT -w -t filter -D FORWARD -j MIHOMO_WGQ 2>/dev/null; $IPT -w -t filter -F MIHOMO_WGQ 2>/dev/null; $IPT -w -t filter -X MIHOMO_WGQ 2>/dev/null
	if [ -n "$WGIF" ]; then
		$IPT -w -t filter -N MIHOMO_WGQ
		for i in $WGIF; do $IPT -w -t filter -A MIHOMO_WGQ -i $i -p udp --dport 443 ! -d 192.168.0.0/16 -j REJECT --reject-with icmp-port-unreachable; done
		$IPT -w -t filter -I FORWARD -j MIHOMO_WGQ
	fi
fi
[ -n "$table" ] && [ "$table" != "nat" ] && exit 0
$IPT -w -t nat -D PREROUTING -j MIHOMO 2>/dev/null
$IPT -w -t nat -F MIHOMO 2>/dev/null || $IPT -w -t nat -N MIHOMO
[ -z "$MACS" ] && [ -z "$WGIF" ] && exit 0
[ -n "$WGIF" ] && { lsmod | grep -q "^xt_NETMAP " || insmod /lib/modules/$(uname -r)/xt_NETMAP.ko 2>/dev/null; }
for i in $WGIF; do
	$IPT -w -t nat -A MIHOMO -i $i -d 192.168.201.0/24 -j NETMAP --to 192.168.1.0/24
	$IPT -w -t nat -A MIHOMO -i $i -p udp --dport 53 -j REDIRECT --to-ports 7874
	$IPT -w -t nat -A MIHOMO -i $i -p tcp --dport 53 -j REDIRECT --to-ports 7874
done
for m in $MACS; do
	$IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p udp --dport 53 -j REDIRECT --to-ports 7874
	$IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p tcp --dport 53 -j REDIRECT --to-ports 7874
done
for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 255.255.255.255/32; do
	$IPT -w -t nat -A MIHOMO -d $net -j RETURN
done
for m in $MACS; do $IPT -w -t nat -A MIHOMO -m mac --mac-source $m -p tcp -j REDIRECT --to-ports $PORT; done
for i in $WGIF; do $IPT -w -t nat -A MIHOMO -i $i -p tcp -j REDIRECT --to-ports $PORT; done
$IPT -w -t nat -I PREROUTING -j MIHOMO
