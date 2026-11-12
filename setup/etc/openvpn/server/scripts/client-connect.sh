#!/bin/bash

source /root/antizapret/setup
[[ -r /etc/knot-resolver/ipv6-mode ]] && IPV6_MODE="$(cat /etc/knot-resolver/ipv6-mode)" # эффективный режим (при сбое выхода up.sh ставит a)
PROFILE="$(awk -v n="$common_name" '$1==n {print $2}' /root/antizapret/config/ipv6-profile.txt 2>/dev/null | tail -n 1)"
[[ "$PROFILE" == 'ipv4' || "$PROFILE" == 'dual' ]] || PROFILE="${IPV6_PROFILE_DEFAULT:-dual}"

if [[ "$IPV6_MODE" == 'a' || "$PROFILE" == 'ipv4' ]]; then
	# Клиент без IPv6: убрать v6-маршруты сервера и заблокировать утечку на Windows
	echo 'push-remove "route-ipv6"' >> "$1"
	if [[ "$IV_PLAT" != 'linux' ]]; then
		echo 'push "route-ipv6 fc00::/7"
push "block-ipv6"' >> "$1"
	fi
fi

./scripts/custom-client-connect.sh "$@"