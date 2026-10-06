#!/bin/sh
# AmneziaWG 3.0 (interface awg1) firewall rules.
#   split 10.9.0.0/24 - antizapret: mirrors the 10.29 rules (DNS -> 127.1.1.1, connmark, drop not in antizapret-forward)
#   full  10.9.1.0/24 - whole-traffic VPN: mirrors the 10.28 rules (DNS -> 127.2.2.2, no drop)
# usage: awg3-rules.sh up|down
S=10.9.0.0/24
F=10.9.1.0/24
OUT=$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
add(){ t=$1; shift; iptables -w -t $t -C "$@" 2>/dev/null || iptables -w -t $t -A "$@"; }
del(){ t=$1; shift; while iptables -w -t $t -C "$@" 2>/dev/null; do iptables -w -t $t -D "$@"; done; }
# client ports 51900-51999 (random per client, see awg3_clients.py) -> ListenPort 51821
if [ "$1" = "down" ]; then
  del nat PREROUTING -i $OUT -p udp --dport 51900:51999 -j REDIRECT --to-ports 51821
  del nat PREROUTING -s $S -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
  del nat PREROUTING -s $S -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
  del nat PREROUTING -s $S ! -d 198.18.0.0/15 -j CONNMARK --set-xmark 0x1/0xffffffff
  del nat PREROUTING -s $S -d 198.18.0.0/15 -j ANTIZAPRET-MAPPING
  del filter FORWARD -s $S -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
  del mangle FORWARD -s $S -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  del nat POSTROUTING -s $S -o $OUT -j MASQUERADE
  # policy routing: same as the 10.29 / 10.28 PostUp rules in up.sh (without WARP fwmark)
  ip rule del from $S to $S lookup main priority 5000 2>/dev/null || true
  ip rule del from $S lookup 13335 priority 10000 2>/dev/null || true
  ip rule del from $F to $F lookup main priority 5000 2>/dev/null || true
  ip rule del from $F lookup 13336 priority 10000 2>/dev/null || true
  del nat PREROUTING -s $F -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
  del nat PREROUTING -s $F -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
  del nat PREROUTING -s $F -d 198.18.0.0/15 -j ANTIZAPRET-MAPPING
  del mangle FORWARD -s $F -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  del nat POSTROUTING -s $F -o $OUT -j MASQUERADE
  exit 0
fi
add nat PREROUTING -i $OUT -p udp --dport 51900:51999 -j REDIRECT --to-ports 51821
# split
add nat PREROUTING -s $S -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
add nat PREROUTING -s $S -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
add nat PREROUTING -s $S ! -d 198.18.0.0/15 -j CONNMARK --set-xmark 0x1/0xffffffff
add nat PREROUTING -s $S -d 198.18.0.0/15 -j ANTIZAPRET-MAPPING
iptables -w -C FORWARD -s $S -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP 2>/dev/null || iptables -w -I FORWARD 2 -s $S -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
add mangle FORWARD -s $S -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
add nat POSTROUTING -s $S -o $OUT -j MASQUERADE
# policy routing for split: antizapret traffic leaves through warp-antizapret (table 13335)
ip rule del from $S to $S lookup main priority 5000 2>/dev/null || true
ip rule add from $S to $S lookup main priority 5000 || true
ip rule del from $S lookup 13335 priority 10000 2>/dev/null || true
ip rule add from $S lookup 13335 priority 10000 || true
# full
ip rule del from $F to $F lookup main priority 5000 2>/dev/null || true
ip rule add from $F to $F lookup main priority 5000 || true
ip rule del from $F lookup 13336 priority 10000 2>/dev/null || true
ip rule add from $F lookup 13336 priority 10000 || true
add nat PREROUTING -s $F -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
add nat PREROUTING -s $F -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
add nat PREROUTING -s $F -d 198.18.0.0/15 -j ANTIZAPRET-MAPPING
add mangle FORWARD -s $F -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
add nat POSTROUTING -s $F -o $OUT -j MASQUERADE
