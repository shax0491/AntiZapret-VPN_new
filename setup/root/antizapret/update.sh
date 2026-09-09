#!/bin/bash
set -e
export LC_ALL=C

if [[ -n "$1" && "$1" != 'ip' && "$1" != 'ips' && "$1" != 'host' && "$1" != 'hosts' && "$1" != 'noclear' && "$1" != 'noclean' ]]; then
	echo "Ignored invalid parameter: $1"
	set --
fi

echo 'Update AntiZapret VPN files:'

cd /root/antizapret
mkdir -p download

LOG_FILE=/var/log/antizapret-update.log
mkdir -p "$(dirname "$LOG_FILE")"

log() {
	echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"
}

FORK_USER="shax0491"
FORK_REPO="AntiZapret-VPN"
FORK_BRANCH="main"
FORK_BASE="https://raw.githubusercontent.com/${FORK_USER}/${FORK_REPO}/${FORK_BRANCH}/setup/root/antizapret"
# Зеркало jsDelivr на тот же репозиторий/ветку - подставляется автоматически в download(),
# если у файла нет отдельно заданного зеркала (см. 4-й аргумент download)
FORK_MIRROR="https://cdn.jsdelivr.net/gh/${FORK_USER}/${FORK_REPO}@${FORK_BRANCH}/setup/root/antizapret"

UPDATE_LINK=$FORK_BASE/update.sh
UPDATE_PATH=update.sh

PARSE_LINK=$FORK_BASE/parse.sh
PARSE_PATH=parse.sh

DOALL_LINK=$FORK_BASE/doall.sh
DOALL_PATH=doall.sh

# Сторонние независимые источники реестра РКН - НЕ трогать при смене форка
DOMAIN_LINK=https://raw.githubusercontent.com/bol-van/rulist/main/reestr_hostname.txt
DOMAIN_PATH=download/bol-van-domain.txt

DOMAIN2_LINK=https://antifilter.download/list/domains.lst
DOMAIN2_PATH=download/antifilter-download-domain.txt

DENY_RPZ_LINK=$FORK_BASE/download/deny-rpz.txt
DENY_RPZ_PATH=download/deny-rpz.txt

DENY2_RPZ_LINK=$FORK_BASE/download/deny2-rpz.txt
DENY2_RPZ_PATH=download/deny2-rpz.txt

INCLUDE_HOSTS_LINK=$FORK_BASE/download/include-hosts.txt
INCLUDE_HOSTS_PATH=download/include-hosts.txt

EXCLUDE_HOSTS_LINK=$FORK_BASE/download/exclude-hosts.txt
EXCLUDE_HOSTS_PATH=download/exclude-hosts.txt

REMOVE_HOSTS_LINK=$FORK_BASE/download/remove-hosts.txt.gz
REMOVE_HOSTS_PATH=download/remove-hosts.txt.gz

INCLUDE_ADBLOCK_HOSTS_LINK=$FORK_BASE/download/include-adblock-hosts.txt
INCLUDE_ADBLOCK_HOSTS_PATH=download/include-adblock-hosts.txt

EXCLUDE_ADBLOCK_HOSTS_LINK=$FORK_BASE/download/exclude-adblock-hosts.txt
EXCLUDE_ADBLOCK_HOSTS_PATH=download/exclude-adblock-hosts.txt

# Сторонние независимые источники - НЕ трогать
ADGUARD_LINK=https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
ADGUARD_MIRROR=https://cdn.jsdelivr.net/gh/AdguardTeam/AdGuardSDNSFilter@gh-pages/Filters/filter.txt
ADGUARD_PATH=download/adguard.txt

OISD_LINK=https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild2_small.txt
OISD_MIRROR=https://cdn.jsdelivr.net/gh/sjhgvr/oisd@main/domainswild2_small.txt
OISD_PATH=download/oisd-include-adblock-hosts.txt

DISCORD_IPS_LINK=$FORK_BASE/download/discord-ips.txt
DISCORD_IPS_PATH=download/discord-ips.txt

CLOUDFLARE_IPS_LINK=$FORK_BASE/download/cloudflare-ips.txt
CLOUDFLARE_IPS_PATH=download/cloudflare-ips.txt

AMAZON_IPS_LINK=$FORK_BASE/download/amazon-ips.txt
AMAZON_IPS_PATH=download/amazon-ips.txt

HETZNER_IPS_LINK=$FORK_BASE/download/hetzner-ips.txt
HETZNER_IPS_PATH=download/hetzner-ips.txt

DIGITALOCEAN_IPS_LINK=$FORK_BASE/download/digitalocean-ips.txt
DIGITALOCEAN_IPS_PATH=download/digitalocean-ips.txt

OVH_IPS_LINK=$FORK_BASE/download/ovh-ips.txt
OVH_IPS_PATH=download/ovh-ips.txt

TELEGRAM_IPS_LINK=$FORK_BASE/download/telegram-ips.txt
TELEGRAM_IPS_PATH=download/telegram-ips.txt

GOOGLE_IPS_LINK=$FORK_BASE/download/google-ips.txt
GOOGLE_IPS_PATH=download/google-ips.txt

AKAMAI_IPS_LINK=$FORK_BASE/download/akamai-ips.txt
AKAMAI_IPS_PATH=download/akamai-ips.txt

WHATSAPP_IPS_LINK=$FORK_BASE/download/whatsapp-ips.txt
WHATSAPP_IPS_PATH=download/whatsapp-ips.txt

ROBLOX_IPS_LINK=$FORK_BASE/download/roblox-ips.txt
ROBLOX_IPS_PATH=download/roblox-ips.txt

PROXY=https://proxy.cors.sh/

function download {
	local path="${1}"
	local tmp_path="${path}.tmp"
	local link="$2"
	local critical="${3:-n}"
	local mirror="${4:-}"
	local attempts=3
	local ok=0
	local i

	# Для файлов из своего форка зеркало на jsDelivr подставляется автоматически,
	# если не задано явно четвёртым аргументом
	if [[ -z "$mirror" && -n "$FORK_BASE" && "$link" == "$FORK_BASE"* ]]; then
		mirror="${link/$FORK_BASE/$FORK_MIRROR}"
	fi

	log "Downloading: $path <- $link"

	for ((i = 1; i <= attempts; i++)); do
		if curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 3 "$link" -o "$tmp_path"; then
			ok=1
			break
		fi
		log "  attempt $i/$attempts failed (direct)"
		sleep $((i * 2))
	done

	if [[ $ok -eq 0 && -n "$mirror" ]]; then
		log "  trying mirror: $mirror"
		if curl -fsSL --connect-timeout 15 --max-time 300 --retry 1 --retry-delay 3 "$mirror" -o "$tmp_path"; then
			ok=1
		else
			log "  mirror also failed"
		fi
	fi

	if [[ $ok -eq 0 ]]; then
		log "  trying via CORS proxy fallback..."
		if curl -fsSL --connect-timeout 15 --max-time 300 "$PROXY$link" -o "$tmp_path"; then
			ok=1
		fi
	fi

	if [[ $ok -eq 1 ]]; then
		if [[ ! -s "$tmp_path" ]]; then
			log "  ERROR: downloaded file is empty: $path"
			ok=0
		elif head -c 300 "$tmp_path" | grep -qiE '<html|<!doctype'; then
			log "  ERROR: downloaded file looks like an HTML error page: $path"
			ok=0
		fi
	fi

	if [[ $ok -eq 0 ]]; then
		rm -f "$tmp_path"
		# Все источники (прямой + зеркало + прокси) недоступны. Если на диске уже есть
		# рабочая копия с прошлого успешного обновления - используем её и не валим весь
		# апдейт из-за сетевой ошибки одного файла.
		if [[ -s "$path" ]]; then
			log "  WARNING: all sources failed for $path, keeping previous cached copy"
			return 1
		fi
		log "  ERROR: failed to download $path and no cached copy exists"
		if [[ "$critical" == 'y' ]]; then
			log "  FATAL: no usable copy of $path - aborting update"
			exit 2
		fi
		return 1
	fi

	mv -f "$tmp_path" "$path"
	if [[ "$path" == *.sh ]]; then
		chmod +x "$path"
	elif [[ "$path" == *.gz ]]; then
		gunzip -f "$path" || > "${path%.gz}"
	fi
	log "  OK: $path ($(wc -c < "$path") bytes)"
	return 0
}

# Скрипт запущен с `set -e` - без `|| true` возврат download() любого ненулевого кода
# (в т.ч. штатный "не критично, оставляю кэш") оборвал бы весь update.sh на первой же
# сетевой заминке. exit 2 внутри download() при этом отработает как надо - `|| true`
# гасит только return, а не explicit exit.
download $UPDATE_PATH $UPDATE_LINK y || true
download $PARSE_PATH $PARSE_LINK y || true
download $DOALL_PATH $DOALL_LINK y || true

source setup

# --- WARP: подбор рабочего не-RU эндпоинта (warpscout) ---
# Сканирование занимает несколько минут - гонять его на каждой перезагрузке (из up.sh)
# нельзя. Поэтому результат кэшируется в файл вне /root/antizapret (переживает
# переустановку) и обновляется здесь, в ночном update.sh, не чаще раза в WARPSCOUT_MAX_AGE_DAYS
# дней. up.sh только читает готовый файл - сам никогда не сканирует.
WARPSCOUT_ACCOUNT=/etc/wireguard/warpscout-account.json
WARPSCOUT_ENDPOINT_CACHE=/etc/wireguard/warpscout-endpoint
WARPSCOUT_MAX_AGE_DAYS=6

if [[ "$WARP_PROVIDER" == 'cloudflare' ]] && { [[ "$ANTIZAPRET_WARP" != '1' ]] || [[ "$VPN_WARP" != '1' ]]; } && command -v warpscout &>/dev/null; then
	STALE=y
	if [[ -s "$WARPSCOUT_ENDPOINT_CACHE" ]]; then
		AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$WARPSCOUT_ENDPOINT_CACHE" 2>/dev/null || echo 0) ) / 86400 ))
		(( AGE_DAYS < WARPSCOUT_MAX_AGE_DAYS )) && STALE=n
	fi
	if [[ "$STALE" == 'y' ]]; then
		log "warpscout: refreshing best WARP endpoint (excluding RU/DME node)..."
		if [[ ! -s "$WARPSCOUT_ACCOUNT" ]]; then
			timeout 30 warpscout register -a "$WARPSCOUT_ACCOUNT" &>>"$LOG_FILE" || log "warpscout: registration failed, will retry next run"
		fi
		if [[ -s "$WARPSCOUT_ACCOUNT" ]]; then
			BEST="$(timeout 200 warpscout scan -a "$WARPSCOUT_ACCOUNT" -p wg -exclude-node DME -best -t 3 -jt 20 -no-report 2>>"$LOG_FILE")"
			if [[ "$BEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
				echo "$BEST" > "$WARPSCOUT_ENDPOINT_CACHE"
				log "warpscout: best endpoint is $BEST"
			else
				log "warpscout: scan found nothing usable, keeping previous cached endpoint (if any)"
			fi
		fi
	fi
fi

if [[ -z "$1" || "$1" == 'host' || "$1" == 'hosts' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	download $DOMAIN_PATH $DOMAIN_LINK n || true
	download $DOMAIN2_PATH $DOMAIN2_LINK n || true
	download $DENY_RPZ_PATH $DENY_RPZ_LINK n || true
	download $DENY2_RPZ_PATH $DENY2_RPZ_LINK n || true
	download $INCLUDE_HOSTS_PATH $INCLUDE_HOSTS_LINK n || true
	download $REMOVE_HOSTS_PATH $REMOVE_HOSTS_LINK n || true

	if [[ "$ROUTE_ALL" == 'y' ]]; then
		download $EXCLUDE_HOSTS_PATH $EXCLUDE_HOSTS_LINK n || true
	else
		printf '# НЕ РЕДАКТИРУЙТЕ ЭТОТ ФАЙЛ!' > $EXCLUDE_HOSTS_PATH
	fi

	if [[ "$ANTIZAPRET_ADBLOCK" == 'y' || "$VPN_ADBLOCK" == 'y' ]]; then
		download $INCLUDE_ADBLOCK_HOSTS_PATH $INCLUDE_ADBLOCK_HOSTS_LINK n || true
		download $EXCLUDE_ADBLOCK_HOSTS_PATH $EXCLUDE_ADBLOCK_HOSTS_LINK n || true
		download $ADGUARD_PATH $ADGUARD_LINK n $ADGUARD_MIRROR || true
		download $OISD_PATH $OISD_LINK n $OISD_MIRROR || true
	else
		> $INCLUDE_ADBLOCK_HOSTS_PATH
		> $EXCLUDE_ADBLOCK_HOSTS_PATH
		> $ADGUARD_PATH
		> $OISD_PATH
	fi
fi

if [[ -z "$1" || "$1" == 'ip' || "$1" == 'ips' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	# Раньше файл списка отключённого сервиса просто оставался в download/ до следующего
	# rm -rf download - теперь, когда download/ больше не стирается целиком при каждом
	# обновлении (см. выше), явно удаляем файл при выключенном тумблере, иначе устаревший
	# список IP продолжит маршрутизироваться через AntiZapret VPN даже после отключения.
	if [[ "$DISCORD_INCLUDE" == 'y' ]]; then download $DISCORD_IPS_PATH $DISCORD_IPS_LINK n || true; else rm -f $DISCORD_IPS_PATH; fi
	if [[ "$CLOUDFLARE_INCLUDE" == 'y' ]]; then download $CLOUDFLARE_IPS_PATH $CLOUDFLARE_IPS_LINK n || true; else rm -f $CLOUDFLARE_IPS_PATH; fi
	if [[ "$AMAZON_INCLUDE" == 'y' ]]; then download $AMAZON_IPS_PATH $AMAZON_IPS_LINK n || true; else rm -f $AMAZON_IPS_PATH; fi
	if [[ "$HETZNER_INCLUDE" == 'y' ]]; then download $HETZNER_IPS_PATH $HETZNER_IPS_LINK n || true; else rm -f $HETZNER_IPS_PATH; fi
	if [[ "$DIGITALOCEAN_INCLUDE" == 'y' ]]; then download $DIGITALOCEAN_IPS_PATH $DIGITALOCEAN_IPS_LINK n || true; else rm -f $DIGITALOCEAN_IPS_PATH; fi
	if [[ "$OVH_INCLUDE" == 'y' ]]; then download $OVH_IPS_PATH $OVH_IPS_LINK n || true; else rm -f $OVH_IPS_PATH; fi
	if [[ "$TELEGRAM_INCLUDE" == 'y' ]]; then download $TELEGRAM_IPS_PATH $TELEGRAM_IPS_LINK n || true; else rm -f $TELEGRAM_IPS_PATH; fi
	if [[ "$GOOGLE_INCLUDE" == 'y' ]]; then download $GOOGLE_IPS_PATH $GOOGLE_IPS_LINK n || true; else rm -f $GOOGLE_IPS_PATH; fi
	if [[ "$AKAMAI_INCLUDE" == 'y' ]]; then download $AKAMAI_IPS_PATH $AKAMAI_IPS_LINK n || true; else rm -f $AKAMAI_IPS_PATH; fi
	if [[ "$WHATSAPP_INCLUDE" == 'y' ]]; then download $WHATSAPP_IPS_PATH $WHATSAPP_IPS_LINK n || true; else rm -f $WHATSAPP_IPS_PATH; fi
	if [[ "$ROBLOX_INCLUDE" == 'y' ]]; then download $ROBLOX_IPS_PATH $ROBLOX_IPS_LINK n || true; else rm -f $ROBLOX_IPS_PATH; fi
fi

./custom-update.sh "$1" || true

log "Update finished"
exit 0
