#!/usr/bin/env bash
# az-common.sh — общие функции az-* скриптов. Только source, не запускать.
# Реквизиты по умолчанию совпадают с egress_guard.py (chain/mark/table/prio/blackhole metric).
# ВАЖНО: IFS не переопределяем — списки EGRESS_IFACES/LAYERS разделены пробелами.
set -euo pipefail
umask 077

CONF="${CONF:-/etc/az-guard.conf}"
CHAIN="${AZ_CHAIN:-AZ_EGRESS_GUARD}"      # filter/FORWARD (одно имя для v4 и v6, как в egress_guard.py)
MCHAIN="${AZ_MCHAIN:-AZ_EGRESS_MARK}"; NCHAIN="${AZ_NCHAIN:-AZ_EGRESS_NAT}"     # mangle/PREROUTING
MARK="${AZ_MARK:-0x1f40}"; MASK="0xffffffff"
TABLE="${AZ_TABLE:-100}"; PRIO="${AZ_PRIO:-900}"
BH_METRIC=2000     # blackhole всегда ПОСЛЕДНИЙ из живых маршрутов
DEAD_METRIC=5000   # мёртвый egress уезжает ЗА blackhole => трафик уходит в blackhole, не в мёртвый iface
APPLY=0
TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/az-test-backup-$TS"
pass=0; fail=0

ok(){ pass=$((pass+1)); echo "[PASS] $*"; }
no(){ fail=$((fail+1)); echo "[FAIL] $*"; }
warn(){ echo "[WARN] $*"; }
summary(){ echo "SUMMARY pass=$pass fail=$fail"; [ "$fail" -eq 0 ]; }
fam_of(){ case "$1" in *:*) echo 6;; *) echo 4;; esac; }

load_conf(){
  [ -r "$CONF" ] || { echo "[FAIL] config not readable: $CONF"; exit 2; }
  # shellcheck disable=SC1090
  . "$CONF"            # root-only файл (chmod 600): исполняется как shell
  : "${HAS_IPV6:=1}"
  : "${EGRESS_IFACES:?EGRESS_IFACES required}"
}

# dry-run печатает команду, apply исполняет
run(){ if [ "$APPLY" = 1 ]; then "$@"; else printf '+ '; printf '%q ' "$@"; echo; fi; }
# то же, но сбой не фатален (интерфейса может ещё не быть при загрузке)
run_try(){ if [ "$APPLY" = 1 ]; then "$@" || warn "failed (non-fatal): $*"; else printf '+ (try) '; printf '%q ' "$@"; echo; fi; }

# --- idempotent iptables helpers: -C, иначе добавить ---
ipt_chain(){ local b=$1 t=$2 c=$3
  if [ "$APPLY" = 1 ]; then "$b" -w -t "$t" -N "$c" 2>/dev/null || true; else echo "+ $b -w -t $t -N $c (if absent)"; fi; }
ipt_jump(){ local b=$1 t=$2 parent=$3 c=$4   # ТОЛЬКО -I 1: хвостовой jump обходится ACCEPT-правилами AntiZapret
  if [ "$APPLY" = 1 ]; then
    # jump должен быть ПЕРВЫМ правилом: перезапуск antizapret вставляет свои правила выше (проверено на NL2 21:10)
    [ "$("$b" -w -t "$t" -S "$parent" | sed -n 2p)" = "-A $parent -j $c" ] && return 0
    "$b" -w -t "$t" -I "$parent" 1 -j "$c"      # сначала вставка: окна без guard нет
    local pos
    while :; do   # затем удалить дубликаты ниже позиции 1 (по номеру правила)
      pos="$("$b" -w -t "$t" -S "$parent" | awk -v c="-A $parent -j $c" 'NR>2 && $0==c{print NR-1; exit}')"
      [ -n "$pos" ] || break
      "$b" -w -t "$t" -D "$parent" "$pos" || break
    done
  else echo "+ $b -w -t $t -C $parent -j $c || $b -w -t $t -I $parent 1 -j $c"; fi; }
ipt_rule(){ local b=$1 t=$2; shift 2
  if [ "$APPLY" = 1 ]; then "$b" -w -t "$t" -C "$@" 2>/dev/null || "$b" -w -t "$t" -A "$@"
  else echo "+ $b -w -t $t -C/-A $*"; fi; }

# --- бэкап + авто-откат (только для --apply; ТОЧЕЧНЫЙ откат наших объектов, а не iptables-restore всего,
#     чтобы не затереть правила, которые панель меняет параллельно) ---
arm_rollback(){
  [ "$APPLY" = 1 ] || { echo "+ backup -> $BK ; auto-rollback in 300s"; return 0; }
  disarm_all >/dev/null   # старый таймер после второго --apply снёс бы живую конфигурацию (ревью KIMI-7D42F1A3)
  mkdir -p "$BK"
  iptables-save > "$BK/iptables.save"; ip6tables-save > "$BK/ip6tables.save" 2>/dev/null || true
  { ip -4 rule show; ip -6 rule show; ip -4 route show table all; ip -6 route show table all; } > "$BK/ip.txt" 2>/dev/null || true
  cat > "$BK/restore.sh" <<EOF
#!/usr/bin/env bash
# точечный откат: только объекты $CHAIN/$MCHAIN/prio $PRIO/table $TABLE
[ -f "$BK/.armed" ] || exit 0
for nb in iptables ip6tables; do \$nb -w -t nat -D POSTROUTING -j $NCHAIN 2>/dev/null; \$nb -w -t nat -F $NCHAIN 2>/dev/null; \$nb -w -t nat -X $NCHAIN 2>/dev/null; done
for b in iptables ip6tables; do
  \$b -w -D FORWARD -j $CHAIN 2>/dev/null; \$b -w -F $CHAIN 2>/dev/null; \$b -w -X $CHAIN 2>/dev/null
  \$b -w -t mangle -D PREROUTING -j $MCHAIN 2>/dev/null; \$b -w -t mangle -F $MCHAIN 2>/dev/null; \$b -w -t mangle -X $MCHAIN 2>/dev/null
done
for f in -4 -6; do
  while ip \$f rule del priority $PRIO 2>/dev/null; do :; done
  ip \$f route flush table $TABLE 2>/dev/null
done
${EXTRA_RESTORE:-:}
rm -f "$BK/.armed"
EOF
  chmod 700 "$BK/restore.sh"; touch "$BK/.armed"
  systemd-run --on-active=300 --unit="az-rollback-$TS" "$BK/restore.sh" >/dev/null
  echo "[INFO] backup=$BK ; auto-rollback in 300s (disarm: az-egress-guard-apply.sh --commit)"
}
disarm_all(){
  local d
  for d in /root/az-test-backup-*; do
    [ -f "$d/.armed" ] || continue
    systemctl stop "az-rollback-${d##*-backup-}.timer" 2>/dev/null || true
    rm -f "$d/.armed"; echo "[INFO] disarmed $d"
  done
}

# Идемпотентно возвращает базовые policy-правила (их стирает `networkctl reconfigure`/`netplan apply`, если networkd
# управляет «чужими» правилами). BASE_RULES: строки "-4|oif proton lookup 51820 priority 1000" (семейство|аргументы ip rule add).
# `ip rule add` на дубликат возвращает EEXIST — это и есть идемпотентность. Правило самого guard добавляется всегда.
ensure_rules(){
  [ "$APPLY" = 1 ] || return 0
  local r fam args f err
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    fam="${r%%|*}"; args="${r#*|}"
    # shellcheck disable=SC2086
    err="$(ip "$fam" rule add $args 2>&1)" || case "$err" in *"File exists"*) ;; *) echo "az-guard: rule add failed: $args: $err" >&2;; esac
  done <<< "${BASE_RULES:-}"
  for f in -4 -6; do
    [ "$f" = -6 ] && [ "${HAS_IPV6:-1}" != 1 ] && continue
    ip "$f" rule add fwmark "$MARK/$MASK" lookup "$TABLE" priority "$PRIO" 2>/dev/null || true
  done
  # jump'ы тоже переустанавливаются на позицию 1 (если цепочки существуют)
  local b
  for b in iptables ip6tables; do
    [ "$b" = ip6tables ] && [ "${HAS_IPV6:-1}" != 1 ] && continue
    "$b" -w -S "$CHAIN" >/dev/null 2>&1 && ipt_jump "$b" filter FORWARD "$CHAIN" || true
    "$b" -w -t mangle -S "$MCHAIN" >/dev/null 2>&1 && ipt_jump "$b" mangle PREROUTING "$MCHAIN" || true
  done
  for b in iptables ip6tables; do
    [ "$b" = ip6tables ] && [ "${HAS_IPV6:-1}" != 1 ] && continue
    "$b" -w -t nat -S "$NCHAIN" >/dev/null 2>&1 && { ipt_jump "$b" nat POSTROUTING "$NCHAIN" || true; }
  done
  return 0
  return 0
}
