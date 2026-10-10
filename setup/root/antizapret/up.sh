#!/bin/bash
set -e
shopt -s nullglob

cd /root/antizapret

./down.sh

source setup

WARP_PROVIDER="${WARP_PROVIDER:-cloudflare}"

# Режим 3 и остальные режимы WARP используют разный warp.rpz: пересобираем под текущий
# ANTIZAPRET_WARP, иначе смена режима из панели (только up.sh) не меняет маршрут доменов
./warp-rpz.sh || echo 'warp.rpz rebuild failed'

# Out IP protection
if [[ -n "$ANTIZAPRET_OUT_IP" ]]; then
	iptables -w -I INPUT 1 -d $ANTIZAPRET_OUT_IP -m conntrack --ctstate NEW -j DROP
fi
if [[ -n "$VPN_OUT_IP" && "$VPN_OUT_IP" != "$ANTIZAPRET_OUT_IP" ]]; then
	iptables -w -I INPUT 1 -d $VPN_OUT_IP -m conntrack --ctstate NEW -j DROP
fi

if [[ -z "$DEFAULT_INTERFACE" ]]; then
	DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
	if [[ -z "$DEFAULT_INTERFACE" ]]; then
		echo 'Default network interface not found!'
		exit 1
	fi
	DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
	if [[ -z "$DEFAULT_IP" ]]; then
		echo 'Default IPv4 address not found!'
		exit 2
	fi
fi

if [[ -z "$ANTIZAPRET_OUT_INTERFACE" ]]; then
	ANTIZAPRET_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		ANTIZAPRET_OUT_IP=$DEFAULT_IP
	fi
fi

if [[ -z "$VPN_OUT_INTERFACE" ]]; then
	VPN_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$VPN_OUT_IP" ]]; then
		VPN_OUT_IP=$DEFAULT_IP
	fi
fi

[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP="${CLIENT_IP:-172}" || IP=10
[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && FAKE_IP="${FAKE_IP:-198.18}" || FAKE_IP="$IP.30"

# WARP/Proton AntiZapret
ANTIZAPRET_WARP_INTERFACE=warp-antizapret
ANTIZAPRET_WARP_PATH="/etc/wireguard/$ANTIZAPRET_WARP_INTERFACE.conf"

if [[ "$ANTIZAPRET_WARP" == '2' || "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]]; then
	set +e
	echo "Starting $ANTIZAPRET_WARP_INTERFACE ($WARP_PROVIDER)..."

	if [[ "$WARP_PROVIDER" == 'proton' ]]; then
		if [[ -z "$PROTON_ANTIZAPRET_PRIVATE_KEY" || -z "$PROTON_ANTIZAPRET_PUBLIC_KEY" || -z "$PROTON_ANTIZAPRET_ENDPOINT_HOST" || -z "$PROTON_ANTIZAPRET_ADDRESS" ]]; then
			echo "Proton VPN config for AntiZapret not set! Re-run setup.sh or fill PROTON_ANTIZAPRET_* in /root/antizapret/setup"
		else
			ANTIZAPRET_WARP_ENDPOINT="${PROTON_ANTIZAPRET_ENDPOINT_HOST}:${PROTON_ANTIZAPRET_ENDPOINT_PORT:-51820}"
			ANTIZAPRET_WARP_ADDRESS="${PROTON_ANTIZAPRET_ADDRESS}/32"
			ANTIZAPRET_WARP_IP="$PROTON_ANTIZAPRET_ADDRESS"

			[[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]] && ANTIZAPRET_FWMARK="fwmark 0x2 "

			echo "[Interface]
PrivateKey = $PROTON_ANTIZAPRET_PRIVATE_KEY
Address = $ANTIZAPRET_WARP_ADDRESS
MTU = ${WARP_MTU:-1280}
Table = 13335
PostUp = ip rule add from $IP.29.0.0/16 to $IP.29.0.0/16 lookup main priority 5000 || true
PostUp = ip rule add from $IP.29.0.0/16 ${ANTIZAPRET_FWMARK}lookup 13335 priority 10000 || true
PostDown = ip rule del from $IP.29.0.0/16 to $IP.29.0.0/16 priority 5000
PostDown = ip rule del from $IP.29.0.0/16 ${ANTIZAPRET_FWMARK}lookup 13335 priority 10000

[Peer]
PublicKey = $PROTON_ANTIZAPRET_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $ANTIZAPRET_WARP_ENDPOINT" > $ANTIZAPRET_WARP_PATH

			wg-quick up $ANTIZAPRET_WARP_INTERFACE 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $ANTIZAPRET_WARP_INTERFACE via Proton VPN: $ANTIZAPRET_WARP_ENDPOINT connected"
				if [[ "$ANTIZAPRET_WARP" == '2' ]]; then
					ANTIZAPRET_OUT_INTERFACE=$ANTIZAPRET_WARP_INTERFACE
					ANTIZAPRET_OUT_IP=$ANTIZAPRET_WARP_IP
				fi
			else
				if [[ "$WARP_PROTECTION" == 'y' ]]; then
					echo "Starting $ANTIZAPRET_WARP_INTERFACE (Proton) failed! Blocking traffic"
					iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -j DROP
				else
					echo "Starting $ANTIZAPRET_WARP_INTERFACE (Proton) failed! Use $DEFAULT_INTERFACE"
				fi
			fi
		fi
	else
		if [[ -z "$ANTIZAPRET_WARP_PRIVATE_KEY" || -z "$ANTIZAPRET_WARP_PUBLIC_KEY" || -z "$ANTIZAPRET_WARP_ENDPOINT" || -z "$ANTIZAPRET_WARP_ADDRESS" ]]; then
			ANTIZAPRET_WARP_PRIVATE_KEY=$(wg genkey)
			KEY=$(echo "$ANTIZAPRET_WARP_PRIVATE_KEY" | wg pubkey)
			REG=$(curl -sSfL --connect-timeout 10 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
				-H 'Content-Type: application/json' \
				-d "{\"key\": \"$KEY\"}")

			ANTIZAPRET_WARP_PUBLIC_KEY=$(echo "$REG" | jq -r '.config.peers[0].public_key')
			ANTIZAPRET_WARP_ENDPOINT=$(echo "$REG" | jq -r '.config.peers[0].endpoint.host')
			ANTIZAPRET_WARP_ADDRESS="$(echo "$REG" | jq -r '.config.interface.addresses.v4')/32"
		fi
		ANTIZAPRET_WARP_IP="${ANTIZAPRET_WARP_ADDRESS%%/*}"

		[[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]] && ANTIZAPRET_FWMARK="fwmark 0x2 "

		echo "[Interface]
PrivateKey = $ANTIZAPRET_WARP_PRIVATE_KEY
Address = $ANTIZAPRET_WARP_ADDRESS
MTU = ${WARP_MTU:-1280}
Table = 13335
PostUp = ip rule add from $IP.29.0.0/16 to $IP.29.0.0/16 lookup main priority 5000 || true
PostUp = ip rule add from $IP.29.0.0/16 ${ANTIZAPRET_FWMARK}lookup 13335 priority 10000 || true
PostDown = ip rule del from $IP.29.0.0/16 to $IP.29.0.0/16 priority 5000
PostDown = ip rule del from $IP.29.0.0/16 ${ANTIZAPRET_FWMARK}lookup 13335 priority 10000

[Peer]
PublicKey = $ANTIZAPRET_WARP_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $ANTIZAPRET_WARP_ENDPOINT" > $ANTIZAPRET_WARP_PATH

		wg-quick up $ANTIZAPRET_WARP_INTERFACE 2>/dev/null

		if [[ $? -eq 0 ]]; then
			echo "Started $ANTIZAPRET_WARP_INTERFACE: $ANTIZAPRET_WARP_ENDPOINT connected"
			if [[ "$ANTIZAPRET_WARP" == '2' ]]; then
				ANTIZAPRET_OUT_INTERFACE=$ANTIZAPRET_WARP_INTERFACE
				ANTIZAPRET_OUT_IP=$ANTIZAPRET_WARP_IP
			fi
		else
			if [[ "$WARP_PROTECTION" == 'y' ]]; then
				echo "Starting $ANTIZAPRET_WARP_INTERFACE failed! Blocking traffic"
				iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -j DROP
			else
				echo "Starting $ANTIZAPRET_WARP_INTERFACE failed! Use $DEFAULT_INTERFACE"
			fi
		fi
	fi
	set -e
else
	rm -f $ANTIZAPRET_WARP_PATH
fi

# WARP/Proton VPN (full VPN)
VPN_WARP_INTERFACE=warp-vpn
VPN_WARP_PATH="/etc/wireguard/$VPN_WARP_INTERFACE.conf"

if [[ "$VPN_WARP" == '2' || "$VPN_WARP" == '3' || "$VPN_WARP" == '4' ]]; then
	set +e
	echo "Starting $VPN_WARP_INTERFACE ($WARP_PROVIDER)..."

	if [[ "$WARP_PROVIDER" == 'proton' ]]; then
		if [[ -z "$PROTON_VPN_PRIVATE_KEY" || -z "$PROTON_VPN_PUBLIC_KEY" || -z "$PROTON_VPN_ENDPOINT_HOST" || -z "$PROTON_VPN_ADDRESS" ]]; then
			echo "Proton VPN config for full VPN not set! Re-run setup.sh or fill PROTON_VPN_* in /root/antizapret/setup"
		else
			VPN_WARP_ENDPOINT="${PROTON_VPN_ENDPOINT_HOST}:${PROTON_VPN_ENDPOINT_PORT:-51820}"
			VPN_WARP_ADDRESS="${PROTON_VPN_ADDRESS}/32"
			VPN_WARP_IP="$PROTON_VPN_ADDRESS"

			[[ "$VPN_WARP" == '3' || "$VPN_WARP" == '4' ]] && VPN_FWMARK="fwmark 0x2 "

			echo "[Interface]
PrivateKey = $PROTON_VPN_PRIVATE_KEY
Address = $VPN_WARP_ADDRESS
MTU = ${WARP_MTU:-1280}
Table = 13336
PostUp = ip rule add from $IP.28.0.0/16 to $IP.28.0.0/16 lookup main priority 5000 || true
PostUp = ip rule add from $IP.28.0.0/16 ${VPN_FWMARK}lookup 13336 priority 10000 || true
PostDown = ip rule del from $IP.28.0.0/16 to $IP.28.0.0/16 priority 5000
PostDown = ip rule del from $IP.28.0.0/16 ${VPN_FWMARK}lookup 13336 priority 10000

[Peer]
PublicKey = $PROTON_VPN_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $VPN_WARP_ENDPOINT" > $VPN_WARP_PATH

			wg-quick up $VPN_WARP_INTERFACE 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $VPN_WARP_INTERFACE via Proton VPN: $VPN_WARP_ENDPOINT connected"
				if [[ "$VPN_WARP" == '2' ]]; then
					VPN_OUT_INTERFACE=$VPN_WARP_INTERFACE
					VPN_OUT_IP=$VPN_WARP_IP
				fi
			else
				if [[ "$WARP_PROTECTION" == 'y' ]]; then
					echo "Starting $VPN_WARP_INTERFACE (Proton) failed! Blocking traffic"
					iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -j DROP
				else
					echo "Starting $VPN_WARP_INTERFACE (Proton) failed! Use $DEFAULT_INTERFACE"
				fi
			fi
		fi
	else
		if [[ -z "$VPN_WARP_PRIVATE_KEY" || -z "$VPN_WARP_PUBLIC_KEY" || -z "$VPN_WARP_ENDPOINT" || -z "$VPN_WARP_ADDRESS" ]]; then
			VPN_WARP_PRIVATE_KEY=$(wg genkey)
			KEY=$(echo "$VPN_WARP_PRIVATE_KEY" | wg pubkey)
			REG=$(curl -sSfL --connect-timeout 10 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
				-H 'Content-Type: application/json' \
				-d "{\"key\": \"$KEY\"}")

			VPN_WARP_PUBLIC_KEY=$(echo "$REG" | jq -r '.config.peers[0].public_key')
			VPN_WARP_ENDPOINT=$(echo "$REG" | jq -r '.config.peers[0].endpoint.host')
			VPN_WARP_ADDRESS="$(echo "$REG" | jq -r '.config.interface.addresses.v4')/32"
		fi
		VPN_WARP_IP="${VPN_WARP_ADDRESS%%/*}"

		[[ "$VPN_WARP" == '3' || "$VPN_WARP" == '4' ]] && VPN_FWMARK="fwmark 0x2 "

		echo "[Interface]
PrivateKey = $VPN_WARP_PRIVATE_KEY
Address = $VPN_WARP_ADDRESS
MTU = ${WARP_MTU:-1280}
Table = 13336
PostUp = ip rule add from $IP.28.0.0/16 to $IP.28.0.0/16 lookup main priority 5000 || true
PostUp = ip rule add from $IP.28.0.0/16 ${VPN_FWMARK}lookup 13336 priority 10000 || true
PostDown = ip rule del from $IP.28.0.0/16 to $IP.28.0.0/16 priority 5000
PostDown = ip rule del from $IP.28.0.0/16 ${VPN_FWMARK}lookup 13336 priority 10000

[Peer]
PublicKey = $VPN_WARP_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
Endpoint = $VPN_WARP_ENDPOINT" > $VPN_WARP_PATH

		wg-quick up $VPN_WARP_INTERFACE 2>/dev/null

		if [[ $? -eq 0 ]]; then
			echo "Started $VPN_WARP_INTERFACE: $VPN_WARP_ENDPOINT connected"
			if [[ "$VPN_WARP" == '2' ]]; then
				VPN_OUT_INTERFACE=$VPN_WARP_INTERFACE
				VPN_OUT_IP=$VPN_WARP_IP
			fi
		else
			if [[ "$WARP_PROTECTION" == 'y' ]]; then
				echo "Starting $VPN_WARP_INTERFACE failed! Blocking traffic"
				iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -j DROP
			else
				echo "Starting $VPN_WARP_INTERFACE failed! Use $DEFAULT_INTERFACE"
			fi
		fi
	fi
	set -e
else
	rm -f $VPN_WARP_PATH
fi

# DNS через WARP. Клиентский DNS отвечает локальный kresd, а его запросы к внешним резолверам -
# трафик самого сервера: правила "from $IP.29/$IP.28" и fwmark их не ловят, и они уходили с IP
# сервера. kresd@1 (российские резолверы, ответы для RU-доменов) оставляем на IP сервера, а
# kresd@2 (зарубежные: домены из proxy.rpz/warp.rpz через proxy.py и DNS полного VPN) выводим
# в WARP: адрес источника = адрес WARP-интерфейса, правило "from <адрес>" ведёт в его таблицу.
# Адрес берётся с поднятого интерфейса, поэтому смена провайдера (Proton/Cloudflare), ключей и
# адреса из панели подхватывается тем же up.sh. По умолчанию выключено, как у апстрима (там
# kresd всегда ходит с IP сервера); включить: ANTIZAPRET_WARP_DNS=y в setup или в панели.
KRESD2_OUT_FILE=/etc/knot-resolver/outgoing2.lua
KRESD2_WARP_IP=''
KRESD2_WARP_TABLE=''
# Через WARP пускаем только зарубежные наборы DNS (2 Cloudflare/Quad9/ControlD/UltraDNS, 4 Google,
# 5 AdGuard): российские (1 MSK-IX/НСДИ/ТТК, 3 Яндекс, 6-8 Comss/GeoHide) с зарубежного
# адреса WARP отвечают нестабильно или не отвечают вовсе
case "$(grep -oP '^local dns2 = \K[0-9]+' /etc/knot-resolver/kresd.conf 2>/dev/null)" in
	2|4|5)
		if [[ "$ANTIZAPRET_WARP_DNS" == 'y' ]]; then
			if [[ "$ANTIZAPRET_WARP" =~ ^[234]$ ]] && ip link show dev $ANTIZAPRET_WARP_INTERFACE &>/dev/null; then
				KRESD2_WARP_IP="$(ip -4 -o addr show dev $ANTIZAPRET_WARP_INTERFACE | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
				KRESD2_WARP_TABLE=13335
			elif [[ "$VPN_WARP" =~ ^[234]$ ]] && ip link show dev $VPN_WARP_INTERFACE &>/dev/null; then
				KRESD2_WARP_IP="$(ip -4 -o addr show dev $VPN_WARP_INTERFACE | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
				KRESD2_WARP_TABLE=13336
			fi
		fi
		;;
esac
if [[ -n "$KRESD2_WARP_IP" ]]; then
	ip rule add from $KRESD2_WARP_IP lookup $KRESD2_WARP_TABLE priority 9990
	echo "net.outgoing_v4('$KRESD2_WARP_IP')" > $KRESD2_OUT_FILE.tmp
	chmod 644 $KRESD2_OUT_FILE.tmp
	mv -f $KRESD2_OUT_FILE.tmp $KRESD2_OUT_FILE
	echo "net.outgoing_v4('$KRESD2_WARP_IP')" | socat - /run/knot-resolver/control/2 &>/dev/null || true
	echo "VPN DNS (kresd@2) via WARP: $KRESD2_WARP_IP, table $KRESD2_WARP_TABLE"
else
	rm -f $KRESD2_OUT_FILE
fi

# filter
iptables -w -P INPUT ACCEPT
iptables -w -P FORWARD ACCEPT
iptables -w -P OUTPUT ACCEPT
ip6tables -w -P INPUT ACCEPT
ip6tables -w -P FORWARD ACCEPT
ip6tables -w -P OUTPUT ACCEPT
iptables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
iptables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
iptables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
# Kill-switch для WARP: если политика маршрутизации по fwmark не может отдать пакет в
# warp-antizapret/warp-vpn (интерфейс упал, перезапускается или ещё не поднялся), ядро
# проваливает lookup дальше по правилам и молча уходит в основную таблицу маршрутизации -
# трафик со стоящей меткой 0x2 в этом случае маскарадится через ANTIZAPRET_OUT_INTERFACE
# (см. POSTROUTING ниже, ветку с общим MASQUERADE на весь $IP.28.0.0/15 без фильтра по метке,
# когда ANTIZAPRET_OUT_INTERFACE совпадает с VPN_OUT_INTERFACE) и уходит напрямую, светя
# реальным IP. Жёстко режем такие пакеты, а не даём им прорваться в обход WARP.
if [[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]]; then
	iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -m mark --mark 0x2 ! -o $ANTIZAPRET_WARP_INTERFACE -j DROP
fi
if [[ "$VPN_WARP" == '3' ]]; then
	iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -m mark --mark 0x2 ! -o $VPN_WARP_INTERFACE -j DROP
fi
# Telegram: подсеть 91.105.192.0/23 у части провайдеров не отвечает по IPv4. Приложение при
# этом не переключается на другой рабочий IP Telegram, а уходит пробовать IPv6 и виснет
# насмерть до перезапуска. REJECT вместо тихого DROP даёт клиенту мгновенный отказ
# (TCP RST/ICMP unreachable), и он сам переключается на рабочую подсеть без зависания.
iptables -w -I FORWARD 2 -d 91.105.192.0/23 -j REJECT --reject-with icmp-port-unreachable
iptables -w -I FORWARD 2 -d 91.105.192.0/23 -p tcp -j REJECT --reject-with tcp-reset
# Единственный живой адрес Telegram в этой подсети - исключаем его из REJECT выше.
# Вставляется последним (-I FORWARD 2), поэтому в цепочке проверяется раньше обоих
# REJECT-правил и трафик к нему проходит как обычно.
iptables -w -I FORWARD 2 -d 91.105.192.110 -j ACCEPT
if [[ "$TORRENT_GUARD" == 'y' ]]; then
	ipset create antizapret-torrent hash:ip timeout 60 -exist
	iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -p tcp -m string --string 'GET ' --algo kmp --to 100 -m string --string 'info_hash=' --algo bm -m string --string 'peer_id=' --algo bm -m string --string 'port=' --algo bm -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 3 -s $IP.28.0.0/16 -p udp -m string --string 'BitTorrent protocol' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 4 -s $IP.28.0.0/16 -p udp -m string --string 'd1:ad2:id20:' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 5 -s $IP.28.0.0/16 -m set --match-set antizapret-torrent src -j DROP
fi
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	{
		echo 'create antizapret-forward hash:net -exist'
		echo 'flush antizapret-forward'
		if [[ -f result/forward-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-forward $line"
			done < result/forward-ips.txt
		fi
	} | ipset restore
	iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
fi
{
	echo 'create antizapret-drop hash:net -exist'
	echo 'flush antizapret-drop'
	if [[ -f result/drop-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-drop $cidr"
		done < result/drop-ips.txt
	fi
} | ipset restore
iptables -w -I FORWARD 2 -s $IP.28.0.0/15 -m set --match-set antizapret-drop dst -j DROP
if [[ "$CLIENT_ISOLATION" == 'y' ]]; then
	iptables -w -I FORWARD 2 -s $IP.28.0.0/15 -d $IP.28.0.0/15 -j DROP
	iptables -w -I INPUT 2 -s $IP.28.0.0/15 -p tcp ! --dport 53 -j DROP
	iptables -w -I INPUT 3 -s $IP.28.0.0/15 -p udp ! --dport 53 -j DROP
fi
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-ssh --hashlimit-htable-expire 60000 -j DROP
	ip6tables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-ssh6 --hashlimit-htable-expire 60000 -j DROP
fi
if [[ "$ATTACK_PROTECTION" == 'y' ]]; then
	{
		echo 'create antizapret-allow hash:net -exist'
		echo 'flush antizapret-allow'
		if [[ -f result/allow-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-allow $line"
			done < result/allow-ips.txt
		fi
	} | ipset restore
	ipset create antizapret-block hash:ip timeout 600 -exist
	ipset create antizapret-watch hash:ip,port timeout 600 -exist
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow src -j ACCEPT
	iptables -w -I INPUT 3 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-scan --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	iptables -w -I INPUT 4 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	iptables -w -I INPUT 5 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block src -j DROP
	iptables -w -I INPUT 6 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch src,dst --exist
	ipset create antizapret-allow6 hash:net family inet6 -exist
	ipset create antizapret-block6 hash:ip timeout 600 family inet6 -exist
	ipset create antizapret-watch6 hash:ip,port timeout 600 family inet6 -exist
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow6 src -j ACCEPT
	ip6tables -w -I INPUT 3 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch6 src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-scan6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6tables -w -I INPUT 4 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6tables -w -I INPUT 5 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block6 src -j DROP
	ip6tables -w -I INPUT 6 -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch6 src,dst --exist
fi
if [[ "$SCAN_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmp --icmp-type echo-request -j DROP
	iptables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	iptables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmp --icmp-type port-unreachable -j DROP
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type echo-request -j DROP
	ip6tables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	ip6tables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type port-unreachable -j DROP
fi
{
	echo 'create antizapret-deny hash:net -exist'
	echo 'flush antizapret-deny'
	if [[ -f result/deny-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-deny $cidr"
		done < result/deny-ips.txt
	fi
} | ipset restore
iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-deny src -j DROP

# mangle
# MSS = меньшее из двух (TCPMSS только уменьшает):
# - потолок MTU-40, где MTU измерен в setup.sh пробингом пути (ping -M do к 1.1.1.1), - на случай
#   узкого пути между клиентом и сервером, о котором ядро не знает;
# - --clamp-mss-to-pmtu, как у апстрима: MTU интерфейса, куда реально уходит пакет. Это WARP/Proton
#   (1280-1324), AWG 2/3 с MTU 1280 и т.п. Без него сегменты под 1420 не лезли в эти туннели и
#   держались на ICMP "Fragmentation needed", которые через WARP теряются - скорость падала до килобит.
VPN_MSS=$(( ${MTU:-1420} - 40 ))
# правило добавляется только если его ещё нет: раньше каждый запуск дописывал копию без проверки
iptables -w -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS" 2>/dev/null || iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS"
iptables -w -t mangle -C OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS" 2>/dev/null || iptables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$VPN_MSS"
iptables -w -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -w -t mangle -C OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# Обратное направление через WARP: SYN-ACK от сайта приходит из warp-* и уходит клиенту в туннель
# 1420, clamp-mss-to-pmtu урезает его только до 1380, и клиент шлёт в WARP (1280-1324) слишком
# большие сегменты. Если ICMP "Fragmentation needed" до клиента не доходит, отправка с устройства
# падает до килобит. Урезаем MSS ответов из WARP под его MTU.
WARP_MSS=$(( ${WARP_MTU:-1280} - 40 ))
iptables -w -t mangle -C FORWARD -i warp+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_MSS" 2>/dev/null || iptables -w -t mangle -A FORWARD -i warp+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_MSS"

# Очередь fq (net.core.default_qdisc=fq) пропускает не больше flow_limit=100 пакетов на поток.
# Туннель WireGuard/AmneziaWG на модуле ядра - один поток UDP на клиента без притормаживания
# сокетом, как у amneziawg-go: пачка больше 100 пакетов обрезается (FQ_FLOW_LIMIT), скорость
# скачет и падает. Поднимаем лимит на внешних интерфейсах (на mq - в каждой очереди).
raise_fq_flow_limit() {
	local dev="$1" parent
	[[ -n "$dev" ]] && ip link show dev "$dev" &>/dev/null || return 0
	if tc qdisc show dev "$dev" | grep -q '^qdisc mq '; then
		for parent in $(tc qdisc show dev "$dev" | grep '^qdisc fq ' | grep -oP 'parent \K\S+'); do
			tc qdisc replace dev "$dev" parent "$parent" fq flow_limit 10000 limit 20000 2>/dev/null || true
		done
	elif tc qdisc show dev "$dev" | grep -q '^qdisc fq .* root '; then
		tc qdisc replace dev "$dev" root fq flow_limit 10000 limit 20000 2>/dev/null || true
	fi
}
for dev in $(printf '%s\n' "$DEFAULT_INTERFACE" "$ANTIZAPRET_OUT_INTERFACE" "$VPN_OUT_INTERFACE" | sort -u); do
	raise_fq_flow_limit "$dev"
done
ip6tables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# raw
iptables -w -t raw -A PREROUTING -i lo -j NOTRACK
iptables -w -t raw -A OUTPUT -o lo -j NOTRACK
ip6tables -w -t raw -A PREROUTING -i lo -j NOTRACK
ip6tables -w -t raw -A OUTPUT -o lo -j NOTRACK

# nat
if [[ "$OPENVPN_BACKUP_TCP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 508 -j REDIRECT --to-ports 50080
fi
if [[ "$OPENVPN_BACKUP_UDP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 508 -j REDIRECT --to-ports 50080
fi
if [[ "$WIREGUARD_BACKUP" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 540 -j REDIRECT --to-ports 51443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 580 -j REDIRECT --to-ports 51080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 544 -j REDIRECT --to-ports 53443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 584 -j REDIRECT --to-ports 53080
fi
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
if [[ "$VPN_DNS" == '1' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
fi
# Учёт DNS-запросов клиентов к чужим DNS (1.1.1.1, 8.8.8.8 и т.п.), а не к DNS туннеля: правила без
# цели, только счётчики для панели (Warp Geo -> DNS). mangle идёт раньше DNAT выше, поэтому видит
# исходный адрес назначения. Так видны устройства и роутеры, которые резолвят не через DNS туннеля
for DNS_PROTO in udp tcp; do
	iptables -w -t mangle -A PREROUTING -s $IP.29.0.0/16 ! -d $IP.28.0.0/15 -p $DNS_PROTO --dport 53 -m comment --comment az-dns-foreign
	iptables -w -t mangle -A PREROUTING -s $IP.28.0.0/16 ! -d $IP.28.0.0/15 -p $DNS_PROTO --dport 53 -m comment --comment az-dns-foreign
done
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 ! -d $FAKE_IP.0.0/15 -j CONNMARK --set-mark 0x1
fi
iptables -w -t nat -S ANTIZAPRET-MAPPING &>/dev/null || iptables -w -t nat -N ANTIZAPRET-MAPPING
iptables -w -t nat -A PREROUTING -s $IP.28.0.0/15 -d $FAKE_IP.0.0/15 -j ANTIZAPRET-MAPPING
iptables -w -t mangle -S ANTIZAPRET-WARP &>/dev/null || iptables -w -t mangle -N ANTIZAPRET-WARP
iptables -w -t mangle -A PREROUTING -s $IP.28.0.0/15 -d $FAKE_IP.0.0/15 -j ANTIZAPRET-WARP
if [[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]]; then
	if [[ -z "$ANTIZAPRET_WARP_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -m mark --mark 0x2 -o $ANTIZAPRET_WARP_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -m mark --mark 0x2 -o $ANTIZAPRET_WARP_INTERFACE -j SNAT --to-source $ANTIZAPRET_WARP_IP
	fi
fi
if [[ "$VPN_WARP" == '3' ]]; then
	if [[ -z "$VPN_WARP_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -m mark --mark 0x2 -o $VPN_WARP_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -m mark --mark 0x2 -o $VPN_WARP_INTERFACE -j SNAT --to-source $VPN_WARP_IP
	fi
fi
if [[ "$ANTIZAPRET_OUT_INTERFACE" == "$VPN_OUT_INTERFACE" && "$ANTIZAPRET_OUT_IP" == "$VPN_OUT_IP" ]]; then
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
elif [[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]]; then
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -m mark ! --mark 0x2 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -m mark ! --mark 0x2 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
	if [[ -z "$VPN_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j SNAT --to-source $VPN_OUT_IP
	fi
else
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
	if [[ -z "$VPN_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j SNAT --to-source $VPN_OUT_IP
	fi
fi

# Network tuning
TXQUEUELEN="${TXQUEUELEN:-10000}"
CPU_MASK=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
MTU="${MTU:-1420}"
for dev_path in /sys/class/net/*; do
	dev="${dev_path##*/}"
	[[ "$dev" == "lo" || "$dev" == *docker* ]] && continue
	if [[ -e "/sys/class/net/$dev/device" ]]; then
		ip link set "$dev" txqueuelen "$TXQUEUELEN"
		echo "$CPU_MASK" | tee /sys/class/net/$dev/queues/rx-*/rps_cpus >/dev/null
	else
		if [[ $(cat /sys/class/net/$dev/mtu) -gt $MTU ]]; then
			ip link set "$dev" mtu "$MTU"
		fi
	fi
done

count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/1 | grep -oE '[0-9]+' || echo 0)"
echo "AntiZapret DNS cache cleared: $count entries"
count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/2 | grep -oE '[0-9]+' || echo 0)"
echo "VPN DNS cache cleared: $count entries"

# AWG 3.1: правила 10.9.x пересобираются после каждого запуска антизапрета, если интерфейс awg1 поднят
# (адрес и режим WARP берутся из setup, который только что прочитан)
if [[ -x /usr/local/sbin/awg3-rules.sh ]] && systemctl is-active --quiet awg3@awg1; then
	/usr/local/sbin/awg3-rules.sh up || true
fi

./custom-up.sh
exit 0
