#!/usr/bin/env bash
# READ-ONLY аудит узла (DE1/NL2): IPv6, слои, guard, панель, egress != ingress. Ничего не меняет, секреты не печатает.
DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
set +e +o pipefail   # аудит должен дойти до конца: curl/ip с кодом !=0 — это FAIL-проверка, а не аварийный выход
[ "${1:-}" = "--conf" ] && CONF="$2"
load_conf
PANEL_PORT="${PANEL_PORT:-}"; PANEL_ALLOWED="${PANEL_ALLOWED_ADDRS:-127.0.0.1 ::1}"

echo "== IPv6 на узле =="
if ip -6 addr show scope global | grep -q inet6; then ok "есть global IPv6-адрес"; else no "нет global IPv6 (NL2 по заявлению должен иметь)"; fi
gw6="$(ip -6 route show default | awk '/default/{print $3; exit}')"
if [ -n "$gw6" ]; then
  st="$(ip -6 neigh show "$gw6" 2>/dev/null | awk '{print $NF}' | head -n1)"
  case "$st" in REACHABLE|STALE|DELAY|PROBE) ok "NDP gateway $gw6 = $st";; *) no "NDP gateway $gw6 = ${st:-нет записи} (FAILED = хостер не отдаёт v6, как DE2/DE4)";; esac
else no "нет default-маршрута IPv6"; fi
if curl -6 -s -m 6 -o /dev/null https://[2606:4700:4700::1111]/ 2>/dev/null; then ok "curl -6 наружу работает"; else no "curl -6 наружу НЕ работает"; fi

echo "== Слои VPN (read-only, без ключей) =="
for t in wg awg; do command -v "$t" >/dev/null 2>&1 && { for i in $($t show interfaces 2>/dev/null); do echo "[INFO] $t $i listen-port=$($t show "$i" listen-port)"; done; }; done
systemctl list-units --no-legend 'openvpn*' 2>/dev/null | awk '{print "[INFO] " $1 " " $3}' || true

echo "== Guard =="
iptables -w -S "$CHAIN" >/dev/null 2>&1 && ok "iptables chain $CHAIN" || no "iptables chain $CHAIN отсутствует"
ip6tables -w -S "$CHAIN" >/dev/null 2>&1 && ok "ip6tables chain $CHAIN" || no "ip6tables chain $CHAIN отсутствует"
iptables -w -S FORWARD | sed -n '2p' | grep -q -- "-j $CHAIN" && ok "FORWARD: jump первый" || no "FORWARD: jump не первый/отсутствует (ACCEPT AntiZapret обойдёт guard)"
iptables -w -t nat -S POSTROUTING | sed -n '2p' | grep -q -- "-j $NCHAIN" && ok "nat: SNAT-цепочка $NCHAIN первая (клиенты получают src egress)" || no "nat: $NCHAIN не подключена (клиентский трафик в egress уйдёт с приватным src)"
iptables -w -t mangle -S PREROUTING | grep -q -- "-j $MCHAIN" && ok "mangle mark-chain подключён" || no "mangle mark-chain не подключён"
for f in -4 -6; do
  [ "$f" = -6 ] && [ "$HAS_IPV6" != 1 ] && continue
  ip $f rule show | grep -Eq "^$PRIO:.*fwmark $MARK(/$MASK)? .*lookup $TABLE" && ok "ip $f rule fwmark->$TABLE" || no "ip $f rule fwmark->$TABLE отсутствует"
  ip $f route show table "$TABLE" | grep -Eq "blackhole default.*metric $BH_METRIC" && ok "ip $f blackhole metric $BH_METRIC" || no "ip $f blackhole отсутствует"
done
# MASQUERADE на WAN для клиентских подсетей безвреден ТОЛЬКО пока FORWARD-guard стоит первым (проверено выше)

echo "== Egress IP != ingress IP =="
for e in $EGRESS_IFACES; do
  ip link show dev "$e" >/dev/null 2>&1 || { no "egress iface $e отсутствует"; continue; }
  for fl in 4 6; do
    [ "$fl" = 6 ] && [ "$HAS_IPV6" != 1 ] && continue
    url="https://1.1.1.1/cdn-cgi/trace"; [ "$fl" = 6 ] && url="https://[2606:4700:4700::1111]/cdn-cgi/trace"
    eip="$(curl "-$fl" -s --interface "$e" --max-time 8 "$url" 2>/dev/null | awk -F= '/^ip=/{print $2}')"
    if [ -z "$eip" ]; then no "$e v$fl: выхода нет (v$fl)"; continue; fi
    echo "[INFO] $e v$fl egress=$eip"
    case " ${INGRESS_IPS:-} " in *" $eip "*) no "$e v$fl: egress IP == ingress IP ($eip)";; *) ok "$e v$fl: egress != ingress";; esac
  done
done

echo "== Изоляция панели =="
if [ -z "$PANEL_PORT" ]; then warn "PANEL_PORT не задан в конфиге — пропуск"; else
  bad=0
  if iptables -w -S INPUT | grep -q -- "--dport $PANEL_PORT .*-j DROP"; then ok "порт $PANEL_PORT закрыт INPUT DROP (исключения: ACCEPT для панели)"; PANEL_ALLOWED="$PANEL_ALLOWED 0.0.0.0 ::"; fi
  while read -r addr; do
    a="${addr%:*}"; a="${a#[}"; a="${a%]}"
    case " $PANEL_ALLOWED " in *" $a "*) ;; *) no "панель слушает на $addr (wildcard/публичный адрес)"; bad=1;; esac
  done < <(ss -Htln "sport = :$PANEL_PORT" | awk '{print $4}')
  [ "$bad" = 0 ] && ok "панель :$PANEL_PORT только на $PANEL_ALLOWED"
fi
summary
