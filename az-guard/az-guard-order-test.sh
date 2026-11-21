#!/usr/bin/env bash
# Регрессия: завершающий REJECT/DROP должен стоять после RETURN, даже если он появился раньше (IPv6 egress поднялся позже).
# Работает в одноразовом netns (unshare -n): боевые правила не затрагиваются. Нужен root и ip6tables.
DIR="$(dirname "$(readlink -f "$0")")"
[ "${AZ_ORDER_INNER:-}" = 1 ] || exec unshare -n env AZ_ORDER_INNER=1 bash "$0" "$@"
. "$DIR/az-common.sh"; APPLY=1
b=ip6tables; C=T_CHAIN; R="-j REJECT --reject-with icmp6-adm-prohibited"
$b -w -N $C
ipt_rule $b filter $C -i eth9 $R                      # как при первом apply без IPv6: остался только REJECT
ipt_rule $b filter $C -i eth9 -o proton -j RETURN     # потом IPv6 поднялся: RETURN дописан НИЖЕ (старый дефект)
ipt_last $b filter $C -i eth9 $R                      # правка: REJECT уходит в конец
ipt_last $b filter $C -i eth9 $R                      # идемпотентность
rules=$($b -w -S $C | tail -n +2)
[ "$(echo "$rules" | grep -c REJECT)" = 1 ] || { echo "[FAIL] REJECT не один:"; echo "$rules"; exit 1; }
echo "$rules" | sed -n '$p' | grep -q REJECT && echo "$rules" | head -1 | grep -q RETURN || { echo "[FAIL] порядок:"; echo "$rules"; exit 1; }
# чистая цепочка: единственный вызов обязан оставить правило (раньше -A затем -D стирало его)
$b -w -N T_CLEAN
ipt_last $b filter T_CLEAN -i eth8 $R
[ "$($b -w -S T_CLEAN | tail -n +2 | grep -c REJECT)" = 1 ] || { echo "[FAIL] на чистой цепочке REJECT пропал"; exit 1; }
echo "[PASS] RETURN стоит перед REJECT, REJECT один"
