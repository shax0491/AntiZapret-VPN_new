#!/bin/sh
# usage: awg3-up.sh <iface>   |   awg3-up.sh down <iface>
if [ "$1" = "down" ]; then ip link del "$2" 2>/dev/null || true; /usr/local/sbin/awg3-rules.sh down; exit 0; fi
I=$1; C=/etc/amnezia/amneziawg3/$I.conf
ip link show "$I" >/dev/null 2>&1 || amneziawg-go "$I"
grep -vE "^(Address|MTU) " "$C" > /run/$I.setconf; chmod 600 /run/$I.setconf
awg setconf "$I" /run/$I.setconf; rm -f /run/$I.setconf
ip addr replace 10.9.0.1/24 dev "$I"
ip addr replace 10.9.1.1/24 dev "$I"
ip link set "$I" mtu 1280 up
/usr/local/sbin/awg3-rules.sh up
