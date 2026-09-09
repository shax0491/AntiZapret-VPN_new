#!/bin/bash
#
# Скрипт для установки на своём сервере AntiZapret VPN + полный VPN
#
# https://github.com/shax0491/AntiZapret-VPN
#
export LC_ALL=C

if [[ -f /var/run/reboot-required ]] || pidof apt apt-get dpkg unattended-upgrades &>/dev/null; then
	echo 'Error: You need to reboot this server before installation!'
	exit 2
fi

systemctl stop apt-daily.timer 2>/dev/null
systemctl stop apt-daily-upgrade.timer 2>/dev/null
systemctl stop apt-daily 2>/dev/null
systemctl stop apt-daily-upgrade 2>/dev/null
systemctl stop unattended-upgrades 2>/dev/null

if [[ "$EUID" -ne 0 ]]; then
	echo 'Error: You need to run this as root!'
	exit 3
fi

cd /root

if [[ "$(systemd-detect-virt)" == 'openvz' || "$(systemd-detect-virt)" == 'lxc' ]]; then
	echo 'Error: OpenVZ and LXC are not supported!'
	exit 4
fi

OS="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
VERSION="$(lsb_release -rs | cut -d '.' -f1)"
CODENAME="$(lsb_release -cs)"
ARCH="$(dpkg --print-architecture)"

if [[ "$OS" == 'debian' ]]; then
	if (( VERSION < 13 )); then
		echo "Error: Debian $VERSION is not supported! Minimal supported version is 13"
		exit 5
	fi
elif [[ "$OS" == 'ubuntu' ]]; then
	if (( VERSION < 24 )); then
		echo "Error: Ubuntu $VERSION is not supported! Minimal supported version is 24"
		exit 6
	fi
else
	echo "Error: Your Linux distribution ($OS) is not supported!"
	exit 7
fi

echo 'Cleaning disk, please wait...'
journalctl --vacuum-size=1B -q
find /var/log -name "*.gz" -delete
find /var/log -name "*.1" -delete
find /var/log -type f -exec truncate -s 0 {} +
[[ -d /etc/openvpn/server/logs ]] && find /etc/openvpn/server/logs -type f -exec truncate -s 0 {} +
dpkg --configure -a >/dev/null
apt-get install -f -y >/dev/null
apt-get clean >/dev/null
apt-get autoremove --purge -y >/dev/null

if [[ $(df --output=avail / | tail -n 1) -lt $((2 * 1024 * 1024)) ]]; then
	echo 'Error: Low disk space! You need 2GB of free space!'
	exit 8
fi

DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
if [[ -z "$DEFAULT_INTERFACE" ]]; then
	echo 'Default network interface not found!'
	exit 9
fi

DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
if [[ -z "$DEFAULT_IP" ]]; then
	echo 'Default IPv4 address not found!'
	exit 10
fi

echo
echo -e '\e[1;32mInstalling AntiZapret VPN + full VPN...\e[0m'
echo 'OpenVPN + WireGuard + AmneziaWG'
echo 'More details: https://github.com/shax0491/AntiZapret-VPN'
echo

MTU=$(< /sys/class/net/$DEFAULT_INTERFACE/mtu)
if (( MTU < 1500 )); then
	echo "Warning! Low MTU on $DEFAULT_INTERFACE: $MTU"
	echo "Change MTU in OpenVPN and WireGuard configs from 1420 to $((MTU-80)) on this server after installation"
	echo
fi

until [[ "$OPENVPN_UDP_ENABLE" =~ (y|n) ]]; do
	read -rp 'Enable OpenVPN UDP? [y/n]: ' -e -i y OPENVPN_UDP_ENABLE
done
echo
until [[ "$OPENVPN_TCP_ENABLE" =~ (y|n) ]]; do
	read -rp 'Enable OpenVPN TCP? [y/n]: ' -e -i n OPENVPN_TCP_ENABLE
done
echo
until [[ "$WIREGUARD_ENABLE" =~ (y|n) ]]; do
	read -rp 'Enable WireGuard/AmneziaWG? [y/n]: ' -e -i y WIREGUARD_ENABLE
done
echo
echo 'Choose AmneziaWG 2.0 first-packet masquerade type (helps bypass DPI):'
echo '    1) TLS ClientHello - legacy, TLS-over-UDP, often filtered by DPI'
echo '    2) QUIC Initial    - mimics QUIC/HTTP3 (recommended)'
echo '    3) SIP INVITE      - mimics a VoIP call'
until [[ "$AWG2_MASQUERADE" =~ ^[1-3]$ ]]; do
	read -rp 'Masquerade type [1-3]: ' -e -i 2 AWG2_MASQUERADE
done
echo
echo 'Choose anti-censorship patch for OpenVPN (UDP only):'
echo '    1) None        - Do not install anti-censorship patch, or remove if already installed'
echo '    2) Random      - Recommended by default, randomly selects Strong or Error-Free'
echo '    3) Strong      - Better protocol masking'
echo '    4) Error-Free  - Use if Strong patch causes connection error, recommended for routers (Keenetic/MikroTik/OpenWrt)'
until [[ "$OPENVPN_PATCH" =~ ^[1-4]$ ]]; do
	read -rp 'Version choice [1-4]: ' -e -i 2 OPENVPN_PATCH
done
echo
echo 'OpenVPN DCO lowers CPU load, boosts data speeds, and only supports AES-128-GCM, AES-256-GCM and CHACHA20-POLY1305 encryption'
until [[ "$OPENVPN_DCO" =~ (y|n) ]]; do
	read -rp 'Turn on OpenVPN DCO? [y/n]: ' -e -i y OPENVPN_DCO
done
echo
echo -e 'Choose egress VPN provider for \e[1;32mWARP-style\e[0m outbound routing (used below for AntiZapret and/or full VPN):'
echo '    1) Proton VPN      - Recommended: stable, no forced RU geo-exit, paste your own WireGuard config'
echo '    2) Cloudflare WARP - Legacy, auto-registered, endpoint may be unstable or geolocate as RU'
until [[ "$WARP_PROVIDER_CHOICE" =~ ^[1-2]$ ]]; do
	read -rp 'Provider choice [1-2]: ' -e -i 1 WARP_PROVIDER_CHOICE
done
[[ "$WARP_PROVIDER_CHOICE" == '1' ]] && WARP_PROVIDER=proton || WARP_PROVIDER=cloudflare
echo
echo -e 'Choose Cloudflare WARP for \e[1;32mAntiZapret VPN\e[0m (antizapret-*) outbound traffic:'
echo '    1) None    - Do not use'
echo '    2) All     - Route all traffic (domains and IPs)'
echo '    3) Domain  - Route AntiZapret domains and config/include-warp-hosts.txt, excluding config/exclude-warp-hosts.txt'
echo '    4) Custom  - Route domains only from config/include-warp-hosts.txt, excluding config/exclude-warp-hosts.txt'
until [[ "$ANTIZAPRET_WARP" =~ ^[1-4]$ ]]; do
	read -rp 'WARP choice [1-4]: ' -e -i 4 ANTIZAPRET_WARP
done
echo
echo -e 'Choose Cloudflare WARP for \e[1;32mfull VPN\e[0m (vpn-*) outbound traffic:'
echo '    1) None  - Do not use'
echo '    2) All   - Route all traffic (domains and IPs)'
until [[ "$VPN_WARP" =~ ^[1-2]$ ]]; do
	read -rp 'WARP choice [1-2]: ' -e -i 2 VPN_WARP
done
echo
echo -e 'Choose DNS resolvers for \e[1;32mAntiZapret VPN\e[0m (antizapret-*):'
echo '    1) MSK-IX+NSDI+SkyDNS - DNS resolvers optimized for users located in Russia, recommended by default'
echo '       +BI.ZONE+TransTeleCom'
echo '       +Cloudflare+Quad9'
echo '       +ControlD+UltraDNS'
echo '    2) Cloudflare+Quad9  - Use if default choice fails to resolve domains'
echo '       +ControlD+UltraDNS'
echo '    3) Yandex *         - Use if previous choice fails to resolve domains'
echo '    4) Google *         - Use if previous choice fails to resolve domains'
echo '    5) AdGuard *        - Use for blocking ads, trackers, malware and phishing websites'
echo '    6) Comss **         - More details: https://comss.ru/disqus/page.php?id=7315'
echo '    7) XBox **          - More details: https://xbox-dns.ru'
echo '    8) GeoHide **       - More details: https://geohide.ru'
echo
echo '  * - DNS resolvers support EDNS Client Subnet'
echo ' ** - Enable additional proxying and hide this server IP on some internet resources'
echo '      Use only if this server is geolocated in Russia or problems accessing some internet resources'
until [[ "$ANTIZAPRET_DNS" =~ ^[1-8]$ ]]; do
	read -rp 'DNS choice [1-8]: ' -e -i 1 ANTIZAPRET_DNS
done
echo
echo -e 'Choose DNS resolvers for \e[1;32mfull VPN\e[0m (vpn-*):'
echo '    1) Self-hosted  - Use previous choice for AntiZapret VPN, recommended by default'
echo '    2) Cloudflare   - Use if default choice fails to resolve domains'
echo '    3) Quad9        - Use if previous choice fails to resolve domains'
echo '    4) Yandex *     - Use if previous choice fails to resolve domains'
echo '    5) Google *     - Use if previous choice fails to resolve domains'
echo '    6) AdGuard *    - Use for blocking ads, trackers, malware and phishing websites'
echo '    7) Comss **     - More details: https://comss.ru/disqus/page.php?id=7315'
echo '    8) XBox **      - More details: https://xbox-dns.ru'
echo '    9) GeoHide **   - More details: https://geohide.ru'
echo
echo '  * - DNS resolvers support EDNS Client Subnet'
echo ' ** - Enable additional proxying and hide this server IP on some internet resources'
echo '      Use only if this server is geolocated in Russia or problems accessing some internet resources'
until [[ "$VPN_DNS" =~ ^[1-9]$ ]]; do
	read -rp 'DNS choice [1-9]: ' -e -i 1 VPN_DNS
done
echo
until [[ "$ANTIZAPRET_ADBLOCK" =~ (y|n) ]]; do
	read -rp $'Enable blocking ads, trackers, malware and phishing websites in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002 (antizapret-*) based on AdGuard and OISD rules? [y/n]: ' -e -i y ANTIZAPRET_ADBLOCK
done
echo
until [[ "$VPN_ADBLOCK" =~ (y|n) ]]; do
	read -rp $'Enable blocking ads, trackers, malware and phishing websites in \001\e[1;32m\002full VPN\001\e[0m\002 (vpn-*) based on AdGuard and OISD rules? [y/n]: ' -e -i n VPN_ADBLOCK
done
echo
echo 'Default CLIENT IP address range:     10.28.0.0/15'
echo 'Alternative CLIENT IP address range: 172.28.0.0/15'
until [[ "$ALTERNATIVE_CLIENT_IP" =~ (y|n) ]]; do
	read -rp 'Use alternative CLIENT IP address range? [y/n]: ' -e -i n ALTERNATIVE_CLIENT_IP
done
echo
[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP=172 || IP=10
echo "Default FAKE IP address range:     $IP.30.0.0/15"
echo 'Alternative FAKE IP address range: 198.18.0.0/15'
until [[ "$ALTERNATIVE_FAKE_IP" =~ (y|n) ]]; do
	read -rp 'Use alternative range of FAKE IP addresses? [y/n]: ' -e -i y ALTERNATIVE_FAKE_IP
done
echo
until [[ "$OPENVPN_BACKUP_UDP" =~ (y|n) ]]; do
	read -rp 'Use UDP ports 80, 443, 504, 508 as backup for OpenVPN connections? [y/n]: ' -e -i y OPENVPN_BACKUP_UDP
done
echo
until [[ "$OPENVPN_BACKUP_TCP" =~ (y|n) ]]; do
	read -rp 'Use TCP ports 80, 443, 504, 508 as backup for OpenVPN connections? [y/n]: ' -e -i n OPENVPN_BACKUP_TCP
done
echo
until [[ "$WIREGUARD_BACKUP" =~ (y|n) ]]; do
	read -rp 'Use UDP ports 540, 580 as backup for WireGuard/AmneziaWG connections? [y/n]: ' -e -i y WIREGUARD_BACKUP
done
echo
until [[ "$OPENVPN_DUPLICATE" =~ (y|n) ]]; do
	read -rp 'Allow multiple clients connecting to OpenVPN using same profile file (*.ovpn)? [y/n]: ' -e -i y OPENVPN_DUPLICATE
done
echo
until [[ "$OPENVPN_LOG" =~ (y|n) ]]; do
	read -rp 'Enable detailed logs and status in OpenVPN? [y/n]: ' -e -i n OPENVPN_LOG
done
echo
echo 'Warning! SSH protection may block your IP after 5 logins/minute!'
until [[ "$SSH_PROTECTION" =~ (y|n) ]]; do
	read -rp 'Enable SSH brute-force protection? [y/n]: ' -e -i y SSH_PROTECTION
done
echo
echo 'Warning! Attack protection may block VPN or third-party applications!'
until [[ "$ATTACK_PROTECTION" =~ (y|n) ]]; do
	read -rp 'Enable network attack protection? [y/n]: ' -e -i y ATTACK_PROTECTION
done
echo
echo 'Warning! Scan protection blocks ping and closed-port replies!'
until [[ "$SCAN_PROTECTION" =~ (y|n) ]]; do
	read -rp 'Enable network scan protection? [y/n]: ' -e -i y SCAN_PROTECTION
done
echo
echo 'Warning! Torrent guard blocks VPN traffic for 1 minute on torrent detection!'
until [[ "$TORRENT_GUARD" =~ (y|n) ]]; do
	read -rp $'Enable torrent guard for \001\e[1;32m\002full VPN\001\e[0m\002? [y/n]: ' -e -i y TORRENT_GUARD
done
echo
until [[ "$RESTRICT_FORWARD" =~ (y|n) ]]; do
	read -rp $'Restrict forwarding in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002 to IPs from config/forward-ips.txt and result/route-ips.txt? [y/n]: ' -e -i y RESTRICT_FORWARD
done
echo
until [[ "$CLIENT_ISOLATION" =~ (y|n) ]]; do
	read -rp $'Enable \001\e[1;32m\002all VPN\001\e[0m\002 client and server isolation? [y/n]: ' -e -i y CLIENT_ISOLATION
done
echo
while read -rp 'Enter valid domain name for this OpenVPN server or press Enter to skip: ' -e OPENVPN_HOST
do
	[[ -z "$OPENVPN_HOST" ]] && break
	[[ -n $(getent ahostsv4 "$OPENVPN_HOST") ]] && break
done
echo
while read -rp 'Enter valid domain name for this WireGuard/AmneziaWG server or press Enter to skip: ' -e WIREGUARD_HOST
do
	[[ -z "$WIREGUARD_HOST" ]] && break
	[[ -n $(getent ahostsv4 "$WIREGUARD_HOST") ]] && break
done
echo
until [[ "$ROUTE_ALL" =~ (y|n) ]]; do
	read -rp $'Route all domains via \001\e[1;32m\002AntiZapret VPN\001\e[0m\002, excluding Russian domains and config/exclude-hosts.txt? [y/n]: ' -e -i n ROUTE_ALL
done
echo
until [[ "$CLOUDFLARE_INCLUDE" =~ (y|n) ]]; do
	read -rp $'Include Cloudflare IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y CLOUDFLARE_INCLUDE
done
echo
until [[ "$TELEGRAM_INCLUDE" =~ (y|n) ]]; do
	read -rp $'Include Telegram IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y TELEGRAM_INCLUDE
done
echo
until [[ "$WHATSAPP_INCLUDE" =~ (y|n) ]]; do
	read -rp $'Include WhatsApp IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y WHATSAPP_INCLUDE
done
echo

# --- Proton VPN: получение и разбор WireGuard-конфигов взамен авторегистрации WARP ---
PROTON_ANTIZAPRET_PRIVATE_KEY=
PROTON_ANTIZAPRET_PUBLIC_KEY=
PROTON_ANTIZAPRET_ADDRESS=
PROTON_ANTIZAPRET_ENDPOINT_HOST=
PROTON_ANTIZAPRET_ENDPOINT_PORT=
PROTON_VPN_PRIVATE_KEY=
PROTON_VPN_PUBLIC_KEY=
PROTON_VPN_ADDRESS=
PROTON_VPN_ENDPOINT_HOST=
PROTON_VPN_ENDPOINT_PORT=

parse_proton_wg_conf() {
	# $1 = сырой текст wg-конфига, $2 = префикс переменных (PROTON_ANTIZAPRET / PROTON_VPN)
	local raw="$1" prefix="$2"
	local pk pub addr ep host port

	pk="$(grep -m1 -iE '^[[:space:]]*PrivateKey[[:space:]]*=' <<<"$raw" | cut -d '=' -f2- | tr -d '[:space:]')"
	pub="$(grep -m1 -iE '^[[:space:]]*PublicKey[[:space:]]*=' <<<"$raw" | cut -d '=' -f2- | tr -d '[:space:]')"
	addr="$(grep -m1 -iE '^[[:space:]]*Address[[:space:]]*=' <<<"$raw" | cut -d '=' -f2- | tr -d '[:space:]' | cut -d ',' -f1 | cut -d '/' -f1)"
	ep="$(grep -m1 -iE '^[[:space:]]*Endpoint[[:space:]]*=' <<<"$raw" | cut -d '=' -f2- | tr -d '[:space:]')"
	host="${ep%%:*}"
	port="${ep##*:}"

	if [[ -z "$pk" || -z "$pub" || -z "$ep" || -z "$addr" ]] || ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
		echo 'Invalid WireGuard config pasted! Expected PrivateKey/PublicKey/Endpoint/Address fields.'
		return 1
	fi

	printf -v "${prefix}_PRIVATE_KEY" '%s' "$pk"
	printf -v "${prefix}_PUBLIC_KEY" '%s' "$pub"
	printf -v "${prefix}_ADDRESS" '%s' "$addr"
	printf -v "${prefix}_ENDPOINT_HOST" '%s' "$host"
	printf -v "${prefix}_ENDPOINT_PORT" '%s' "$port"
	return 0
}

if [[ "$WARP_PROVIDER" == 'proton' ]]; then
	echo 'Proton VPN has no simple scriptable login API (SRP auth). Get a WireGuard config from'
	echo 'your Proton account (Downloads -> WireGuard configuration) or via the official protonvpn-cli,'
	echo 'then paste its full content below.'
	echo

	if [[ "$ANTIZAPRET_WARP" != '1' ]]; then
		echo 'Paste Proton VPN WireGuard config for AntiZapret VPN egress, then press Enter and Ctrl+D:'
		RAW="$(cat -)"
		until parse_proton_wg_conf "$RAW" PROTON_ANTIZAPRET; do
			echo 'Paste again, then press Enter and Ctrl+D:'
			RAW="$(cat -)"
		done
		echo
	fi

	if [[ "$VPN_WARP" != '1' ]]; then
		echo 'Paste Proton VPN WireGuard config for full VPN egress, then press Enter and Ctrl+D:'
		RAW="$(cat -)"
		until parse_proton_wg_conf "$RAW" PROTON_VPN; do
			echo 'Paste again, then press Enter and Ctrl+D:'
			RAW="$(cat -)"
		done
		echo
	fi
fi

echo 'Installation, please wait...'

systemctl disable --now kresd@1
systemctl disable --now kresd@2
systemctl disable --now antizapret
systemctl disable --now antizapret-update.timer
systemctl disable --now antizapret-update
systemctl disable --now openvpn-server@antizapret-udp
systemctl disable --now openvpn-server@vpn-udp
systemctl disable --now openvpn-server@antizapret-tcp
systemctl disable --now openvpn-server@vpn-tcp
systemctl disable --now wg-quick@antizapret
systemctl disable --now wg-quick@vpn
systemctl disable --now amneziawg@antizapret2
systemctl disable --now amneziawg@vpn2

apt-get purge -y ufw
apt-get purge -y firewalld
apt-get purge -y apparmor
apt-get purge -y apport
apt-get purge -y modemmanager
apt-get purge -y snapd
apt-get purge -y upower
apt-get purge -y multipath-tools
apt-get purge -y rsyslog
apt-get purge -y udisks2
apt-get purge -y qemu-guest-agent
apt-get purge -y tuned
apt-get purge -y sysstat
apt-get purge -y acpid
apt-get purge -y fwupd
apt-get purge -y watchdog
apt-get purge -y pcscd
apt-get purge -y packagekit

if [[ "$SSH_PROTECTION" == 'y' ]]; then
	apt-get purge -y fail2ban || true
	apt-get purge -y sshguard || true
fi

rm -rf /var/cache/knot-resolver/*
rm -rf /var/cache/knot-resolver2/*

rm -rf /etc/openvpn/server/*
rm -rf /etc/openvpn/client/*
rm -rf /etc/wireguard/templates/*

make -C /usr/local/src/openvpn uninstall
rm -rf /usr/local/src/openvpn

sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

sed -i '/^$/!{/^#/!d}' /etc/sysctl.conf

echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf

set -e

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

rm -rf /etc/apt/sources.list.d/cznic-labs-knot-resolver.list
rm -rf /etc/apt/sources.list.d/openvpn-aptrepo.list
rm -rf /etc/apt/sources.list.d/backports.list
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y
apt-get install -y curl gpg

mkdir -p /etc/apt/keyrings

curl -fL --connect-timeout 30 https://pkg.labs.nic.cz/gpg -o /etc/apt/keyrings/cznic-labs-pkg.gpg
echo "deb [signed-by=/etc/apt/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/knot-resolver $CODENAME main" > /etc/apt/sources.list.d/cznic-labs-knot-resolver.list

curl -fL --connect-timeout 30 https://swupdate.openvpn.net/repos/repo-public.gpg | gpg --yes --dearmor -o /etc/apt/keyrings/openvpn-repo-public.gpg
echo "deb [signed-by=/etc/apt/keyrings/openvpn-repo-public.gpg] https://build.openvpn.net/debian/openvpn/release/2.7 $CODENAME main" > /etc/apt/sources.list.d/openvpn-aptrepo.list

if [[ "$OS" == 'debian' ]]; then
	echo "deb http://deb.debian.org/debian $CODENAME-backports main" > /etc/apt/sources.list.d/backports.list
fi

apt-get update
INSTALL=
if [[ "$OS" == 'ubuntu' ]] && (( VERSION < 26 )); then
	INSTALL="linux-generic-hwe-${VERSION}.04"
elif [[ "$OS" == 'debian' ]] && (( VERSION < 14 )); then
	INSTALL="-t $CODENAME-backports linux-image-$ARCH linux-headers-$ARCH"
fi
apt-get install -y $INSTALL git make openvpn iptables easy-rsa gawk knot-resolver idn sipcalc python3-pip wireguard diffutils socat lua-cqueues ipset irqbalance unattended-upgrades jq ethtool iproute2
apt-get autoremove --purge -y
apt-get clean

dpkg-reconfigure -f noninteractive unattended-upgrades
git config --global http.version HTTP/1.1

# AmneziaWG 2.0 (amneziawg-go, userspace) - собирается нативно вместе с основным VPN
NEED_GO=y
if command -v go &>/dev/null; then
	GOMINOR="$(go version | grep -oP 'go1\.\K[0-9]+')"
	[[ "$GOMINOR" -ge 24 ]] && NEED_GO=n
fi
if [[ "$NEED_GO" == 'y' ]]; then
	GO_VER="$(curl -sf 'https://go.dev/dl/?mode=json' | grep -oP '"version":\s*"\Kgo[0-9.]+' | head -1)"
	[[ "$ARCH" == 'arm64' ]] && GOARCH='arm64' || GOARCH='amd64'
	curl -sfL "https://dl.google.com/go/${GO_VER}.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
	ln -sf /usr/local/go/bin/go /usr/local/bin/go
fi

systemctl disable --now amneziawg@antizapret2 2>/dev/null || true
systemctl disable --now amneziawg@vpn2 2>/dev/null || true

rm -rf /tmp/amneziawg-go
git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
make -C /tmp/amneziawg-go
install -m 755 /tmp/amneziawg-go/amneziawg-go /usr/local/bin/amneziawg-go

rm -rf /tmp/amneziawg-tools
git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
make -C /tmp/amneziawg-tools/src
make -C /tmp/amneziawg-tools/src install PREFIX=/usr/local

rm -rf /tmp/amneziawg-go /tmp/amneziawg-tools

rm -rf /tmp/dnslib
git clone https://github.com/paulc/dnslib.git /tmp/dnslib
PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m pip install --force-reinstall --user /tmp/dnslib

rm -rf /tmp/antizapret
git clone https://github.com/shax0491/AntiZapret-VPN.git /tmp/antizapret

cp /root/antizapret/config/*.txt /tmp/antizapret/setup/root/antizapret/config/ || true
cp /root/antizapret/custom*.sh /tmp/antizapret/setup/root/antizapret/ || true
cp /etc/knot-resolver/*.lua /tmp/antizapret/setup/etc/knot-resolver/ || true

if [[ -e /root/backup*.tar.gz ]]; then
	rm -rf /root/easyrsa3
	rm -rf /root/wireguard
	rm -rf /root/config
	rm -rf /root/knot-resolver
	rm -rf /root/custom
fi

tar -xzf /root/backup*.tar.gz || true
rm -f /root/backup*.tar.gz || true

mkdir -p /tmp/antizapret/setup/etc/openvpn/easyrsa3
cp -r /root/easyrsa3/* /tmp/antizapret/setup/etc/openvpn/easyrsa3/ || true
cp /root/wireguard/* /tmp/antizapret/setup/etc/wireguard/ || true
cp /root/config/* /tmp/antizapret/setup/root/antizapret/config/ || true
cp /root/knot-resolver/* /tmp/antizapret/setup/etc/knot-resolver/ || true
cp /root/custom/* /tmp/antizapret/setup/root/antizapret/ || true

rm -rf /root/easyrsa3
rm -rf /root/wireguard
rm -rf /root/config
rm -rf /root/knot-resolver
rm -rf /root/custom

echo "SETUP_DATE=$(date --iso-8601=seconds)
OPENVPN_UDP_ENABLE=$OPENVPN_UDP_ENABLE
OPENVPN_TCP_ENABLE=$OPENVPN_TCP_ENABLE
WIREGUARD_ENABLE=$WIREGUARD_ENABLE
OPENVPN_PATCH=$OPENVPN_PATCH
OPENVPN_DCO=$OPENVPN_DCO
AWG2_MASQUERADE=$AWG2_MASQUERADE
WARP_PROVIDER=$WARP_PROVIDER
ANTIZAPRET_WARP=$ANTIZAPRET_WARP
ANTIZAPRET_WARP_PRIVATE_KEY=
ANTIZAPRET_WARP_PUBLIC_KEY=
ANTIZAPRET_WARP_ENDPOINT=
ANTIZAPRET_WARP_ADDRESS=
VPN_WARP=$VPN_WARP
VPN_WARP_PRIVATE_KEY=
VPN_WARP_PUBLIC_KEY=
VPN_WARP_ENDPOINT=
VPN_WARP_ADDRESS=
PROTON_ANTIZAPRET_PRIVATE_KEY=$PROTON_ANTIZAPRET_PRIVATE_KEY
PROTON_ANTIZAPRET_PUBLIC_KEY=$PROTON_ANTIZAPRET_PUBLIC_KEY
PROTON_ANTIZAPRET_ADDRESS=$PROTON_ANTIZAPRET_ADDRESS
PROTON_ANTIZAPRET_ENDPOINT_HOST=$PROTON_ANTIZAPRET_ENDPOINT_HOST
PROTON_ANTIZAPRET_ENDPOINT_PORT=$PROTON_ANTIZAPRET_ENDPOINT_PORT
PROTON_VPN_PRIVATE_KEY=$PROTON_VPN_PRIVATE_KEY
PROTON_VPN_PUBLIC_KEY=$PROTON_VPN_PUBLIC_KEY
PROTON_VPN_ADDRESS=$PROTON_VPN_ADDRESS
PROTON_VPN_ENDPOINT_HOST=$PROTON_VPN_ENDPOINT_HOST
PROTON_VPN_ENDPOINT_PORT=$PROTON_VPN_ENDPOINT_PORT
ANTIZAPRET_DNS=$ANTIZAPRET_DNS
VPN_DNS=$VPN_DNS
ANTIZAPRET_ADBLOCK=$ANTIZAPRET_ADBLOCK
VPN_ADBLOCK=$VPN_ADBLOCK
ALTERNATIVE_CLIENT_IP=$ALTERNATIVE_CLIENT_IP
ALTERNATIVE_FAKE_IP=$ALTERNATIVE_FAKE_IP
OPENVPN_BACKUP_UDP=$OPENVPN_BACKUP_UDP
OPENVPN_BACKUP_TCP=$OPENVPN_BACKUP_TCP
WIREGUARD_BACKUP=$WIREGUARD_BACKUP
OPENVPN_DUPLICATE=$OPENVPN_DUPLICATE
OPENVPN_LOG=$OPENVPN_LOG
SSH_PROTECTION=$SSH_PROTECTION
ATTACK_PROTECTION=$ATTACK_PROTECTION
SCAN_PROTECTION=$SCAN_PROTECTION
TORRENT_GUARD=$TORRENT_GUARD
RESTRICT_FORWARD=$RESTRICT_FORWARD
CLIENT_ISOLATION=$CLIENT_ISOLATION
OPENVPN_HOST=$OPENVPN_HOST
WIREGUARD_HOST=$WIREGUARD_HOST
ROUTE_ALL=$ROUTE_ALL
DISCORD_INCLUDE=$DISCORD_INCLUDE
CLOUDFLARE_INCLUDE=$CLOUDFLARE_INCLUDE
TELEGRAM_INCLUDE=$TELEGRAM_INCLUDE
WHATSAPP_INCLUDE=$WHATSAPP_INCLUDE
ROBLOX_INCLUDE=$ROBLOX_INCLUDE
AMAZON_INCLUDE=$AMAZON_INCLUDE
HETZNER_INCLUDE=$HETZNER_INCLUDE
DIGITALOCEAN_INCLUDE=$DIGITALOCEAN_INCLUDE
OVH_INCLUDE=$OVH_INCLUDE
GOOGLE_INCLUDE=$GOOGLE_INCLUDE
AKAMAI_INCLUDE=$AKAMAI_INCLUDE
CLEAR_HOSTS=y
TXQUEUELEN=10000
MTU=1420
SEGMENTATION_OFFLOAD=off
DEFAULT_INTERFACE=
DEFAULT_IP=
ANTIZAPRET_OUT_INTERFACE=
ANTIZAPRET_OUT_IP=
VPN_OUT_INTERFACE=
VPN_OUT_IP=
CLIENT_IP=
FAKE_IP=" > /tmp/antizapret/setup/root/antizapret/setup

mkdir -p /var/cache/knot-resolver
mkdir -p /var/cache/knot-resolver2

find /tmp/antizapret -type f -exec chmod 644 {} +
find /tmp/antizapret -type d -exec chmod 755 {} +
find /tmp/antizapret/setup/root/antizapret -type f -exec chmod +x {} +
find /tmp/antizapret/setup/etc/openvpn/server/scripts -type f -exec chmod +x {} +
chown -R knot-resolver:knot-resolver /var/cache/knot-resolver
chown -R knot-resolver:knot-resolver /var/cache/knot-resolver2

rm -rf /root/antizapret
cp -r /tmp/antizapret/setup/* /
rm -rf /tmp/dnslib
rm -rf /tmp/antizapret

if [[ "$ANTIZAPRET_DNS" != '1' ]]; then
	sed -i "s/local dns1 = 1/local dns1 = $ANTIZAPRET_DNS/" /etc/knot-resolver/kresd.conf
fi

if [[ "$VPN_DNS" == '3' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 9.9.9.10"\npush "dhcp-option DNS 149.112.112.10"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/9.9.9.10, 149.112.112.10/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '4' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 77.88.8.8"\npush "dhcp-option DNS 77.88.8.1"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/77.88.8.8, 77.88.8.1/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '5' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 8.8.8.8"\npush "dhcp-option DNS 8.8.4.4"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/8.8.8.8, 8.8.4.4/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '6' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 94.140.14.14"\npush "dhcp-option DNS 94.140.15.15"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/94.140.14.14, 94.140.15.15/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '7' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 83.220.169.155"\npush "dhcp-option DNS 212.109.195.93"\npush "dhcp-option DNS 195.133.25.16"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/83.220.169.155, 212.109.195.93, 195.133.25.16/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '8' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 111.88.96.50"\npush "dhcp-option DNS 111.88.96.51"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/111.88.96.50, 111.88.96.51/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
elif [[ "$VPN_DNS" == '9' ]]; then
	sed -i '/push "dhcp-option DNS 1\.1\.1\.1"/,+1c push "dhcp-option DNS 193.233.112.67"\npush "dhcp-option DNS 193.233.112.68"\npush "dhcp-option DNS 45.155.204.190"\npush "dhcp-option DNS 37.230.192.51"' /etc/openvpn/server/vpn*.conf
	sed -i 's/1\.1\.1\.1, 1\.0\.0\.1/193.233.112.67, 193.233.112.68, 45.155.204.190, 37.230.192.51/' /etc/wireguard/templates/vpn-client*.conf /etc/amneziawg/templates/vpn2-client.conf
fi

if [[ "$ALTERNATIVE_FAKE_IP" == 'n' ]]; then
	sed -i "s/198\.18\./${IP}\.30\./g" /root/antizapret/proxy.py
fi

if [[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]]; then
	sed -i 's/10\./172\./g' /etc/knot-resolver/kresd.conf
	sed -i 's/10\./172\./g' /etc/openvpn/server/*.conf
	sed -i 's/10\./172\./g' /etc/wireguard/templates/*.conf
	sed -i 's/10\./172\./g' /etc/amneziawg/templates/*.conf
	find /etc/wireguard -name '*.conf' -exec sed -i 's/s = 10\./s = 172\./g' {} +
	find /etc/amneziawg -maxdepth 1 -name '*.conf' -exec sed -i 's/s = 10\./s = 172\./g' {} +
else
	find /etc/wireguard -name '*.conf' -exec sed -i 's/s = 172\./s = 10\./g' {} +
	find /etc/amneziawg -maxdepth 1 -name '*.conf' -exec sed -i 's/s = 172\./s = 10\./g' {} +
fi

if [[ "$OPENVPN_DUPLICATE" == 'n' ]]; then
	sed -i '/duplicate-cn/s/^/#/' /etc/openvpn/server/*.conf
fi

if [[ "$OPENVPN_LOG" == 'y' ]]; then
	sed -i '/^#\(verb\|log\|status\)/s/^#//' /etc/openvpn/server/*.conf
fi

sed -i '/function policy\.PASS(state, _)/,/^end$/s/return state/return nil/' /usr/lib/knot-resolver/kres_modules/policy.lua
sed -i -z -E 's/policy\.DENY_MSG\([^)]*kres\.extended_error\.NOTSUP[^)]*\)/policy.DENY/g' /usr/lib/knot-resolver/kres_modules/policy.lua

/root/antizapret/doall.sh noclear

/root/antizapret/client.sh 4

systemctl enable kresd@1
systemctl enable kresd@2
systemctl enable antizapret
systemctl enable antizapret-update.timer
systemctl enable antizapret-update
if [[ "$OPENVPN_UDP_ENABLE" == 'y' ]]; then
	systemctl enable openvpn-server@antizapret-udp
	systemctl enable openvpn-server@vpn-udp
fi
if [[ "$OPENVPN_TCP_ENABLE" == 'y' ]]; then
	systemctl enable openvpn-server@antizapret-tcp
	systemctl enable openvpn-server@vpn-tcp
fi
if [[ "$WIREGUARD_ENABLE" == 'y' ]]; then
	systemctl enable wg-quick@antizapret
	systemctl enable wg-quick@vpn
	systemctl enable amneziawg@antizapret2
	systemctl enable amneziawg@vpn2
	systemctl restart amneziawg@antizapret2
	systemctl restart amneziawg@vpn2
fi

ERRORS=

if [[ "$OPENVPN_PATCH" != '1' ]]; then
	if ! /root/antizapret/patch-openvpn.sh "$OPENVPN_PATCH"; then
		ERRORS+="\n\e[1;31mAnti-censorship patch for OpenVPN has not installed!\e[0m Please run '/root/antizapret/patch-openvpn.sh' after rebooting\n"
	fi
fi

if [[ "$OPENVPN_DCO" == 'y' ]]; then
	if ! /root/antizapret/openvpn-dco.sh y; then
		ERRORS+="\n\e[1;31mOpenVPN DCO has not turn on!\e[0m Please run '/root/antizapret/openvpn-dco.sh y' after rebooting\n"
	fi
fi

if [[ -n "$ERRORS" ]]; then
	echo -e "$ERRORS"
fi

if [[ -z "$(swapon --show)" ]]; then
	set +e
	SWAPFILE=/swapfile
	SWAPSIZE=1024
	dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAPSIZE
	chmod 600 $SWAPFILE
	mkswap $SWAPFILE
	swapon $SWAPFILE
	echo $SWAPFILE none swap sw 0 0 >> /etc/fstab
fi

echo
echo -e '\e[1;32mAntiZapret VPN + full VPN installed successfully!\e[0m'
reboot
