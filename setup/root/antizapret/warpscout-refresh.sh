#!/bin/bash
#
# Периодическая проверка и обновление Endpoint у Cloudflare WARP-туннелей
# (warp-antizapret/warp-vpn) через github.com/vernette/warpscout.
#
# Endpoint меняется "на лету" через `wg set ... endpoint`, без wg-quick down/up -
# активные сессии клиентов AntiZapret VPN/VPN при этом не рвутся.
#
# Не применяется к Proton VPN (WARP_PROVIDER=proton) - там endpoint фиксированный,
# задаётся вручную пользователем, и его нечем "просканировать" через warpscout.
#
export LC_ALL=C
set -uo pipefail

cd /root/antizapret
[[ -f setup ]] && source setup

LOG_FILE=/var/log/warpscout-refresh.log
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }

if [[ "${WARP_PROVIDER:-}" != 'cloudflare' ]]; then
	log 'WARP_PROVIDER != cloudflare (Proton use fixed endpoint) - nothing to refresh, exiting'
	exit 0
fi

# % потерь пакетов, выше которого текущий endpoint считается "плохим"
PING_LOSS_THRESHOLD="${WARPSCOUT_LOSS_THRESHOLD:-50}"
# DME (Москва) обычно первым попадает под блокировки в РФ - исключаем по умолчанию
EXCLUDE_NODES="${WARPSCOUT_EXCLUDE_NODES:-DME}"

ensure_warpscout() {
	command -v warpscout &>/dev/null && return 0
	log 'warpscout not found, installing...'
	if ! curl -fsSL https://raw.githubusercontent.com/vernette/warpscout/master/install.sh | sh &>>"$LOG_FILE"; then
		log 'ERROR: warpscout install failed'
		return 1
	fi
	command -v warpscout &>/dev/null
}

# Аргументы: понятное имя, интерфейс wg, путь к conf-файлу
refresh_endpoint() {
	local name="$1" iface="$2" conf="$3"
	local current_endpoint current_host loss tmp_conf new_endpoint pubkey

	[[ -f "$conf" ]] || { log "$name: $conf not found, skipping"; return; }
	wg show "$iface" &>/dev/null || { log "$name: interface $iface is not up, skipping"; return; }

	current_endpoint="$(grep -m1 '^Endpoint' "$conf" | awk -F'= ' '{print $2}')"
	if [[ -z "$current_endpoint" ]]; then
		log "$name: no Endpoint line in $conf, skipping"
		return
	fi
	current_host="${current_endpoint%:*}"

	loss="$(ping -c 4 -W 2 "$current_host" 2>/dev/null | grep -oP '\d+(?=% packet loss)')"
	[[ -z "$loss" ]] && loss=100

	if (( loss <= PING_LOSS_THRESHOLD )); then
		log "$name: current endpoint $current_endpoint is healthy (${loss}% loss), skipping"
		return
	fi

	log "$name: current endpoint $current_endpoint is degraded (${loss}% loss), scanning for a better one..."
	ensure_warpscout || return

	warpscout register &>>"$LOG_FILE" || log "$name: warpscout register skipped/failed (probably already registered)"

	tmp_conf="/tmp/warpscout-${iface}.conf"
	rm -f "$tmp_conf"
	if ! warpscout scan -p awg -P -best -exclude-node "$EXCLUDE_NODES" -conf "$tmp_conf" &>>"$LOG_FILE"; then
		log "$name: warpscout scan failed"
		rm -f "$tmp_conf"
		return
	fi

	new_endpoint="$(grep -m1 '^Endpoint' "$tmp_conf" 2>/dev/null | awk -F'= ' '{print $2}')"
	rm -f "$tmp_conf"

	if [[ -z "$new_endpoint" || "$new_endpoint" == "$current_endpoint" ]]; then
		log "$name: no better endpoint found"
		return
	fi

	pubkey="$(grep -m1 '^PublicKey' "$conf" | awk -F'= ' '{print $2}')"
	if [[ -z "$pubkey" ]]; then
		log "$name: could not read PublicKey from $conf, skipping live update"
		return
	fi

	if wg set "$iface" peer "$pubkey" endpoint "$new_endpoint"; then
		sed -i "s|^Endpoint.*|Endpoint = $new_endpoint|" "$conf"
		log "$name: endpoint switched $current_endpoint -> $new_endpoint"
	else
		log "$name: wg set failed for new endpoint $new_endpoint"
	fi
}

refresh_endpoint 'AntiZapret WARP' warp-antizapret /etc/wireguard/warp-antizapret.conf
refresh_endpoint 'VPN WARP' warp-vpn /etc/wireguard/warp-vpn.conf

exit 0
