#!/usr/bin/env bash
# Health-монитор egress. Мёртвый egress уезжает за blackhole (metric 5000 > 2000), живой возвращается на 100*(i+1).
# Direct/WAN маршрут в table 100 НЕ добавляется никогда. Живость = (handshake свежий, если это wg) И (HTTPS через iface).
DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
ONCE=0; INTERVAL="${INTERVAL:-30}"; HS_MAX_SEC="${HS_MAX_SEC:-180}"
usage(){ echo "usage: $0 [--conf F] [--dry-run|--apply] [--once] [--interval N]"; exit 2; }
while [ $# -gt 0 ]; do case "$1" in
  --conf) CONF="$2"; shift 2;; --dry-run) shift;; --apply) APPLY=1; shift;; --once) ONCE=1; shift;;
  --interval) INTERVAL="$2"; shift 2;; *) usage;; esac; done
load_conf
URLS4="${MONITOR_URLS_V4:-https://1.1.1.1/cdn-cgi/trace}"
URLS6="${MONITOR_URLS_V6:-https://[2606:4700:4700::1111]/cdn-cgi/trace}"
declare -A PREV

alive_wg(){ local hs now
  wg show "$1" >/dev/null 2>&1 || return 0            # не wg (например tun) — handshake не проверяем
  hs="$(wg show "$1" latest-handshakes | awk '{print $2}' | sort -n | tail -n1)"
  [ -n "$hs" ] && [ "$hs" != 0 ] || return 1
  now="$(date +%s)"; [ $((now-hs)) -le "$HS_MAX_SEC" ]; }
probe(){ local ifc=$1 fl=$2 urls=$3 u c   # любой HTTP-ответ кроме 000 = данные ходят
  for u in $urls; do
    c="$(curl "-$fl" --noproxy '*' --interface "$ifc" --connect-timeout 3 --max-time 6 -s -o /dev/null -w '%{http_code}' "$u" 2>/dev/null || true)"
    [ -n "$c" ] && [ "$c" != 000 ] && return 0
  done; return 1; }

set_route(){ local fl=$1 ifc=$2 live=$3 dead=$4 state=$5 gw_var gw via=()
  gw_var="EGRESS_GW_${ifc//[^A-Za-z0-9]/_}"; gw="${!gw_var:-}"; [ -n "$gw" ] && via=(via "$gw")
  # metric входит в ключ маршрута: replace с другой метрикой ДОБАВИТ второй маршрут — старый удаляем явно
  if [ "$state" = up ]; then
    run_try ip "$fl" route del default dev "$ifc" table "$TABLE" metric "$dead" 2>/dev/null || true
    run_try ip "$fl" route replace default "${via[@]}" dev "$ifc" table "$TABLE" metric "$live"
  else
    run_try ip "$fl" route del default dev "$ifc" table "$TABLE" metric "$live" 2>/dev/null || true
    run_try ip "$fl" route replace default "${via[@]}" dev "$ifc" table "$TABLE" metric "$dead"
  fi; }

tick(){ local ifc i=0 live up4 up6 liveN=0 s
  ensure_rules   # networkctl reconfigure мог стереть базовые ip rule — вернуть до проб
  for ifc in $EGRESS_IFACES; do
    i=$((i+1)); live=$((i*100))
    up4=down; if alive_wg "$ifc" && probe "$ifc" 4 "$URLS4"; then up4=up; fi
    set_route -4 "$ifc" "$live" "$DEAD_METRIC" "$up4"
    if [ "$HAS_IPV6" = 1 ]; then
      up6=down; if [ "$up4" = up ] && probe "$ifc" 6 "$URLS6"; then up6=up; fi
      set_route -6 "$ifc" "$live" "$DEAD_METRIC" "$up6"
    else up6=n/a; fi
    s="v4=$up4 v6=$up6"
    [ "$up4" = up ] && liveN=$((liveN+1))
    if [ "${PREV[$ifc]:-}" != "$s" ]; then echo "[$(date +%T)] $ifc: $s"; PREV[$ifc]="$s"; fi
  done
  if [ "$liveN" = 0 ]; then
    echo "[WARN] все egress мёртвы: клиенты в blackhole (direct не используется)"
    if [ "$APPLY" = 1 ]; then ip -4 route show table "$TABLE" | grep -q 'blackhole default' || no "blackhole missing in table $TABLE!"; fi
  fi; }

if [ "$ONCE" = 1 ]; then tick; summary; exit $?; fi
while :; do tick || true; sleep "$INTERVAL"; done
