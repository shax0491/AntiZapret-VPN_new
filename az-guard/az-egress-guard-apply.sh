#!/usr/bin/env bash
# Применяет egress-guard (то же, что plan_egress_guard()): mangle-mark -> table 100 -> egress / blackhole,
# FORWARD: клиентский iface может выйти ТОЛЬКО в egress, всё остальное DROP/REJECT.
# Режимы: --dry-run (по умолчанию) | --apply (+ авто-откат 300с) | --commit (снять откат, поставить unit) | --boot (для unit)
# Для изолированного теста: AZ_CHAIN/AZ_MCHAIN/AZ_MARK/AZ_TABLE/AZ_PRIO и LAYERS из окружения (см. az-guard-test.sh).
DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
MODE=dry
usage(){ echo "usage: $0 [--conf F] [--dry-run|--apply|--commit|--boot]"; exit 2; }
while [ $# -gt 0 ]; do case "$1" in
  --conf) CONF="$2"; shift 2;; --dry-run) shift;;
  --apply) APPLY=1; MODE=apply; shift;; --commit) APPLY=1; MODE=commit; shift;; --boot) APPLY=1; MODE=boot; shift;;
  *) usage;; esac; done

if [ "$MODE" = commit ]; then
  disarm_all
  # unit ставится ТОЛЬКО после commit: до этого откат автоматический
  cat > /etc/systemd/system/az-egress-guard.service <<EOF
[Unit]
Description=AZ egress guard (policy routing + blackhole, до туннелей)
DefaultDependencies=no
Before=wg-quick@.service awg-quick@.service openvpn-server@.service network-online.target
After=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DIR/az-egress-guard-apply.sh --conf $CONF --boot
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/az-egress-monitor.service <<EOF
[Unit]
Description=AZ egress health monitor
After=az-egress-guard.service
Requires=az-egress-guard.service
[Service]
ExecStart=$DIR/az-egress-monitor.sh --conf $CONF --apply
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable az-egress-guard.service az-egress-monitor.service
  echo "[PASS] committed: units enabled (start monitor: systemctl start az-egress-monitor)"; exit 0
fi

load_conf
: "${LAYERS:?LAYERS required: name:iface:v4_cidr[,..]:v6_cidr[,..] (через пробел)}"
for L in $LAYERS; do IFS=':' read -r _n _i _ <<<"$L"; [ -n "$_n" ] && [ -n "$_i" ] || { echo "[FAIL] bad LAYERS entry '$L' (нужно name:iface:v4:v6 без пробелов внутри)"; exit 2; }; done
case "$MODE" in apply|dry) arm_rollback;; esac   # boot: без бэкапа и без таймера

apply_family(){
  local bin=$1 f=$2 v6=0 L name iface v4s v6s subs s a e
  [ "$f" = 6 ] && v6=1
  ipt_chain "$bin" mangle "$MCHAIN"; ipt_jump "$bin" mangle PREROUTING "$MCHAIN"
  ipt_chain "$bin" filter "$CHAIN";  ipt_jump "$bin" filter FORWARD "$CHAIN"

  if [ "$v6" = 0 ] || [ "$HAS_IPV6" = 1 ]; then
    # исключения из маркировки: адреса ноды и клиент<->клиент
    for a in ${INGRESS_IPS:-}; do [ "$(fam_of "$a")" = "$f" ] && ipt_rule "$bin" mangle "$MCHAIN" -d "$a" -j RETURN || true; done
    for L in $LAYERS; do
      IFS=':' read -r name iface v4s v6s <<<"$L"
      if [ "$v6" = 1 ]; then subs="${v6s//,/ }"; else subs="${v4s//,/ }"; fi
      for s in $subs; do ipt_rule "$bin" mangle "$MCHAIN" -d "$s" -j RETURN; done
    done
    for L in $LAYERS; do
      IFS=':' read -r name iface v4s v6s <<<"$L"
      ipt_rule "$bin" mangle "$MCHAIN" -i "$iface" -j MARK --set-xmark "$MARK/$MASK"
    done
  fi

  if [ "$v6" = 0 ]; then
    # без SNAT пакет клиента уходит в Proton/WARP с приватным src и молча теряется (найдено сквозным тестом на NL2)
    ipt_chain "$bin" nat "$NCHAIN"; ipt_jump "$bin" nat POSTROUTING "$NCHAIN"
    for L in $LAYERS; do
      IFS=':' read -r name iface v4s v6s <<<"$L"
      for s in ${v4s//,/ }; do for e in $EGRESS_IFACES; do ipt_rule "$bin" nat "$NCHAIN" -s "$s" -o "$e" -j MASQUERADE; done; done
    done
  fi

  for L in $LAYERS; do
    IFS=':' read -r name iface v4s v6s <<<"$L"
    if [ "$v6" = 1 ]; then
      if [ "$HAS_IPV6" = 1 ]; then for e in $EGRESS_IFACES; do ipt_rule "$bin" filter "$CHAIN" -i "$iface" -o "$e" -j RETURN; done; fi
      ipt_rule "$bin" filter "$CHAIN" -i "$iface" -j REJECT --reject-with icmp6-adm-prohibited   # по iface, не по подсети
    else
      for e in $EGRESS_IFACES; do ipt_rule "$bin" filter "$CHAIN" -i "$iface" -o "$e" -j RETURN; done
      ipt_rule "$bin" filter "$CHAIN" -i "$iface" -j DROP
    fi
  done
}

apply_routes(){
  local fl=$1 m=100 e gw_var gw
  # blackhole ПЕРВЫМ: при загрузке egress-интерфейсов ещё нет, но утечки быть не должно
  run ip "$fl" route replace blackhole default table "$TABLE" metric "$BH_METRIC"
  if [ "$APPLY" = 1 ]; then ip "$fl" rule show | grep -Eq "^$PRIO:.*fwmark $MARK(/$MASK)? .*lookup $TABLE" || ip "$fl" rule add fwmark "$MARK/$MASK" lookup "$TABLE" priority "$PRIO"
  else echo "+ ip $fl rule add fwmark $MARK/$MASK lookup $TABLE priority $PRIO (if absent)"; fi
  for e in $EGRESS_IFACES; do
    gw_var="EGRESS_GW_${e//[^A-Za-z0-9]/_}"; gw="${!gw_var:-}"
    if [ -n "$gw" ]; then run_try ip "$fl" route replace default via "$gw" dev "$e" table "$TABLE" metric "$m"
    else run_try ip "$fl" route replace default dev "$e" table "$TABLE" metric "$m"; fi
    m=$((m+100))   # монитор использует ту же схему: 100,200,...
  done
}

apply_family iptables 4
apply_family ip6tables 6
apply_routes -4
[ "$HAS_IPV6" = 1 ] && apply_routes -6 || true

case "$MODE" in
  apply) echo "[PASS] applied; ROLLBACK ARMED (300s). Проверь az-audit.sh, затем: $0 --commit"; ;;
  boot)  ensure_rules; echo "[PASS] boot apply done";;
  *)     echo "[PASS] dry-run complete (ничего не изменено)";;
esac
