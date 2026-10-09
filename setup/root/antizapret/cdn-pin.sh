#!/bin/bash
# Проверенные узлы CDN для kresd@2.
# Часть CDN (например, bunny у image.tmdb.org) по геолокации DNS-запроса из WARP отдаёт узлы
# без сертификата нужного сайта: TLS рвётся, у клиентов не грузятся картинки. Скрипт сравнивает
# ответ, который видит kresd@2 (через WARP), с ответами обычных DNS, проверяет каждый адрес
# HTTPS-запросом с нужным SNI и закрепляет в /etc/knot-resolver/cdn-pin.lua только рабочие.
# Уже выданные клиентам подменные адреса, которые смотрят на неработающий узел,
# перенаправляются на рабочий.
# Домены: config/cdn-pin-hosts.txt (по одному в строке), по умолчанию image.tmdb.org
set -u
export LC_ALL=C
cd /root/antizapret || exit 1

OUT=/etc/knot-resolver/cdn-pin.lua
HOSTS_FILE=config/cdn-pin-hosts.txt
RESOLVERS='1.1.1.1 8.8.8.8 9.9.9.10 76.76.2.0 64.6.64.6'
# Резолверы kresd@2 (forward(2) в kresd.conf)
KRESD2_RESOLVERS='1.1.1.1 1.0.0.1 9.9.9.10 149.112.112.10 76.76.2.0 76.76.10.0 64.6.64.6 64.6.65.6'
MAX_IPS=4

# Таймер ставим сами: update.sh приносит только скрипты, а systemd-юниты - только setup.sh
if [[ ! -f /etc/systemd/system/cdn-pin.timer ]]; then
	cat > /etc/systemd/system/cdn-pin.service <<-'EOF'
	[Unit]
	Description=Check CDN nodes for kresd@2 (cdn-pin.sh)
	After=antizapret.service network-online.target
	Wants=network-online.target

	[Service]
	Type=oneshot
	WorkingDirectory=/root/antizapret
	ExecStart=/root/antizapret/cdn-pin.sh
	TimeoutSec=5m
	EOF
	cat > /etc/systemd/system/cdn-pin.timer <<-'EOF'
	[Unit]
	Description=Hourly CDN node check for kresd@2 (cdn-pin.sh)

	[Timer]
	OnBootSec=10m
	OnUnitActiveSec=1h
	RandomizedDelaySec=5m

	[Install]
	WantedBy=timers.target
	EOF
	systemctl daemon-reload
	systemctl enable --now cdn-pin.timer &>/dev/null || true
fi

if [[ -s "$HOSTS_FILE" ]]; then
	HOSTS="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$HOSTS_FILE" | grep -v '^$' | sort -u)"
else
	HOSTS='image.tmdb.org'
fi

# Адрес, с которого kresd@2 ходит в WARP (up.sh пишет его в outgoing2.lua)
WARP_SRC="$(grep -oE "[0-9]+(\.[0-9]+){3}" /etc/knot-resolver/outgoing2.lua 2>/dev/null | head -1)"

a_records() { # resolver [source]
	dig +short +time=3 +tries=1 ${2:+-b "$2"} @"$1" "$HOST" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$'
}

works() { # ip
	local code
	code="$(curl -sS -o /dev/null -m 6 -w '%{http_code}' --resolve "$HOST:443:$1" "https://$HOST/" 2>/dev/null)"
	[[ -n "$code" && "$code" != 000 ]]
}

LUA="-- Сгенерировано cdn-pin.sh $(date '+%F %T'), не редактировать"$'\n'
declare -A BAD_TO_GOOD=()

for HOST in $HOSTS; do
	# Уже закреплённые адреса: пока они работают, оставляем как есть (без перезапуска kresd@2)
	PINNED="$(grep -F "todname('$HOST')" "$OUT" 2>/dev/null | grep -oE "[0-9]+(\.[0-9]+){3}")"
	# Как видит kresd@2: его же резолверы (forward(2) в kresd.conf) с адреса WARP, плюс сам
	# kresd@2, пока домен не закреплён (иначе он вернёт уже закреплённые адреса)
	WARP_IPS="$(
		for r in $KRESD2_RESOLVERS; do a_records "$r" "$WARP_SRC"; done
		[[ -z "$PINNED" ]] && a_records 127.2.2.2
	)"
	OTHER_IPS="$(for r in $RESOLVERS; do a_records "$r"; done)"
	CANDIDATES="$(printf '%s\n' $PINNED $WARP_IPS $OTHER_IPS | awk 'NF && !seen[$0]++')"
	[[ -z "$CANDIDATES" ]] && continue

	GOOD=() BAD=()
	for ip in $CANDIDATES; do
		if works "$ip"; then GOOD+=("$ip"); else BAD+=("$ip"); fi
	done
	if [[ ${#GOOD[@]} -eq 0 ]]; then
		echo "$HOST: no working nodes, not pinned"
		continue
	fi

	# Закрепляем всегда: ответ через WARP меняется от запроса к запросу, неработающий узел
	# появляется не каждый раз
	GOOD=("${GOOD[@]:0:$MAX_IPS}")
	echo "$HOST: ${GOOD[*]}${BAD:+ (bad: ${BAD[*]})}"
	RDATA="$(printf "kres.str2ip('%s'), " "${GOOD[@]}")"
	LUA+="policy.add(policy.domains(policy.ANSWER({[kres.type.A] = {rdata = {${RDATA%, }}, ttl = 600}}), {todname('$HOST')}))"$'\n'
	for ip in "${BAD[@]}"; do
		BAD_TO_GOOD[$ip]="${GOOD[0]}"
	done
done

OLD="$(grep -v '^--' "$OUT" 2>/dev/null)"
NEW="$(printf '%s' "$LUA" | grep -v '^--')"
if [[ "$OLD" != "$NEW" ]]; then
	if [[ -z "$NEW" ]]; then
		rm -f "$OUT"
	else
		printf '%s' "$LUA" > "$OUT"
	fi
	systemctl restart kresd@2
	echo "kresd@2 restarted"
fi

# Подменные адреса, уже выданные клиентам и ведущие на неработающий узел
for bad in "${!BAD_TO_GOOD[@]}"; do
	iptables -w -t nat -S ANTIZAPRET-MAPPING 2>/dev/null | grep -E -- "--to-destination ${bad//./\\.}$" | grep -oE -- '-d [0-9.]+/32' | awk '{print $2}' |
	while read -r fake; do
		iptables -w -t nat -D ANTIZAPRET-MAPPING -d "$fake" -j DNAT --to-destination "$bad" &&
		iptables -w -t nat -A ANTIZAPRET-MAPPING -d "$fake" -j DNAT --to-destination "${BAD_TO_GOOD[$bad]}" &&
		conntrack -D -d "${fake%/32}" &>/dev/null
		echo "remap $fake: $bad -> ${BAD_TO_GOOD[$bad]}"
	done
done
exit 0
