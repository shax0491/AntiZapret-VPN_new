#!/usr/bin/env bash
# Тест реверса на ЗАРУБЕЖНОЙ ноде-выходе: туннель инициирован отсюда к РФ-relay, переживает бан ВХОДЯЩИХ из РФ.
# Конфиг: REVERSE_IFACE (azrN), REVERSE_RELAY_V4, [REVERSE_RELAY_V6], REVERSE_RELAY_PORT, [REVERSE_PEER_IP для ping].
# Имитация бана: DROP только NEW-соединений от relay (ответы на исходящие = ESTABLISHED проходят) — как делает ТСПУ.
DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
usage(){ echo "usage: $0 [--conf F] [--dry-run|--apply]"; exit 2; }
while [ $# -gt 0 ]; do case "$1" in --conf) CONF="$2"; shift 2;; --dry-run) shift;; --apply) APPLY=1; shift;; *) usage;; esac; done
load_conf
: "${REVERSE_IFACE:?}" "${REVERSE_RELAY_V4:?}" "${REVERSE_RELAY_PORT:?}"
IF="$REVERSE_IFACE"; HS_MAX=180
RULES=()   # добавленные правила (для trap-удаления)
EXTRA_RESTORE="iptables -w -D INPUT -s $REVERSE_RELAY_V4 -p udp --sport $REVERSE_RELAY_PORT -m conntrack --ctstate NEW -j DROP 2>/dev/null; ${REVERSE_RELAY_V6:+ip6tables -w -D INPUT -s $REVERSE_RELAY_V6 -p udp --sport $REVERSE_RELAY_PORT -m conntrack --ctstate NEW -j DROP 2>/dev/null}"
export EXTRA_RESTORE
cleanup(){ [ "$APPLY" = 1 ] || return 0; set +e
  iptables -w -D INPUT -s "$REVERSE_RELAY_V4" -p udp --sport "$REVERSE_RELAY_PORT" -m conntrack --ctstate NEW -j DROP 2>/dev/null
  [ -n "${REVERSE_RELAY_V6:-}" ] && ip6tables -w -D INPUT -s "$REVERSE_RELAY_V6" -p udp --sport "$REVERSE_RELAY_PORT" -m conntrack --ctstate NEW -j DROP 2>/dev/null
  disarm_all >/dev/null; }
trap cleanup EXIT

age(){ local h; h="$(wg show "$IF" latest-handshakes | awk '{print $2}' | sort -n | tail -n1)"; [ -n "$h" ] && [ "$h" != 0 ] && echo $(( $(date +%s) - h )) || echo 99999; }

if [ "$APPLY" != 1 ]; then
  echo "+ check: wg show $IF (endpoint=relay:$REVERSE_RELAY_PORT, keepalive>0, handshake<${HS_MAX}s)"
  echo "+ apply: iptables -I INPUT 1 -s $REVERSE_RELAY_V4 -p udp --sport $REVERSE_RELAY_PORT -m conntrack --ctstate NEW -j DROP (+v6), авто-откат 300с"
  echo "+ wait 45s; check: handshake fresh, ping ${REVERSE_PEER_IP:-<peer>} via $IF"
  echo "[PASS] dry-run (ничего не изменено)"; exit 0
fi

echo "== предусловия (read-only) =="
wg show "$IF" >/dev/null 2>&1 && ok "интерфейс $IF существует" || { no "нет интерфейса $IF"; summary; exit 1; }
ep="$(wg show "$IF" endpoints | awk '{print $2}' | head -n1)"
case "$ep" in "$REVERSE_RELAY_V4":*|"[${REVERSE_RELAY_V6:-none}]":*) ok "endpoint = relay ($ep): туннель ИСХОДЯЩИЙ с этой ноды";; *) no "endpoint $ep не совпадает с relay";; esac
ka="$(wg show "$IF" persistent-keepalive | awk '{print $2}' | head -n1)"
[ -n "$ka" ] && [ "$ka" != off ] && [ "$ka" -le 25 ] 2>/dev/null && ok "persistent-keepalive=$ka (держит conntrack)" || { no "keepalive=${ka:-off}: без keepalive ESTABLISHED протухнет и тест сломает туннель — стоп"; summary; exit 1; }
a="$(age)"; [ "$a" -le "$HS_MAX" ] && ok "handshake $a c назад" || { no "handshake устарел ($a c) ещё до теста"; summary; exit 1; }

arm_rollback
echo "== бан входящих NEW от relay =="
iptables -w -I INPUT 1 -s "$REVERSE_RELAY_V4" -p udp --sport "$REVERSE_RELAY_PORT" -m conntrack --ctstate NEW -j DROP
[ -n "${REVERSE_RELAY_V6:-}" ] && ip6tables -w -I INPUT 1 -s "$REVERSE_RELAY_V6" -p udp --sport "$REVERSE_RELAY_PORT" -m conntrack --ctstate NEW -j DROP || true
sleep 45                         # > 1 keepalive-цикла и rekey не обязателен: проверяем живость потока
a="$(age)"
[ "$a" -le "$HS_MAX" ] && ok "handshake жив при бане входящих ($a c)" || no "handshake умер ($a c): реверс НЕ переживает бан"
if [ -n "${REVERSE_PEER_IP:-}" ]; then ping -c3 -W3 -I "$IF" "$REVERSE_PEER_IP" >/dev/null 2>&1 && ok "ping peer $REVERSE_PEER_IP через $IF" || no "ping peer не проходит"; fi
cleanup; trap - EXIT
a="$(age)"; [ "$a" -le "$HS_MAX" ] && ok "после снятия бана туннель жив" || no "туннель не жив после снятия бана"
summary
