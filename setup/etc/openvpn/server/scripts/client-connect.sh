#!/bin/bash

source /root/antizapret/setup
if [[ "$IV_PLAT" != 'linux' && "$IPV6_MODE" == 'b' ]]; then
	echo 'push "ifconfig-ipv6 fdea:dead::2/64 fdea:dead::1"
push "route-ipv6 ::/0"' >> "$1"
elif [[ "$IV_PLAT" != 'linux' ]]; then
	echo 'push "route-ipv6 fc00::/7"
push "block-ipv6"' >> "$1"
fi

./scripts/custom-client-connect.sh "$@"