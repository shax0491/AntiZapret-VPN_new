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
# ВАЖНО: критерий "плохого" эндпоинта - НЕ пинг, а гео-флаг. Проверено эмпирически:
# дефолтный (авторегистрация Cloudflare) эндпоинт может быть идеально быстрым (0%
# потерь) и при этом YouTube всё равно определяет его регион как RU (поле "GL" в
# ytcfg на странице youtube.com). Смена по пингу эту проблему не решает - нужно
# проверять и подбирать эндпоинт именно по гео-сигналу целевого сервиса.
#
export LC_ALL=C
set -uo pipefail

# systemd-сервис запускает скрипт с обрезанным окружением (HOME не /root, PATH без
# ~/.local/bin) - без явного экспорта официальный install.sh warpscout ставит
# бинарник в /.local/bin вместо /root/.local/bin, и command -v после этого его
# всё равно не находит.
export HOME=/root
export PATH="/root/.local/bin:$PATH"

cd /root/antizapret
[[ -f setup ]] && source setup

LOG_FILE=/var/log/warpscout-refresh.log
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }

if [[ "${WARP_PROVIDER:-}" != 'cloudflare' ]]; then
	log 'WARP_PROVIDER != cloudflare (Proton use fixed endpoint) - nothing to refresh, exiting'
	exit 0
fi

# DME (Москва) обычно первым попадает под блокировки в РФ - исключаем по умолчанию.
# Само по себе не гарантирует не-RU гео (это подтверждает основная проверка ниже),
# но снижает число холостых попыток.
EXCLUDE_NODES="${WARPSCOUT_EXCLUDE_NODES:-DME}"
# Страны, которые считаем "плохими" для гео-флага (через запятую, ISO-коды)
BAD_GEO="${WARPSCOUT_BAD_GEO:-RU}"

ensure_warpscout() {
	command -v warpscout &>/dev/null && return 0
	log 'warpscout not found, installing...'
	if ! curl -fsSL https://raw.githubusercontent.com/vernette/warpscout/master/install.sh | sh &>>"$LOG_FILE"; then
		log 'ERROR: warpscout install failed'
		return 1
	fi
	command -v warpscout &>/dev/null
}

# Гео-сигнал YouTube (поле "GL" в ytcfg на странице) - то, как Google фактически
# классифицирует регион для этого исходящего IP. Пусто = не удалось проверить
# (тоже считаем "плохо", т.к. может означать, что туннель не работает).
#
# Сразу после `wg set ... endpoint` первый запрос через интерфейс надёжно
# обрывается по таймауту (HTTP 000, 0 байт) - хендшейк с новым эндпоинтом ещё
# не установлен. Поэтому несколько попыток с паузой, а не одна.
check_youtube_gl() {
	local iface="$1" gl attempt
	for attempt in 1 2 3; do
		gl="$(curl -s --interface "$iface" --max-time 10 -A 'Mozilla/5.0' 'https://www.youtube.com/' 2>/dev/null \
			| grep -oE '"GL":"[A-Z]{2}"' | head -1 | sed -n 's/.*"GL":"\([A-Z]\{2\}\)".*/\1/p')"
		[[ -n "$gl" ]] && { echo "$gl"; return; }
		sleep 2
	done
}

is_bad_geo() {
	local gl="$1"
	[[ -z "$gl" ]] && return 0
	[[ ",${BAD_GEO}," == *",${gl},"* ]]
}

# Аргументы: понятное имя, интерфейс wg, путь к conf-файлу
refresh_endpoint() {
	local name="$1" iface="$2" conf="$3"
	local current_endpoint current_gl tmp_conf new_endpoint pubkey new_gl attempt

	[[ -f "$conf" ]] || { log "$name: $conf not found, skipping"; return; }
	wg show "$iface" &>/dev/null || { log "$name: interface $iface is not up, skipping"; return; }

	current_endpoint="$(grep -m1 '^Endpoint' "$conf" | awk -F'= ' '{print $2}')"
	if [[ -z "$current_endpoint" ]]; then
		log "$name: no Endpoint line in $conf, skipping"
		return
	fi

	current_gl="$(check_youtube_gl "$iface")"
	if ! is_bad_geo "$current_gl"; then
		log "$name: current endpoint $current_endpoint OK (YouTube GL=$current_gl), skipping"
		return
	fi
	log "$name: current endpoint $current_endpoint flagged (YouTube GL=${current_gl:-<no response>}), scanning for a better one..."

	ensure_warpscout || return
	warpscout register &>>"$LOG_FILE" || log "$name: warpscout register skipped/failed (probably already registered)"

	pubkey="$(grep -m1 '^PublicKey' "$conf" | awk -F'= ' '{print $2}')"
	if [[ -z "$pubkey" ]]; then
		log "$name: could not read PublicKey from $conf, skipping live update"
		return
	fi

	# До 3 попыток: находим кандидата через warpscout, применяем на лету, проверяем
	# его собственный гео-флаг тем же способом. Если кандидат тоже RU - откатываем
	# и пробуем следующего (каждая попытка сканирует заново, кандидаты могут отличаться).
	for attempt in 1 2 3; do
		tmp_conf="/tmp/warpscout-${iface}.conf"
		rm -f "$tmp_conf"
		if ! warpscout scan -p awg -P -best -exclude-node "$EXCLUDE_NODES" -conf "$tmp_conf" &>>"$LOG_FILE"; then
			log "$name: warpscout scan failed (attempt $attempt/3)"
			rm -f "$tmp_conf"
			continue
		fi

		new_endpoint="$(grep -m1 '^Endpoint' "$tmp_conf" 2>/dev/null | awk -F'= ' '{print $2}')"
		rm -f "$tmp_conf"

		if [[ -z "$new_endpoint" || "$new_endpoint" == "$current_endpoint" ]]; then
			log "$name: no new candidate endpoint found (attempt $attempt/3)"
			continue
		fi

		if ! wg set "$iface" peer "$pubkey" endpoint "$new_endpoint"; then
			log "$name: wg set failed for candidate $new_endpoint (attempt $attempt/3)"
			continue
		fi

		new_gl="$(check_youtube_gl "$iface")"
		if ! is_bad_geo "$new_gl"; then
			sed -i "s|^Endpoint.*|Endpoint = $new_endpoint|" "$conf"
			log "$name: endpoint switched $current_endpoint -> $new_endpoint (YouTube GL=$new_gl)"
			return
		fi

		log "$name: candidate $new_endpoint still flagged (YouTube GL=${new_gl:-<no response>}), reverting and retrying (attempt $attempt/3)"
		wg set "$iface" peer "$pubkey" endpoint "$current_endpoint" &>/dev/null || true
	done

	log "$name: no clean (non-$BAD_GEO) endpoint found after 3 attempts, keeping $current_endpoint - will retry on next scheduled run"
}

refresh_endpoint 'AntiZapret WARP' warp-antizapret /etc/wireguard/warp-antizapret.conf
refresh_endpoint 'VPN WARP' warp-vpn /etc/wireguard/warp-vpn.conf

exit 0
