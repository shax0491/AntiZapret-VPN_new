#!/bin/bash
#
# Добавление/удаление клиента
#
# chmod +x client.sh && ./client.sh [1-6] [имя_клиента] [срок_действия_сертификата]
#
# Срок действия сертификата в днях - только для OpenVPN
#
# Добавление и удаление клиента охватывают сразу все протоколы: OpenVPN, WireGuard,
# AmneziaWG 1.5 и AmneziaWG 2.0 - профили создаются/удаляются синхронно одной командой.
#
set -e
export LC_ALL=C
shopt -s nullglob

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

if (( $# > 3 )); then
	echo 'Too many parameters! Usage: ./client.sh [1-6] [client_name] [cert_expire_days]'
	exit 2
fi

SERVER_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
if [[ -z "$SERVER_IP" ]]; then
	echo 'Default IPv4 address not found!'
	exit 3
fi

export EASYRSA_PKI=/etc/openvpn/easyrsa3/pki
cd /root/antizapret
source setup
umask 022
OPTION="$1"
CLIENT_NAME="$2"
CLIENT_CERT_EXPIRE="$3"

AWG2=/etc/amneziawg

askClientName(){
	if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
		echo
		echo 'Enter client name: 1–32 alphanumeric characters (a-z, A-Z, 0-9) with underscore (_) or dash (-)'
		until [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; do
			read -rp 'Client name: ' -e CLIENT_NAME
		done
	fi
}

askClientCertExpire(){
	if ! [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] || (( CLIENT_CERT_EXPIRE <= 0 )) || (( CLIENT_CERT_EXPIRE > 3650 )); then
		echo
		echo 'Enter client certificate expiration days (1-3650):'
		until [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] && (( CLIENT_CERT_EXPIRE > 0 )) && (( CLIENT_CERT_EXPIRE <= 3650 )); do
			read -rp 'Certificate expiration days: ' -e -i 3650 CLIENT_CERT_EXPIRE
		done
	fi
}

setServerHost_FileName(){
	if [[ -z "$1" ]]; then
		SERVER_HOST="$SERVER_IP"
	else
		SERVER_HOST="$1"
	fi

	FILE_NAME="${CLIENT_NAME#antizapret-}"
	FILE_NAME="${FILE_NAME#vpn-}"
	FILE_NAME="${FILE_NAME}-(${SERVER_HOST})"
}

render() {
	local IFS=
	while read -r line; do
		while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]]; do
			local LHS="${BASH_REMATCH[1]}"
			local RHS="$(eval echo "\"$LHS\"")"
			line="${line//$LHS/$RHS}"
		done
		echo "$line"
	done < "$1"
}

# --- OpenVPN ---

initOpenVPN(){
	mkdir -p /etc/openvpn/easyrsa3
	mkdir -p /etc/openvpn/server/ccd
	mkdir -p /etc/openvpn/server/ccd2
	mkdir -p /etc/openvpn/server/logs

	if [[ ! -f /etc/openvpn/easyrsa3/pki/ca.crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/issued/antizapret-server.crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/private/antizapret-server.key ]]; then
		rm -rf /etc/openvpn/easyrsa3/pki
		/usr/share/easy-rsa/easyrsa init-pki
		EASYRSA_CA_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch --req-cn='AntiZapret CA' build-ca nopass
		EASYRSA_CERT_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch build-server-full 'antizapret-server' nopass
	fi

	EASYRSA_CRL_DAYS=3650 /usr/share/easy-rsa/easyrsa gen-crl
	chmod 755 /etc/openvpn/easyrsa3/pki
	chmod 644 /etc/openvpn/easyrsa3/pki/crl.pem
}

addOpenVPN(){
	setServerHost_FileName "$OPENVPN_HOST"

	if [[ ! -f /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/private/"$CLIENT_NAME".key ]]; then
		askClientCertExpire
		echo
		EASYRSA_CERT_EXPIRE="$CLIENT_CERT_EXPIRE" /usr/share/easy-rsa/easyrsa --batch build-client-full "$CLIENT_NAME" nopass
	else
		echo
		echo 'Client with that name already exists! Please enter different name for new client'
		echo
		if [[ "$CLIENT_CERT_EXPIRE" != "0" ]]; then
			echo 'Current client certificate expiration period:'
			openssl x509 -in /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt -noout -dates
			echo
			echo "Attention! Certificate renewal is NOT possible after 'notAfter' date"
			askClientCertExpire
			echo
			rm -f /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt
			/usr/share/easy-rsa/easyrsa --batch --days="$CLIENT_CERT_EXPIRE" sign client "$CLIENT_NAME"
		fi
	fi

	CA_CERT="$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/easyrsa3/pki/ca.crt")"
	CLIENT_CERT="$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/easyrsa3/pki/issued/$CLIENT_NAME.crt")"
	CLIENT_KEY="$(cat -- "/etc/openvpn/easyrsa3/pki/private/$CLIENT_NAME.key")"
	if [[ ! "$CA_CERT" ]] || [[ ! "$CLIENT_CERT" ]] || [[ ! "$CLIENT_KEY" ]]; then
		echo 'Cannot load client keys!'
		exit 4
	fi

	render "/etc/openvpn/client/templates/antizapret-udp.conf" > "/root/antizapret/client/openvpn/antizapret-udp/antizapret-$FILE_NAME-udp.ovpn"
	render "/etc/openvpn/client/templates/antizapret-tcp.conf" > "/root/antizapret/client/openvpn/antizapret-tcp/antizapret-$FILE_NAME-tcp.ovpn"
	render "/etc/openvpn/client/templates/antizapret.conf" > "/root/antizapret/client/openvpn/antizapret/antizapret-$FILE_NAME.ovpn"
	render "/etc/openvpn/client/templates/vpn-udp.conf" > "/root/antizapret/client/openvpn/vpn-udp/vpn-$FILE_NAME-udp.ovpn"
	render "/etc/openvpn/client/templates/vpn-tcp.conf" > "/root/antizapret/client/openvpn/vpn-tcp/vpn-$FILE_NAME-tcp.ovpn"
	render "/etc/openvpn/client/templates/vpn.conf" > "/root/antizapret/client/openvpn/vpn/vpn-$FILE_NAME.ovpn"

	echo "OpenVPN profile files (re)created for client '$CLIENT_NAME' at /root/antizapret/client/openvpn"
}

deleteOpenVPN(){
	setServerHost_FileName "$OPENVPN_HOST"

	if [[ ! -f /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt ]]; then
		echo "OpenVPN client '$CLIENT_NAME' not found, skipping"
		return 0
	fi
	echo

	/usr/share/easy-rsa/easyrsa --batch revoke "$CLIENT_NAME"
	EASYRSA_CRL_DAYS=3650 /usr/share/easy-rsa/easyrsa gen-crl
	chmod 755 /etc/openvpn/easyrsa3/pki
	chmod 644 /etc/openvpn/easyrsa3/pki/crl.pem

	rm -f /root/antizapret/client/openvpn/antizapret/antizapret-"$FILE_NAME".ovpn
	rm -f /root/antizapret/client/openvpn/antizapret-udp/antizapret-"$FILE_NAME"-udp.ovpn
	rm -f /root/antizapret/client/openvpn/antizapret-tcp/antizapret-"$FILE_NAME"-tcp.ovpn
	rm -f /root/antizapret/client/openvpn/vpn/vpn-"$FILE_NAME".ovpn
	rm -f /root/antizapret/client/openvpn/vpn-udp/vpn-"$FILE_NAME"-udp.ovpn
	rm -f /root/antizapret/client/openvpn/vpn-tcp/vpn-"$FILE_NAME"-tcp.ovpn

	echo "kill $CLIENT_NAME" | socat - UNIX-CONNECT:/run/openvpn-server/antizapret-udp.sock &>/dev/null || true
	echo "kill $CLIENT_NAME" | socat - UNIX-CONNECT:/run/openvpn-server/antizapret-tcp.sock &>/dev/null || true
	echo "kill $CLIENT_NAME" | socat - UNIX-CONNECT:/run/openvpn-server/vpn-udp.sock &>/dev/null || true
	echo "kill $CLIENT_NAME" | socat - UNIX-CONNECT:/run/openvpn-server/vpn-tcp.sock &>/dev/null || true

	echo "OpenVPN client '$CLIENT_NAME' successfully deleted"
}

listOpenVPN(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'OpenVPN client names:'
	ls /etc/openvpn/easyrsa3/pki/issued | sed 's/\.crt$//' | grep -v "^antizapret-server$" | sort
}

# --- WireGuard / AmneziaWG 1.5 ---

initWireGuard(){
	if [[ ! -f /etc/wireguard/key ]]; then
		echo
		echo 'Generating WireGuard/AmneziaWG server keys'
		PRIVATE_KEY="$(wg genkey)"
		PUBLIC_KEY="$(echo "${PRIVATE_KEY}" | wg pubkey)"
		echo "PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}" > /etc/wireguard/key
		render "/etc/wireguard/templates/antizapret.conf" > "/etc/wireguard/antizapret.conf"
		render "/etc/wireguard/templates/vpn.conf" > "/etc/wireguard/vpn.conf"
	fi
}

addWireGuard(){
	setServerHost_FileName "$WIREGUARD_HOST"
	echo

	source /etc/wireguard/key
	IPS="$(cat /etc/wireguard/ips)"

	# AntiZapret

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/antizapret.conf)"

	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PUBLIC_KEY="$(echo "$CLIENT_BLOCK" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d '/' -f 1)"
		echo 'Client (AntiZapret) with that name already exists! Please enter different name for new client'
	else
		CLIENT_PRIVATE_KEY="$(wg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)"
		CLIENT_PRESHARED_KEY="$(wg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" /etc/wireguard/antizapret.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" /etc/wireguard/antizapret.conf; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The WireGuard/AmneziaWG subnet can support only 253 clients!'
				exit 5
			fi
		done
		echo "# Client = ${CLIENT_NAME}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "/etc/wireguard/antizapret.conf"
		wg syncconf antizapret <(wg-quick strip antizapret 2>/dev/null) &>/dev/null || true
	fi

	render "/etc/wireguard/templates/antizapret-client-wg.conf" > "/root/antizapret/client/wireguard/antizapret/antizapret-$FILE_NAME-wg.conf"
	render "/etc/wireguard/templates/antizapret-client-am.conf" > "/root/antizapret/client/amneziawg/antizapret/antizapret-$FILE_NAME-am.conf"

	# VPN

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/vpn.conf)"
	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PUBLIC_KEY="$(echo "$CLIENT_BLOCK" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d '/' -f 1)"
		echo 'Client (VPN) with that name already exists! Please enter different name for new client'
	else
		CLIENT_PRIVATE_KEY="$(wg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)"
		CLIENT_PRESHARED_KEY="$(wg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" /etc/wireguard/vpn.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" /etc/wireguard/vpn.conf; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The WireGuard/AmneziaWG subnet can support only 253 clients!'
				exit 6
			fi
		done
		echo "# Client = ${CLIENT_NAME}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "/etc/wireguard/vpn.conf"
		wg syncconf vpn <(wg-quick strip vpn 2>/dev/null) &>/dev/null || true
	fi

	render "/etc/wireguard/templates/vpn-client-wg.conf" > "/root/antizapret/client/wireguard/vpn/vpn-$FILE_NAME-wg.conf"
	render "/etc/wireguard/templates/vpn-client-am.conf" > "/root/antizapret/client/amneziawg/vpn/vpn-$FILE_NAME-am.conf"

	echo "WireGuard/AmneziaWG 1.5 profile files (re)created for client '$CLIENT_NAME' at /root/antizapret/client/wireguard and /root/antizapret/client/amneziawg"
}

deleteWireGuard(){
	setServerHost_FileName "$WIREGUARD_HOST"

	if ! grep -q "# Client = ${CLIENT_NAME}" "/etc/wireguard/antizapret.conf" 2>/dev/null && ! grep -q "# Client = ${CLIENT_NAME}" "/etc/wireguard/vpn.conf" 2>/dev/null; then
		echo "WireGuard/AmneziaWG 1.5 client '$CLIENT_NAME' not found, skipping"
		return 0
	fi
	echo

	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" /etc/wireguard/antizapret.conf
	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" /etc/wireguard/vpn.conf

	sed -i '/^$/N;/^\n$/D' /etc/wireguard/antizapret.conf
	sed -i '/^$/N;/^\n$/D' /etc/wireguard/vpn.conf

	rm -f /root/antizapret/client/{wireguard,amneziawg}/antizapret/antizapret-"$FILE_NAME"-*.conf
	rm -f /root/antizapret/client/{wireguard,amneziawg}/vpn/vpn-"$FILE_NAME"-*.conf

	wg syncconf antizapret <(wg-quick strip antizapret 2>/dev/null) &>/dev/null || true
	wg syncconf vpn <(wg-quick strip vpn 2>/dev/null) &>/dev/null || true

	echo "WireGuard/AmneziaWG 1.5 client '$CLIENT_NAME' successfully deleted"
}

listWireGuard(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'WireGuard/AmneziaWG 1.5 client names:'
	grep -hE "^# Client" /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf 2>/dev/null | cut -d '=' -f 2 | sed 's/ //g' | sort -u
}

# --- AmneziaWG 2.0 ---

awg2Masquerade(){
	# I1/I2 - маскировка первого пакета под TLS/QUIC/SIP, выбор сделан в setup.sh (AWG2_MASQUERADE)
	case "${AWG2_MASQUERADE:-2}" in
		1)
			I1='<b 0x160303003a020000360303cc2cead5190af433d0345004067af01c2d93f5b12b3be32a608efd11d9e8b9560e0cd623e0c25aae0bf22195532fd8c02c000000>'
			I2=''
			;;
		3)
			I1='<b 0x494e56495445207369703a626f624062696c6f78692e636f6d205349502f322e300d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a4d61782d466f7277617264733a2037300d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74616374203c7369703a616c69636540706333332e61746c616e74612e636f6d3e0d0a436f6e74656e742d547970653a206170706c69636174696f6e2f7364700d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>'
			I2='<b 0x5349502f322e302031303020547279696e670d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>'
			;;
		*)
			I1='<b 0xcb0000000108625dd0eec612a22e0847686b87c6ffef2d0042048a4899094013c8c90acfc4d0ead2886fd6420d14743260085a1ab16a9a25dc0115d93efefa21f5203dc2fef27947b2c88cab4e5323f5ef628bc68220c7e4aff7511189aea0ebe96d1ead6284cae30d73d0906efb61ad16baf6026918e2fc0bd4d4482de525d8461df169132aeff54b4872768e5b446ffdf775f5a90c9881d770b378dec72154cb21460dcff5e76e26a41a22aba2df9d6d122e6ac47ee28718d10231361b5deb48383cfea037589e4b6a6f1229a38822a5b72a5f5d330e73cdc6dd62edfee565961a8dee1924618680f0c1ab1616b4ab0b9d0e0dfaa26094ae1e333b49f29c4177df5818610972ea7d42871cbaa64b8f244057eb7d429c22074c450de567368c1e4a35a3286e8bcab2ed00938801dca0869ca5c9a887e4327b0b3b9b06f0543a2b447d00025081a371dc47a66485a2bde7e7fe4cbf67a03c8bfa3d745f3d3ad22ea1495578c1803fe811945cc4ff97ac87e50a2b9f3bcf448e575d5861d9e62b94f5cd116b21533a913d852ac4fc4ec623dc624f527495e115660838103457d55a35e6628dc0e2ca815a8cfc881ddfa9b1ecf331f73e5db485995a2ddb5c66196cb2a44afbdca1dd638d9d0ec1d70aff0d9e1dd74a8e20924230c23abf2e10de0bf4446eca009e0ad6666f39c3862fc40cf2ee76c860a77e4f3e033f7b31122e2a49ede34e9bcc363822d86c05a9b5bd50b6b7ce03a8b1f17020c7646a7e>'
			I2=''
			;;
	esac
}

initAmneziaWG2(){
	if [[ ! -f "$AWG2/key" ]]; then
		echo
		echo 'Generating AmneziaWG 2.0 server keys'
		mkdir -p "$AWG2"
		chmod 700 "$AWG2"
		PRIVATE_KEY="$(awg genkey)"
		PUBLIC_KEY="$(echo "${PRIVATE_KEY}" | awg pubkey)"
		echo "PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}" > "$AWG2/key"
		render "$AWG2/templates/antizapret2.conf" > "$AWG2/antizapret2.conf"
		render "$AWG2/templates/vpn2.conf" > "$AWG2/vpn2.conf"
	fi
}

addAmneziaWG2(){
	setServerHost_FileName "$WIREGUARD_HOST"
	echo

	source "$AWG2/key"
	IPS="$(cat /etc/wireguard/ips)"
	awg2Masquerade

	mkdir -p /root/antizapret/client/amneziawg2/{antizapret,vpn}

	# AntiZapret

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" "$AWG2/antizapret2.conf")"

	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d '/' -f 1)"
	else
		CLIENT_PRIVATE_KEY="$(awg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | awg pubkey)"
		CLIENT_PRESHARED_KEY="$(awg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" "$AWG2/antizapret2.conf" | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" "$AWG2/antizapret2.conf"; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The AmneziaWG 2.0 subnet can support only 253 clients!'
				exit 9
			fi
		done
		echo "# Client = ${CLIENT_NAME}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "$AWG2/antizapret2.conf"
		awg syncconf antizapret2 <(awg-quick strip "$AWG2/antizapret2.conf" 2>/dev/null) &>/dev/null || true
	fi

	render "$AWG2/templates/antizapret2-client.conf" > "/root/antizapret/client/amneziawg2/antizapret/antizapret2-$FILE_NAME-am2.conf"

	# VPN

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" "$AWG2/vpn2.conf")"
	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d '/' -f 1)"
	else
		CLIENT_PRIVATE_KEY="$(awg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | awg pubkey)"
		CLIENT_PRESHARED_KEY="$(awg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" "$AWG2/vpn2.conf" | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" "$AWG2/vpn2.conf"; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The AmneziaWG 2.0 subnet can support only 253 clients!'
				exit 10
			fi
		done
		echo "# Client = ${CLIENT_NAME}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "$AWG2/vpn2.conf"
		awg syncconf vpn2 <(awg-quick strip "$AWG2/vpn2.conf" 2>/dev/null) &>/dev/null || true
	fi

	render "$AWG2/templates/vpn2-client.conf" > "/root/antizapret/client/amneziawg2/vpn/vpn2-$FILE_NAME-am2.conf"

	echo "AmneziaWG 2.0 profile files (re)created for client '$CLIENT_NAME' at /root/antizapret/client/amneziawg2"
}

deleteAmneziaWG2(){
	setServerHost_FileName "$WIREGUARD_HOST"

	if [[ ! -f "$AWG2/antizapret2.conf" ]] || { ! grep -q "# Client = ${CLIENT_NAME}" "$AWG2/antizapret2.conf" 2>/dev/null && ! grep -q "# Client = ${CLIENT_NAME}" "$AWG2/vpn2.conf" 2>/dev/null; }; then
		echo "AmneziaWG 2.0 client '$CLIENT_NAME' not found, skipping"
		return 0
	fi
	echo

	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" "$AWG2/antizapret2.conf"
	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" "$AWG2/vpn2.conf"

	sed -i '/^$/N;/^\n$/D' "$AWG2/antizapret2.conf"
	sed -i '/^$/N;/^\n$/D' "$AWG2/vpn2.conf"

	rm -f /root/antizapret/client/amneziawg2/antizapret/antizapret2-"$FILE_NAME"-am2.conf
	rm -f /root/antizapret/client/amneziawg2/vpn/vpn2-"$FILE_NAME"-am2.conf

	awg syncconf antizapret2 <(awg-quick strip "$AWG2/antizapret2.conf" 2>/dev/null) &>/dev/null || true
	awg syncconf vpn2 <(awg-quick strip "$AWG2/vpn2.conf" 2>/dev/null) &>/dev/null || true

	echo "AmneziaWG 2.0 client '$CLIENT_NAME' successfully deleted"
}

listAmneziaWG2(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'AmneziaWG 2.0 client names:'
	grep -hE "^# Client" "$AWG2/antizapret2.conf" "$AWG2/vpn2.conf" 2>/dev/null | cut -d '=' -f 2 | sed 's/ //g' | sort -u
}

# --- Unified actions across all protocols ---

addClient(){
	initOpenVPN
	initWireGuard
	command -v awg &>/dev/null && initAmneziaWG2 || echo 'AmneziaWG 2.0 (awg) not installed - skipping. Re-run setup.sh to install it.'

	addOpenVPN
	addWireGuard
	command -v awg &>/dev/null && addAmneziaWG2 || true
}

deleteClient(){
	deleteOpenVPN
	deleteWireGuard
	command -v awg &>/dev/null && deleteAmneziaWG2 || true
}

listClients(){
	listOpenVPN
	listWireGuard
	command -v awg &>/dev/null && listAmneziaWG2 || true
}

recreate(){
	echo

	rm -rf /root/antizapret/client
	mkdir -p /root/antizapret/client/{openvpn/{antizapret,antizapret-tcp,antizapret-udp,vpn,vpn-tcp,vpn-udp},wireguard/{antizapret,vpn},amneziawg/{antizapret,vpn},amneziawg2/{antizapret,vpn}}

	# OpenVPN
	if [[ -d /etc/openvpn/easyrsa3/pki/issued ]]; then
		initOpenVPN
		CLIENT_CERT_EXPIRE=0
		ls /etc/openvpn/easyrsa3/pki/issued | sed 's/\.crt$//' | grep -v "^antizapret-server$" | sort | while read -r CLIENT_NAME; do
			if [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				addOpenVPN >/dev/null
				echo "OpenVPN profile files recreated for client '$CLIENT_NAME'"
			else
				echo "OpenVPN client name '$CLIENT_NAME' is invalid! No profile files recreated"
			fi
		done
	else
		CLIENT_NAME=antizapret-client
		CLIENT_CERT_EXPIRE=3650
		echo "Creating OpenVPN server keys and first OpenVPN client: '$CLIENT_NAME'"
		initOpenVPN
		addOpenVPN >/dev/null
	fi

	# WireGuard/AmneziaWG 1.5
	if [[ -f /etc/wireguard/key && -f /etc/wireguard/antizapret.conf && -f /etc/wireguard/vpn.conf ]]; then
		grep -hE "^# Client" /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf | cut -d '=' -f 2 | sed 's/ //g' | sort -u | while read -r CLIENT_NAME; do
			if [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				addWireGuard >/dev/null
				echo "WireGuard/AmneziaWG 1.5 profile files recreated for client '$CLIENT_NAME'"
			else
				echo "WireGuard/AmneziaWG client name '$CLIENT_NAME' is invalid! No profile files recreated"
			fi
		done
	else
		CLIENT_NAME=antizapret-client
		echo "Creating WireGuard/AmneziaWG server keys and first WireGuard/AmneziaWG client: '$CLIENT_NAME'"
		initWireGuard
		addWireGuard >/dev/null
	fi

	# AmneziaWG 2.0
	if command -v awg &>/dev/null; then
		initAmneziaWG2
		if [[ -f "$AWG2/antizapret2.conf" && -f "$AWG2/vpn2.conf" ]] && grep -qE "^# Client" "$AWG2/antizapret2.conf" "$AWG2/vpn2.conf"; then
			grep -hE "^# Client" "$AWG2/antizapret2.conf" "$AWG2/vpn2.conf" | cut -d '=' -f 2 | sed 's/ //g' | sort -u | while read -r CLIENT_NAME; do
				if [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
					addAmneziaWG2 >/dev/null
					echo "AmneziaWG 2.0 profile files recreated for client '$CLIENT_NAME'"
				else
					echo "AmneziaWG 2.0 client name '$CLIENT_NAME' is invalid! No profile files recreated"
				fi
			done
		else
			CLIENT_NAME=antizapret-client
			echo "Creating AmneziaWG 2.0 server keys and first client: '$CLIENT_NAME'"
			addAmneziaWG2 >/dev/null
		fi
	else
		echo 'AmneziaWG 2.0 (awg) not installed - skipping. Run setup.sh to install it.'
	fi
}

backup(){
	echo

	rm -rf /root/antizapret/backup
	mkdir -p /root/antizapret/backup/wireguard
	mkdir -p /root/antizapret/backup/amneziawg
	mkdir -p /root/antizapret/backup/config
	mkdir -p /root/antizapret/backup/knot-resolver
	mkdir -p /root/antizapret/backup/custom

	cp -r /etc/openvpn/easyrsa3 /root/antizapret/backup
	cp -r /etc/wireguard/antizapret.conf /root/antizapret/backup/wireguard
	cp -r /etc/wireguard/vpn.conf /root/antizapret/backup/wireguard
	cp -r /etc/wireguard/key /root/antizapret/backup/wireguard
	cp -r "$AWG2/antizapret2.conf" /root/antizapret/backup/amneziawg 2>/dev/null || true
	cp -r "$AWG2/vpn2.conf" /root/antizapret/backup/amneziawg 2>/dev/null || true
	cp -r "$AWG2/key" /root/antizapret/backup/amneziawg 2>/dev/null || true
	cp -r /root/antizapret/config/*.txt /root/antizapret/backup/config || true
	cp -r /etc/knot-resolver/*.lua /root/antizapret/backup/knot-resolver || true
	cp -r /root/antizapret/custom*.sh /root/antizapret/backup/custom || true

	BACKUP_FILE="/root/antizapret/backup-$SERVER_IP.tar.gz"
	tar -czf $BACKUP_FILE -C /root/antizapret/backup easyrsa3 wireguard amneziawg config knot-resolver custom
	tar -tzf $BACKUP_FILE >/dev/null

	rm -rf /root/antizapret/backup

	echo "Backup configuration and clients (re)created at $BACKUP_FILE"
}

restore(){
	echo

	if [[ -e /root/backup*.tar.gz ]]; then
		rm -rf /root/easyrsa3
		rm -rf /root/wireguard
		rm -rf /root/amneziawg
		rm -rf /root/config
		rm -rf /root/knot-resolver
		rm -rf /root/custom
	fi

	tar -xzf /root/backup*.tar.gz -C /root || true
	rm -f /root/backup*.tar.gz || true

	if [[ ! -d /root/easyrsa3 && ! -d /root/wireguard && ! -d /root/config && ! -d /root/knot-resolver && ! -d /root/custom ]]; then
		echo 'Backup not found! Upload backup*.tar.gz to /root, or extract folders to /root: easyrsa3, wireguard, amneziawg, config, knot-resolver, custom'
		exit 8
	fi

	if [[ -d /root/easyrsa3/pki ]]; then
		rm -rf /etc/openvpn/easyrsa3/*
	fi

	cp -r /root/easyrsa3 /etc/openvpn/ || true
	cp /root/wireguard/* /etc/wireguard/ || true
	if [[ -d /root/amneziawg ]]; then
		mkdir -p "$AWG2"
		chmod 700 "$AWG2"
		cp /root/amneziawg/* "$AWG2/" || true
	fi
	cp /root/config/* /root/antizapret/config/ || true
	cp /root/knot-resolver/* /etc/knot-resolver/ || true
	cp /root/custom/* /root/antizapret/ || true

	rm -rf /root/easyrsa3
	rm -rf /root/wireguard
	rm -rf /root/amneziawg
	rm -rf /root/config
	rm -rf /root/knot-resolver
	rm -rf /root/custom

	./doall.sh ip
	initWireGuard
	initOpenVPN
	command -v awg &>/dev/null && initAmneziaWG2 || true
	recreate

	echo "Configuration and clients restored from backup"
	reboot
}

if ! [[ "$OPTION" =~ ^[1-6]$ ]]; then
	echo
	echo 'Please choose option:'
	echo '    1) Add client (OpenVPN + WireGuard + AmneziaWG 1.5 + AmneziaWG 2.0)'
	echo '    2) Delete client (all protocols)'
	echo '    3) List clients (all protocols)'
	echo '    4) (Re)create all client profile files'
	echo '    5) Backup configuration and clients'
	echo '    6) Restore configuration and clients from backup'
	until [[ "$OPTION" =~ ^[1-6]$ ]]; do
		read -rp 'Option choice [1-6]: ' -e OPTION
	done
fi

case "$OPTION" in
	1)
		echo "Add client $CLIENT_NAME $CLIENT_CERT_EXPIRE"
		askClientName
		addClient
		;;
	2)
		echo "Delete client $CLIENT_NAME"
		listClients
		askClientName
		deleteClient
		;;
	3)
		echo 'List clients'
		listClients
		;;
	4)
		echo '(Re)create all client profile files'
		recreate
		;;
	5)
		echo 'Backup configuration and clients'
		backup
		;;
	6)
		echo 'Restore configuration and clients from backup'
		restore
		;;
esac
exit 0
