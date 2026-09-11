#!/bin/bash
set -e
export LC_ALL=C
shopt -s nullglob

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

if [[ -n "$1" && "$1" != 'ip' && "$1" != 'ips' && "$1" != 'host' && "$1" != 'hosts' && "$1" != 'noclear' && "$1" != 'noclean' ]]; then
	echo "Ignored invalid parameter: $1"
	set --
fi

echo 'Parse AntiZapret VPN files:'

cd /root/antizapret
rm -rf temp result
mkdir -p temp result
source setup

# --- Точечная очистка кэша по изменившимся доменам ---
# Работает ВСЕГДА, включая noclear/noclean (ночной автозапуск), в отличие
# от полного cache.clear(), который под noclear/noclean намеренно пропускается.
# ВАЖНО: на первой установке control-сокет kresd ещё не существует (служба
# запускается позже), поэтому функция сразу выходит - чистить ещё нечего.
# Также есть лимит max_purge: если изменилось слишком много доменов разом
# (например при первом включении adblock), точечная чистка пропускается -
# в этом случае проще положиться на естественное истечение TTL/полный clear.
purge_changed_names() {
	local old="$1" new="$2" sock="$3" label="$4"
	local max_purge=2000
	local n

	[[ -S "$sock" ]] || return 0
	[[ -f "$old" ]] || touch "$old"
	[[ -f "$new" ]] || return 0

	local changed count=0
	changed="$(diff "$old" "$new" 2>/dev/null | grep -E '^[<>]' | sed -E 's/^[<>] //; s/^\*\.//; s/[[:space:]]+CNAME.*//' | grep -vE '^\$TTL|^@|^;' | sort -u)" || true

	if [[ -z "$changed" ]]; then
		return 0
	fi

	n="$(wc -l <<< "$changed")"
	if (( n > max_purge )); then
		echo "$label: too many changed domains ($n), skipping targeted purge"
		return 0
	fi

	while read -r name; do
		[[ -z "$name" ]] && continue
		echo "cache.clear('$name', true)" | socat - "$sock" &>/dev/null || true
		count=$((count + 1))
	done <<< "$changed"
	echo "$label: targeted cache purge for $count changed domain(s)"
	return 0
}

###
mv -f config/rpz.txt config/deny.txt 2>/dev/null || true
mv -f config/rpz2.txt config/deny2.txt 2>/dev/null || true
mv -f config/deny.txt config/deny-rpz.txt 2>/dev/null || true
mv -f config/deny2.txt config/deny2-rpz.txt 2>/dev/null || true
mv -f config/warp.txt config/warp-rpz.txt 2>/dev/null || true
mv -f config/proxy.txt config/proxy-rpz.txt 2>/dev/null || true

if [[ -f "config/include-hosts.txt" ]] && ! grep -qF 'добавление всех доменов' config/include-hosts.txt; then
	sed -i '/^#   xn--80aswg\.xn--p1ai/a\#   .                      - добавление всех доменов (исключения задаются в config/exclude-hosts.txt)' config/include-hosts.txt
fi

if [[ -f "config/include-warp-hosts.txt" ]] && ! grep -qF 'добавление всех доменов' config/include-warp-hosts.txt; then
	sed -i '/^#   xn--80aswg\.xn--p1ai/a\#   .                      - добавление всех доменов (исключения задаются в config/exclude-warp-hosts.txt)' config/include-warp-hosts.txt
fi

if [[ ! -f "config/include-warp-hosts.txt" ]]; then
	echo '# Добавление доменов для маршрутизации исходящего трафика через WARP
#
# Формат записи: example.com
#
# Строки начинающиеся с # это комментарии и они не обрабатываются
#' > config/include-warp-hosts.txt
fi

if [[ ! -f "config/exclude-warp-hosts.txt" ]]; then
	echo '# Исключение доменов из маршрутизации исходящего трафика через WARP
#
# Формат записи: example.com
#
# Строки начинающиеся с # это комментарии и они не обрабатываются
#' > config/exclude-warp-hosts.txt
fi

if [[ ! -f "config/warp-rpz.txt" ]]; then
	echo '; Настройка RPZ для маршрутизации через WARP
;' > config/warp-rpz.txt
fi

if [[ ! -f "config/proxy-rpz.txt" ]]; then
	echo '; Настройка RPZ для маршрутизации через AntiZapret VPN
;' > config/proxy-rpz.txt
fi
###

for file in config/*.txt; do
	sed -i -e '$a\' "$file"
done

if [[ -z "$1" || "$1" == 'ip' || "$1" == 'ips' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	echo 'IPs...'

	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/*exclude-ips.txt | sort -u > temp/exclude-ips.txt
	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' download/*ips.txt config/*include-ips.txt | sort -u > temp/include-ips.txt

	comm -13 temp/exclude-ips.txt temp/include-ips.txt > temp/route-ips.txt

	awk -F'[/.]' 'NF==5 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 && $5>=1 && $5<=32 {print}' temp/route-ips.txt > result/route-ips.txt

	echo "$(wc -l < result/route-ips.txt) - route-ips.txt"

	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/*drop-ips.txt | sort -u \
	| awk -F'[/.]' 'NF==5 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 && $5>=1 && $5<=32 {print}' > result/drop-ips.txt

	echo "$(wc -l < result/drop-ips.txt) - drop-ips.txt"

	{
		echo 'create antizapret-drop hash:net -exist'
		echo 'flush antizapret-drop'
		while read -r cidr; do
			echo "add antizapret-drop $cidr -exist"
		done < result/drop-ips.txt
	} | ipset restore

	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/*deny-ips.txt | sort -u \
	| awk -F'[/.]' 'NF==5 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 && $5>=1 && $5<=32 {print}' > result/deny-ips.txt

	echo "$(wc -l < result/deny-ips.txt) - deny-ips.txt"

	{
		echo 'create antizapret-deny hash:net -exist'
		echo 'flush antizapret-deny'
		while read -r cidr; do
			echo "add antizapret-deny $cidr -exist"
		done < result/deny-ips.txt
	} | ipset restore

	[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP="${CLIENT_IP:-172}" || IP=10
	[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && FAKE_IP="${FAKE_IP:-198.18}" || FAKE_IP="$IP.30"

	echo "push \"route $FAKE_IP.0.0 255.254.0.0\"" > result/DEFAULT
	echo -e "route 0.0.0.0 128.0.0.0 net_gateway\nroute 128.0.0.0 128.0.0.0 net_gateway\nroute $IP.29.0.0 255.255.0.0\nroute $FAKE_IP.0.0 255.254.0.0" > result/tp-link-openvpn-routes.txt
	echo -e "route ADD DNS_IP_1 MASK 255.255.255.255 $IP.29.8.1\nroute ADD DNS_IP_2 MASK 255.255.255.255 $IP.29.8.1\nroute ADD $FAKE_IP.0.0 MASK 255.254.0.0 $IP.29.8.1" > result/keenetic-wireguard-routes.txt
	echo "/ip route add dst-address=$FAKE_IP.0.0/15 gateway=$IP.29.8.1 distance=1 comment=\"antizapret-wireguard\"" > result/mikrotik-wireguard-routes.txt
	# AmneziaWG 2.0 - отдельный шлюз (antizapret2, .9.1), т.к. WireGuard/AmneziaWG 1.5 (antizapret, .8.1)
	# и AmneziaWG 2.0 (antizapret2, .9.1) - разные интерфейсы с разными адресами на сервере, роутер
	# должен слать эти маршруты именно на шлюз своего протокола, иначе они уйдут не в тот туннель
	echo -e "route ADD DNS_IP_1 MASK 255.255.255.255 $IP.29.9.1\nroute ADD DNS_IP_2 MASK 255.255.255.255 $IP.29.9.1\nroute ADD $FAKE_IP.0.0 MASK 255.254.0.0 $IP.29.9.1" > result/keenetic-amneziawg2-routes.txt
	echo "/ip route add dst-address=$FAKE_IP.0.0/15 gateway=$IP.29.9.1 distance=1 comment=\"antizapret-amneziawg2\"" > result/mikrotik-amneziawg2-routes.txt
	while read -r cidr; do
		NET="$(echo "$cidr" | awk -F '/' '{print $1}')"
		MASK="$(sipcalc -- "$cidr" | awk '/Network mask/ {print $4; exit;}')"
		echo "push \"route $NET $MASK\"" >> result/DEFAULT
		echo "route $NET $MASK" >> result/tp-link-openvpn-routes.txt
		echo "route ADD $NET MASK $MASK $IP.29.8.1" >> result/keenetic-wireguard-routes.txt
		echo "/ip route add dst-address=$cidr gateway=$IP.29.8.1 distance=1 comment=\"antizapret-wireguard\"" >> result/mikrotik-wireguard-routes.txt
		echo "route ADD $NET MASK $MASK $IP.29.9.1" >> result/keenetic-amneziawg2-routes.txt
		echo "/ip route add dst-address=$cidr gateway=$IP.29.9.1 distance=1 comment=\"antizapret-amneziawg2\"" >> result/mikrotik-amneziawg2-routes.txt
	done < result/route-ips.txt

	mkdir -p /etc/openvpn/server/ccd
	if [[ -f result/DEFAULT ]] && ! diff -q result/DEFAULT /etc/openvpn/server/ccd/DEFAULT; then
		cp -f result/DEFAULT /etc/openvpn/server/ccd/DEFAULT
	fi

	echo -n ", $FAKE_IP.0.0/15" > result/ips
	awk '{printf ", %s", $0}' result/route-ips.txt >> result/ips

	if [[ -f result/ips ]] && ! diff -q result/ips /etc/wireguard/ips; then
		cp -f result/ips /etc/wireguard/ips
	fi

	if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
		sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/*forward-ips.txt temp/route-ips.txt | sort -u \
		| awk -F'[/.]' 'NF==5 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 && $5>=1 && $5<=32 {print}' > result/forward-ips.txt

		echo "$(wc -l < result/forward-ips.txt) - forward-ips.txt"

		{
			echo 'create antizapret-forward hash:net -exist'
			echo 'flush antizapret-forward'
			while read -r cidr; do
				echo "add antizapret-forward $cidr -exist"
			done < result/forward-ips.txt
		} | ipset restore
	fi

	if [[ "$ATTACK_PROTECTION" == 'y' ]]; then
		sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d' config/*allow-ips.txt | sort -u \
		| awk -F'[/.]' 'NF==5 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 && $5>=1 && $5<=32 {print}' > result/allow-ips.txt

		echo "$(wc -l < result/allow-ips.txt) - allow-ips.txt"

		{
			echo 'create antizapret-allow hash:net -exist'
			echo 'flush antizapret-allow'
			while read -r cidr; do
				echo "add antizapret-allow $cidr -exist"
			done < result/allow-ips.txt
		} | ipset restore
	fi
fi

if [[ -z "$1" || "$1" == 'host' || "$1" == 'hosts' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	echo 'Hosts...'

	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' download/*include-adblock-hosts.txt config/*include-adblock-hosts.txt > temp/include-adblock-hosts.txt
	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' download/*exclude-adblock-hosts.txt config/*exclude-adblock-hosts.txt > temp/exclude-adblock-hosts.txt

	[[ -n "$(compgen -G 'download/*adguard.txt')" ]] && \
	sed -n '/\*/!s/^||\([^ ]*\)\^.*$/\1/p' download/*adguard.txt | sed -E 's/.*/\L&/; /^[0-9.]+$/d' >> temp/include-adblock-hosts.txt

	[[ -n "$(compgen -G 'download/*adguard.txt')" ]] && \
	sed -n '/\*/!s/^@@||\([^ ]*\)\^.*$/\1/p' download/*adguard.txt | sed -E 's/.*/\L&/; /^[0-9.]+$/d' >> temp/exclude-adblock-hosts.txt

	sort -u temp/include-adblock-hosts.txt > result/include-adblock-hosts.txt
	sort -u temp/exclude-adblock-hosts.txt > result/exclude-adblock-hosts.txt

	echo "$(wc -l < result/include-adblock-hosts.txt) - include-adblock-hosts.txt"
	echo "$(wc -l < result/exclude-adblock-hosts.txt) - exclude-adblock-hosts.txt"

	echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > temp/deny.rpz
	echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > temp/deny2.rpz

	if [[ "$ANTIZAPRET_ADBLOCK" == 'y' ]]; then
		sed 's/$/ CNAME ./; p; s/^/*./' result/include-adblock-hosts.txt >> temp/deny.rpz
		sed 's/$/ CNAME rpz-passthru./; p; s/^/*./' result/exclude-adblock-hosts.txt >> temp/deny.rpz
	fi
	sed 's/\r//g; /^;/d; /^$/d' download/*deny-rpz.txt config/*deny-rpz.txt >> temp/deny.rpz
	cp temp/deny.rpz result/deny.rpz

	if [[ "$VPN_ADBLOCK" == 'y' ]]; then
		sed 's/$/ CNAME ./; p; s/^/*./' result/include-adblock-hosts.txt >> temp/deny2.rpz
		sed 's/$/ CNAME rpz-passthru./; p; s/^/*./' result/exclude-adblock-hosts.txt >> temp/deny2.rpz
	fi
	sed 's/\r//g; /^;/d; /^$/d' download/*deny2-rpz.txt config/*deny2-rpz.txt >> temp/deny2.rpz
	cp temp/deny2.rpz result/deny2.rpz

	if [[ -f result/deny.rpz ]] && ! diff -q result/deny.rpz /etc/knot-resolver/deny.rpz; then
		purge_changed_names /etc/knot-resolver/deny.rpz result/deny.rpz /run/knot-resolver/control/1 'deny.rpz'
		cp -f result/deny.rpz /etc/knot-resolver/deny.rpz.tmp
		mv -f /etc/knot-resolver/deny.rpz.tmp /etc/knot-resolver/deny.rpz
		sleep 5
	fi

	if [[ -f result/deny2.rpz ]] && ! diff -q result/deny2.rpz /etc/knot-resolver/deny2.rpz; then
		purge_changed_names /etc/knot-resolver/deny2.rpz result/deny2.rpz /run/knot-resolver/control/2 'deny2.rpz'
		cp -f result/deny2.rpz /etc/knot-resolver/deny2.rpz.tmp
		mv -f /etc/knot-resolver/deny2.rpz.tmp /etc/knot-resolver/deny2.rpz
		sleep 5
	fi

	sed -E 's/[\r[:space:]]+//g; /^\.$/!{/^[[:punct:]]/d;}; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' download/*include-hosts.txt config/*include-hosts.txt > temp/include-hosts.txt
	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' download/*exclude-hosts.txt config/*exclude-hosts.txt | sort -u > temp/exclude-hosts.txt
	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' download/*remove-hosts.txt config/*remove-hosts.txt | sort -u > temp/remove-hosts.txt
	sed -E 's/[\r[:space:]]+//g; /^\.$/!{/^[[:punct:]]/d;}; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' config/*include-warp-hosts.txt | sort -u > result/include-warp-hosts.txt
	sed -E 's/[\r[:space:]]+//g; /^[[:punct:]]/d; /^$/d; s/[]_~:/?#\[@!$&'\''()*+,;=].*//; s/.*/\L&/' config/*exclude-warp-hosts.txt | sort -u > result/exclude-warp-hosts.txt

	# nice/ionice: обработка ~3.3М строк из download/*domain.txt через sed+idn
	# даёт кратковременный (~4 сек), но заметный пик CPU на обоих ядрах разом
	# (sed и idn грузят каждый своё ядро параллельно через пайп). На слабых VPS
	# это может конкурировать с другими процессами за CPU/IO в момент старта
	# antizapret.service - понижаем приоритет, чтобы не мешать остальной системе.
	# Результат не меняется, меняется только скорость/приоритет выполнения.
	[[ -n "$(compgen -G 'download/*domain.txt')" ]] && \
	nice -n 19 ionice -c3 sed -n 's/^[[:punct:]]\+//; s/[[:punct:]]\+$//; /\./{s/.*/\L&/; /^[а-яa-z0-9.-]\+$/p}' download/*domain.txt \
	| CHARSET=UTF-8 nice -n 19 ionice -c3 idn --no-tld >> temp/include-hosts.txt

	if [[ "$CLEAR_HOSTS" == 'y' ]]; then
		grep -Evi '[ck]a+[szc3]+[iley1]+n+[0-9o]|[vw][uy]+[l1]+[kc]a+n|[vw]a+[vw]+a+d+a|x-*bet|most-*bet|leon-*bet|rio-*bet|mel-*bet|ramen-*bet|marathon-*bet|max-*bet|bet-*win|gg-*bet|spin-*bet|banzai-*bet|1iks-*bet|x-*slot|sloto-*zal|max-*slot|bk-*leon|gold-*fishka|play-*fortuna|dragon-*money|poker-*dom|1-*win|crypto-*bos|free-*spin|fair-*spin|no-*deposit|igrovye|avtomaty|bookmaker|zerkalo|slottica|sykaaa|admiral-*x|x-*admiral|pinup-*bet|pari-*match|betting|partypoker|jackpot|bonus|azino[0-9-]|888-*starz|zooma[0-9-]|zenit-*bet|eldorado|slots|vodka|newretro|platinum|igrat|flagman|arkada' temp/include-hosts.txt | sort -u > temp/include-hosts2.txt
	else
		sort -u temp/include-hosts.txt > temp/include-hosts2.txt
	fi

	comm -13 temp/remove-hosts.txt temp/include-hosts2.txt > temp/include-hosts3.txt
	comm -13 temp/remove-hosts.txt temp/exclude-hosts.txt > result/exclude-hosts.txt

	if [[ "$ROUTE_ALL" == 'y' ]]; then
		sed -E '/\..*\./ s/^([0-9]*www[0-9]*|hd[0-9]*|[0-9]+)\.//' temp/include-hosts3.txt > temp/include-hosts4.txt
	else
		sed -E '/\..*\./ s/^([0-9]*www[0-9]*|hd[0-9]*|[0-9]+)\.//' temp/include-hosts3.txt result/exclude-hosts.txt > temp/include-hosts4.txt
	fi

	# --- Схлопывание избыточных поддоменов ---
	rev temp/include-hosts4.txt | LC_ALL=C sort | awk '
	BEGIN { last = "" }
	{
		if (last != "" && (index($0, last ".") == 1 || $0 == last)) {
			next
		}
		last = $0
		print $0
	}' | rev | LC_ALL=C sort -u > temp/include-hosts5.txt

	if [[ "$ROUTE_ALL" == 'y' ]]; then
		sed '1i.' temp/include-hosts5.txt > result/include-hosts.txt
	else
		comm -23 temp/include-hosts5.txt result/exclude-hosts.txt > result/include-hosts.txt
	fi

	echo "$(wc -l < result/include-hosts.txt) - include-hosts.txt"
	echo "$(wc -l < result/exclude-hosts.txt) - exclude-hosts.txt"
	echo "$(wc -l < result/include-warp-hosts.txt) - include-warp-hosts.txt"
	echo "$(wc -l < result/exclude-warp-hosts.txt) - exclude-warp-hosts.txt"

	echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > temp/proxy.rpz
	sed '/^\.$/ s/.*/*. CNAME ./; t; s/$/ CNAME ./; p; s/^/*./' result/include-hosts.txt >> temp/proxy.rpz
	sed '/^\.$/ s/.*/*. CNAME rpz-passthru./; t; s/$/ CNAME rpz-passthru./; p; s/^/*./' result/exclude-hosts.txt >> temp/proxy.rpz
	sed 's/\r//g; /^;/d; /^$/d' config/*proxy-rpz.txt >> temp/proxy.rpz
	cp temp/proxy.rpz result/proxy.rpz

	if [[ -f result/proxy.rpz ]] && ! diff -q result/proxy.rpz /etc/knot-resolver/proxy.rpz; then
		purge_changed_names /etc/knot-resolver/proxy.rpz result/proxy.rpz /run/knot-resolver/control/1 'proxy.rpz'
		cp -f result/proxy.rpz /etc/knot-resolver/proxy.rpz.tmp
		mv -f /etc/knot-resolver/proxy.rpz.tmp /etc/knot-resolver/proxy.rpz
		sleep 5
	fi

	if [[ "$ANTIZAPRET_WARP" == '3' ]]; then
		cp temp/proxy.rpz temp/warp.rpz
	else
		echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > temp/warp.rpz
	fi
	sed '/^\.$/ s/.*/*. CNAME ./; t; s/$/ CNAME ./; p; s/^/*./' result/include-warp-hosts.txt >> temp/warp.rpz
	sed '/^\.$/ s/.*/*. CNAME rpz-passthru./; t; s/$/ CNAME rpz-passthru./; p; s/^/*./' result/exclude-warp-hosts.txt >> temp/warp.rpz
	sed 's/\r//g; /^;/d; /^$/d' config/*warp-rpz.txt >> temp/warp.rpz
	cp temp/warp.rpz result/warp.rpz

	if [[ -f result/warp.rpz ]] && ! diff -q result/warp.rpz /etc/knot-resolver/warp.rpz; then
		purge_changed_names /etc/knot-resolver/warp.rpz result/warp.rpz /run/knot-resolver/control/1 'warp.rpz'
		cp -f result/warp.rpz /etc/knot-resolver/warp.rpz.tmp
		mv -f /etc/knot-resolver/warp.rpz.tmp /etc/knot-resolver/warp.rpz
		sleep 5
	fi

	if [[ "$1" != 'noclear' && "$1" != 'noclean' ]]; then
		count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/1 | grep -oE '[0-9]+' || echo 0)"
		echo "AntiZapret DNS cache cleared: $count entries"
		count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/2 | grep -oE '[0-9]+' || echo 0)"
		echo "VPN DNS cache cleared: $count entries"
	fi
fi

./custom-parse.sh "$1" || true

exit 0
