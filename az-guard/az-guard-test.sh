#!/usr/bin/env bash
# Поведенческий тест guard БЕЗ влияния на живых клиентов: «теневой» guard с отдельными chain/mark/table/prio
# и ОДНИМ тестовым клиентом в netns (подсеть 10.255.77.0/30). Боевые правила и туннели не трогаются.
#   1) клиент выходит через egress, egress IP != ingress IP
#   2) egress "умер" (в теневой таблице нет egress-маршрутов) -> связи нет (blackhole, не direct)
#   3) fwmark-правило убрано (имитация потери маркировки) -> трафик идёт в main -> FORWARD-guard ДОЛЖЕН дропнуть
#   4) всё вернули -> связь снова есть
# --dry-run (по умолчанию) только печатает план. --apply: авто-откат 300с + trap-очистка.
DIR="$(dirname "$(readlink -f "$0")")"
export AZ_CHAIN=AZ_EGRESS_GUARD_T AZ_MCHAIN=AZ_EGRESS_MARK_T AZ_NCHAIN=AZ_EGRESS_NAT_T AZ_MARK=0x1f4f AZ_TABLE=102 AZ_PRIO=1002
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
usage(){ echo "usage: $0 [--conf F] [--dry-run|--apply]"; exit 2; }
while [ $# -gt 0 ]; do case "$1" in --conf) CONF="$2"; shift 2;; --dry-run) shift;; --apply) APPLY=1; shift;; *) usage;; esac; done
load_conf
NS=azt; HV=azt0; NV=azt1; NET=10.255.77.0/30; HIP=10.255.77.1; NIP=10.255.77.2
EG="${TEST_EGRESS:-${EGRESS_IFACES%% *}}"      # живой egress, через который гоняем тест
URL="https://1.1.1.1/cdn-cgi/trace"
EXTRA_RESTORE="ip netns del $NS 2>/dev/null; ip link del $HV 2>/dev/null; iptables -w -t nat -D POSTROUTING -s $NET -o $EG -j MASQUERADE 2>/dev/null"
export EXTRA_RESTORE

cleanup(){ [ "$APPLY" = 1 ] || return 0; set +e
  ip netns del "$NS" 2>/dev/null; ip link del "$HV" 2>/dev/null
  iptables -w -t nat -D POSTROUTING -s "$NET" -o "$EG" -j MASQUERADE 2>/dev/null
  [ -x "$BK/restore.sh" ] && "$BK/restore.sh"; disarm_all >/dev/null; }
trap cleanup EXIT

if [ "$APPLY" != 1 ]; then
  echo "+ netns $NS + veth $HV/$NV ($NET), egress=$EG"
  echo "+ shadow guard: LAYERS=TEST:$HV:$NET: chain=$CHAIN mark=$MARK table=$TABLE prio=$PRIO"
  echo "+ phases: egress ok -> egress dead (expect no connectivity) -> mark lost (expect FORWARD DROP) -> restore"
  echo "[PASS] dry-run (ничего не изменено)"; exit 0
fi

[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || { echo "[FAIL] ip_forward=0"; exit 2; }
ip link show dev "$EG" >/dev/null 2>&1 || { echo "[FAIL] egress iface $EG отсутствует"; exit 2; }
ip -4 route show table all | grep -q "$NET" && { echo "[FAIL] $NET уже используется"; exit 2; }
arm_rollback

ip netns add "$NS"; ip link add "$HV" type veth peer name "$NV"; ip link set "$NV" netns "$NS"
ip addr add "$HIP/30" dev "$HV"; ip link set "$HV" up
ip netns exec "$NS" ip addr add "$NIP/30" dev "$NV"; ip netns exec "$NS" ip link set "$NV" up
ip netns exec "$NS" ip link set lo up;               ip netns exec "$NS" ip route add default via "$HIP"
iptables -w -t nat -A POSTROUTING -s "$NET" -o "$EG" -j MASQUERADE   # NAT только на egress, НЕ на WAN

# теневой guard: тем же скриптом, только с тестовыми именами и единственным слоем; HAS_IPV6=0 => v6 не трогаем
# (отдельный conf: load_conf в apply иначе перезатёр бы тестовые значения боевыми)
TCONF="$(mktemp)"; printf 'LAYERS="TEST:%s:%s:"\nEGRESS_IFACES="%s"\nHAS_IPV6=0\nINGRESS_IPS="%s"\n' "$HV" "$NET" "$EG" "${INGRESS_IPS:-}" > "$TCONF"
"$DIR/az-egress-guard-apply.sh" --conf "$TCONF" --boot >/dev/null; rm -f "$TCONF"

fetch(){ ip netns exec "$NS" curl -4 -s --max-time 8 "$URL" 2>/dev/null | awk -F= '/^ip=/{print $2}'; }
sleep 1
echo "== фаза 1: egress жив =="
eip="$(fetch)"
if [ -n "$eip" ]; then ok "клиент вышел через $EG (ip=$eip)"; else no "нет связи через $EG при живом egress — дальнейшие фазы не имеют смысла"; summary; exit 1; fi
case " ${INGRESS_IPS:-} " in *" $eip "*) no "egress IP == ingress IP";; *) ok "egress IP != ingress IP";; esac

echo "== фаза 2: egress умер (теневая таблица без egress, остаётся blackhole) =="
ip -4 route del default dev "$EG" table "$TABLE"
[ -z "$(fetch)" ] && ok "связи нет: blackhole, direct не использован" || no "УТЕЧКА: клиент ходит при мёртвом egress"
ip -4 route replace default dev "$EG" table "$TABLE" metric 100

echo "== фаза 3: потеряна маркировка (fwmark rule удалён) -> main table -> FORWARD-guard =="
before="$(iptables -w -t filter -L "$CHAIN" -nvx | awk '/DROP/{print $1; exit}')"
ip -4 rule del priority "$PRIO"
[ -z "$(fetch)" ] && ok "связи нет: FORWARD-guard блокирует прямой выход" || no "УТЕЧКА: без маркировки клиент вышел в WAN"
after="$(iptables -w -t filter -L "$CHAIN" -nvx | awk '/DROP/{print $1; exit}')"
[ "${after:-0}" -gt "${before:-0}" ] && ok "счётчик DROP вырос ($before -> $after)" || no "счётчик DROP не вырос — пакеты дропались не guard-ом"
ip -4 rule add fwmark "$MARK/$MASK" lookup "$TABLE" priority "$PRIO"

echo "== фаза 4: восстановлено =="
[ -n "$(fetch)" ] && ok "связь восстановлена" || no "связь не восстановилась"
summary
