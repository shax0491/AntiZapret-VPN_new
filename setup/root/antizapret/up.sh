#!/bin/bash
set -e
shopt -s nullglob

cd /root/antizapret

./down.sh

source setup

WARP_PROVIDER="${WARP_PROVIDER:-cloudflare}"

# Регистрация в Cloudflare WARP с повторными попытками. Один неудачный запрос к их API
# (сетевой сбой, троттлинг) раньше давал пустой ответ, jq тихо возвращал "null"/пустую
# строку, и скрипт поднимал wg-интерфейс с обрезанным конфигом (без PublicKey/Endpoint) -
# либо получал заведомо нерабочий туннель, либо (в режиме "2", когда WARP - это основной
# исходящий канал) молча оставался на основном интерфейсе сервера. Теперь при неудаче
# всех попыток конфиг не создаётся и не поднимается вообще, а ключи возвращаются в
# заведомо пустое состояние - вызывающий код обязан явно сообщить об ошибке.
warp_cf_register() {
	local pubkey="$1" attempt reg pub ep addr
	for attempt in 1 2 3; do
		reg="$(curl -sSL --connect-timeout 10 --max-time 20 -X POST 'https://api.cloudflareclient.com/v0a2158/reg' \
			-H 'Content-Type: application/json' -d "{\"key\": \"$pubkey\"}" 2>/dev/null)" || true
		pub="$(echo "$reg" | jq -r '.config.peers[0].public_key' 2>/dev/null)" || true
		ep="$(echo "$reg" | jq -r '.config.peers[0].endpoint.host' 2>/dev/null)" || true
		addr="$(echo "$reg" | jq -r '.config.interface.addresses.v4' 2>/dev/null)" || true
		if [[ -n "$pub" && "$pub" != 'null' && -n "$ep" && "$ep" != 'null' && -n "$addr" && "$addr" != 'null' ]]; then
			WARP_REG_PUBLIC_KEY="$pub"
			WARP_REG_ENDPOINT="$ep"
			WARP_REG_ADDRESS="$addr"
			return 0
		fi
		[[ "$attempt" -lt 3 ]] && sleep 3
	done
	return 1
}

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
MTU = 1420
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

			wg-quick up $ANTIZAPRET_WARP_PATH 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $ANTIZAPRET_WARP_INTERFACE via Proton VPN: $ANTIZAPRET_WARP_ENDPOINT connected"
				if [[ "$ANTIZAPRET_WARP" == '2' ]]; then
					ANTIZAPRET_OUT_INTERFACE=$ANTIZAPRET_WARP_INTERFACE
					ANTIZAPRET_OUT_IP=$ANTIZAPRET_WARP_IP
				fi
			else
				echo "Starting $ANTIZAPRET_WARP_INTERFACE (Proton) failed! Use $DEFAULT_INTERFACE"
			fi
		fi
	else
		if [[ -z "$ANTIZAPRET_WARP_PRIVATE_KEY" || -z "$ANTIZAPRET_WARP_PUBLIC_KEY" || -z "$ANTIZAPRET_WARP_ENDPOINT" || -z "$ANTIZAPRET_WARP_ADDRESS" ]]; then
			ANTIZAPRET_WARP_PRIVATE_KEY=$(wg genkey)
			KEY=$(echo "$ANTIZAPRET_WARP_PRIVATE_KEY" | wg pubkey)
			if warp_cf_register "$KEY"; then
				ANTIZAPRET_WARP_PUBLIC_KEY="$WARP_REG_PUBLIC_KEY"
				ANTIZAPRET_WARP_ENDPOINT="$WARP_REG_ENDPOINT"
				ANTIZAPRET_WARP_ADDRESS="$WARP_REG_ADDRESS/32"

				# Эндпоинт, который сама Cloudflare выдаёт при регистрации, часто ведёт на
				# московский узел (DME) с российской гео-локацией и DPI-фильтрацией с апреля
				# 2026. Если warpscout (update.sh, раз в несколько дней) нашёл рабочий не-RU
				# эндпоинт - используем его вместо предложенного Cloudflare. Публичный ключ
				# пира общий для всех эндпоинтов WARP, поэтому подмена совместима с любым
				# зарегистрированным ключом.
				if [[ -s /etc/wireguard/warpscout-endpoint ]]; then
					WARPSCOUT_EP="$(cat /etc/wireguard/warpscout-endpoint)"
					if [[ "$WARPSCOUT_EP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
						ANTIZAPRET_WARP_ENDPOINT="$WARPSCOUT_EP"
					fi
				fi
			else
				ANTIZAPRET_WARP_PRIVATE_KEY=
			fi
		fi

		if [[ -z "$ANTIZAPRET_WARP_PRIVATE_KEY" || -z "$ANTIZAPRET_WARP_PUBLIC_KEY" || -z "$ANTIZAPRET_WARP_ENDPOINT" || -z "$ANTIZAPRET_WARP_ADDRESS" ]]; then
			echo -e "\e[1;31mError: Cloudflare WARP registration for $ANTIZAPRET_WARP_INTERFACE failed after retries! Traffic will use $DEFAULT_INTERFACE.\e[0m"
			rm -f $ANTIZAPRET_WARP_PATH
		else
			ANTIZAPRET_WARP_IP="${ANTIZAPRET_WARP_ADDRESS%%/*}"

			[[ "$ANTIZAPRET_WARP" == '3' || "$ANTIZAPRET_WARP" == '4' ]] && ANTIZAPRET_FWMARK="fwmark 0x2 "

			echo "[Interface]
PrivateKey = $ANTIZAPRET_WARP_PRIVATE_KEY
Address = $ANTIZAPRET_WARP_ADDRESS
MTU = 1420
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

			wg-quick up $ANTIZAPRET_WARP_PATH 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $ANTIZAPRET_WARP_INTERFACE: $ANTIZAPRET_WARP_ENDPOINT connected"
				if [[ "$ANTIZAPRET_WARP" == '2' ]]; then
					ANTIZAPRET_OUT_INTERFACE=$ANTIZAPRET_WARP_INTERFACE
					ANTIZAPRET_OUT_IP=$ANTIZAPRET_WARP_IP
				fi
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

if [[ "$VPN_WARP" == '2' || "$VPN_WARP" == '3' ]]; then
	set +e
	echo "Starting $VPN_WARP_INTERFACE ($WARP_PROVIDER)..."

	if [[ "$WARP_PROVIDER" == 'proton' ]]; then
		if [[ -z "$PROTON_VPN_PRIVATE_KEY" || -z "$PROTON_VPN_PUBLIC_KEY" || -z "$PROTON_VPN_ENDPOINT_HOST" || -z "$PROTON_VPN_ADDRESS" ]]; then
			echo "Proton VPN config for full VPN not set! Re-run setup.sh or fill PROTON_VPN_* in /root/antizapret/setup"
		else
			VPN_WARP_ENDPOINT="${PROTON_VPN_ENDPOINT_HOST}:${PROTON_VPN_ENDPOINT_PORT:-51820}"
			VPN_WARP_ADDRESS="${PROTON_VPN_ADDRESS}/32"
			VPN_WARP_IP="$PROTON_VPN_ADDRESS"

			[[ "$VPN_WARP" == '3' ]] && VPN_FWMARK="fwmark 0x2 "

			echo "[Interface]
PrivateKey = $PROTON_VPN_PRIVATE_KEY
Address = $VPN_WARP_ADDRESS
MTU = 1420
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

			wg-quick up $VPN_WARP_PATH 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $VPN_WARP_INTERFACE via Proton VPN: $VPN_WARP_ENDPOINT connected"
				if [[ "$VPN_WARP" == '2' ]]; then
					VPN_OUT_INTERFACE=$VPN_WARP_INTERFACE
					VPN_OUT_IP=$VPN_WARP_IP
				fi
			else
				echo "Starting $VPN_WARP_INTERFACE (Proton) failed! Use $DEFAULT_INTERFACE"
			fi
		fi
	else
		if [[ -z "$VPN_WARP_PRIVATE_KEY" || -z "$VPN_WARP_PUBLIC_KEY" || -z "$VPN_WARP_ENDPOINT" || -z "$VPN_WARP_ADDRESS" ]]; then
			VPN_WARP_PRIVATE_KEY=$(wg genkey)
			KEY=$(echo "$VPN_WARP_PRIVATE_KEY" | wg pubkey)
			if warp_cf_register "$KEY"; then
				VPN_WARP_PUBLIC_KEY="$WARP_REG_PUBLIC_KEY"
				VPN_WARP_ENDPOINT="$WARP_REG_ENDPOINT"
				VPN_WARP_ADDRESS="$WARP_REG_ADDRESS/32"

				# См. пояснение у ANTIZAPRET_WARP выше - используем найденный warpscout'ом
				# не-RU эндпоинт вместо предложенного Cloudflare, если он есть в кэше.
				if [[ -s /etc/wireguard/warpscout-endpoint ]]; then
					WARPSCOUT_EP="$(cat /etc/wireguard/warpscout-endpoint)"
					if [[ "$WARPSCOUT_EP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
						VPN_WARP_ENDPOINT="$WARPSCOUT_EP"
					fi
				fi
			else
				VPN_WARP_PRIVATE_KEY=
			fi
		fi

		if [[ -z "$VPN_WARP_PRIVATE_KEY" || -z "$VPN_WARP_PUBLIC_KEY" || -z "$VPN_WARP_ENDPOINT" || -z "$VPN_WARP_ADDRESS" ]]; then
			echo -e "\e[1;31mError: Cloudflare WARP registration for $VPN_WARP_INTERFACE failed after retries! Traffic will use $DEFAULT_INTERFACE.\e[0m"
			rm -f $VPN_WARP_PATH
		else
			VPN_WARP_IP="${VPN_WARP_ADDRESS%%/*}"

			[[ "$VPN_WARP" == '3' ]] && VPN_FWMARK="fwmark 0x2 "

			echo "[Interface]
PrivateKey = $VPN_WARP_PRIVATE_KEY
Address = $VPN_WARP_ADDRESS
MTU = 1420
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

			wg-quick up $VPN_WARP_PATH 2>/dev/null

			if [[ $? -eq 0 ]]; then
				echo "Started $VPN_WARP_INTERFACE: $VPN_WARP_ENDPOINT connected"
				if [[ "$VPN_WARP" == '2' ]]; then
					VPN_OUT_INTERFACE=$VPN_WARP_INTERFACE
					VPN_OUT_IP=$VPN_WARP_IP
				fi
			else
				echo "Starting $VPN_WARP_INTERFACE failed! Use $DEFAULT_INTERFACE"
			fi
		fi
	fi
	set -e
else
	rm -f $VPN_WARP_PATH
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
iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
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
fi
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080
iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
if [[ "$VPN_DNS" == '1' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
fi
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
SEGMENTATION_OFFLOAD="${SEGMENTATION_OFFLOAD:-off}"
TXQUEUELEN="${TXQUEUELEN:-10000}"
CPU_MASK=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
MTU="${MTU:-1420}"
for dev in $(ls /sys/class/net); do
	[[ "$dev" == "lo" || "$dev" == *docker* ]] && continue
	ethtool -K "$dev" tso "$SEGMENTATION_OFFLOAD" gso "$SEGMENTATION_OFFLOAD" gro "$SEGMENTATION_OFFLOAD"
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

./custom-up.sh
exit 0
