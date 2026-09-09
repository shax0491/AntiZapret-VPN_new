#!/bin/bash
set -e
export LC_ALL=C

if [[ -n "$1" && "$1" != 'ip' && "$1" != 'ips' && "$1" != 'host' && "$1" != 'hosts' && "$1" != 'noclear' && "$1" != 'noclean' ]]; then
	echo "Ignored invalid parameter: $1"
	set --
fi

echo 'Update AntiZapret VPN files:'

cd /root/antizapret
rm -rf download
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
ADGUARD_PATH=download/adguard.txt

OISD_LINK=https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild2_small.txt
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
	local attempts=3
	local ok=0
	local i

	log "Downloading: $path <- $link"

	for ((i = 1; i <= attempts; i++)); do
		if curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 3 "$link" -o "$tmp_path"; then
			ok=1
			break
		fi
		log "  attempt $i/$attempts failed (direct)"
		sleep $((i * 2))
	done

	if [[ $ok -eq 0 ]]; then
		log "  trying via CORS proxy fallback..."
		if curl -fsSL --connect-timeout 15 --max-time 300 "$PROXY$link" -o "$tmp_path"; then
			ok=1
		fi
	fi

	if [[ $ok -eq 0 ]]; then
		log "  ERROR: failed to download $path"
		rm -f "$tmp_path"
		if [[ "$critical" == 'y' ]]; then
			log "  FATAL: critical file missing, aborting update"
			exit 2
		fi
		return 1
	fi

	if [[ ! -s "$tmp_path" ]]; then
		log "  ERROR: downloaded file is empty: $path"
		rm -f "$tmp_path"
		[[ "$critical" == 'y' ]] && exit 2
		return 1
	fi

	if head -c 300 "$tmp_path" | grep -qiE '<html|<!doctype'; then
		log "  ERROR: downloaded file looks like an HTML error page: $path"
		rm -f "$tmp_path"
		[[ "$critical" == 'y' ]] && exit 2
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

download $UPDATE_PATH $UPDATE_LINK y
download $PARSE_PATH $PARSE_LINK y
download $DOALL_PATH $DOALL_LINK y

source setup

if [[ -z "$1" || "$1" == 'host' || "$1" == 'hosts' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	download $DOMAIN_PATH $DOMAIN_LINK n
	( download $DOMAIN2_PATH $DOMAIN2_LINK n ) || true
	download $DENY_RPZ_PATH $DENY_RPZ_LINK n
	download $DENY2_RPZ_PATH $DENY2_RPZ_LINK n
	download $INCLUDE_HOSTS_PATH $INCLUDE_HOSTS_LINK n
	download $REMOVE_HOSTS_PATH $REMOVE_HOSTS_LINK n

	if [[ "$ROUTE_ALL" == 'y' ]]; then
		download $EXCLUDE_HOSTS_PATH $EXCLUDE_HOSTS_LINK n
	else
		printf '# НЕ РЕДАКТИРУЙТЕ ЭТОТ ФАЙЛ!' > $EXCLUDE_HOSTS_PATH
	fi

	if [[ "$ANTIZAPRET_ADBLOCK" == 'y' || "$VPN_ADBLOCK" == 'y' ]]; then
		download $INCLUDE_ADBLOCK_HOSTS_PATH $INCLUDE_ADBLOCK_HOSTS_LINK n
		download $EXCLUDE_ADBLOCK_HOSTS_PATH $EXCLUDE_ADBLOCK_HOSTS_LINK n
		download $ADGUARD_PATH $ADGUARD_LINK n
		download $OISD_PATH $OISD_LINK n
	else
		> $INCLUDE_ADBLOCK_HOSTS_PATH
		> $EXCLUDE_ADBLOCK_HOSTS_PATH
		> $ADGUARD_PATH
		> $OISD_PATH
	fi
fi

if [[ -z "$1" || "$1" == 'ip' || "$1" == 'ips' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	[[ "$DISCORD_INCLUDE" == 'y' ]] && download $DISCORD_IPS_PATH $DISCORD_IPS_LINK n
	[[ "$CLOUDFLARE_INCLUDE" == 'y' ]] && download $CLOUDFLARE_IPS_PATH $CLOUDFLARE_IPS_LINK n
	[[ "$AMAZON_INCLUDE" == 'y' ]] && download $AMAZON_IPS_PATH $AMAZON_IPS_LINK n
	[[ "$HETZNER_INCLUDE" == 'y' ]] && download $HETZNER_IPS_PATH $HETZNER_IPS_LINK n
	[[ "$DIGITALOCEAN_INCLUDE" == 'y' ]] && download $DIGITALOCEAN_IPS_PATH $DIGITALOCEAN_IPS_LINK n
	[[ "$OVH_INCLUDE" == 'y' ]] && download $OVH_IPS_PATH $OVH_IPS_LINK n
	[[ "$TELEGRAM_INCLUDE" == 'y' ]] && download $TELEGRAM_IPS_PATH $TELEGRAM_IPS_LINK n
	[[ "$GOOGLE_INCLUDE" == 'y' ]] && download $GOOGLE_IPS_PATH $GOOGLE_IPS_LINK n
	[[ "$AKAMAI_INCLUDE" == 'y' ]] && download $AKAMAI_IPS_PATH $AKAMAI_IPS_LINK n
	[[ "$WHATSAPP_INCLUDE" == 'y' ]] && download $WHATSAPP_IPS_PATH $WHATSAPP_IPS_LINK n
	[[ "$ROBLOX_INCLUDE" == 'y' ]] && download $ROBLOX_IPS_PATH $ROBLOX_IPS_LINK n
fi

./custom-update.sh "$1" || true

log "Update finished"
exit 0
