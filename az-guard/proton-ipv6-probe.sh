#!/usr/bin/env bash
# READ-ONLY: IPv6-готовность Proton/WARP-профилей. Секреты (PrivateKey/PresharedKey) не читаются и не печатаются.
# Живые интерфейсы НЕ переподключаются (лимит сессий Proton: один ключ = одно активное подключение).
DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=az-common.sh
. "$DIR/az-common.sh"
PROFILE_DIR="${PROTON_PROFILE_DIR:-/etc/wireguard}"
PICK="${PROTON_PICK:-/root/antizapret/proton-pick.py}"
while [ $# -gt 0 ]; do case "$1" in --conf) CONF="$2"; shift 2;; --profile-dir) PROFILE_DIR="$2"; shift 2;; *) echo "usage: $0 [--conf F] [--profile-dir D]"; exit 2;; esac; done
[ -r "$CONF" ] && . "$CONF" || true
: "${HAS_IPV6:=1}"

val(){ sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*)$/\1/Ip" "$1" | tr ',' '\n' | tr -d ' \r'; }
shopt -s nullglob; found=0
for f in "$PROFILE_DIR"/*proton*.conf "$PROFILE_DIR"/warp-*.conf; do
  found=1; base="$(basename "$f" .conf)"
  addr6="$(val "$f" Address | grep ':' || true)"; allow6="$(val "$f" AllowedIPs | grep -E '^::/0$' || true)"; dns6="$(val "$f" DNS | grep ':' || true)"
  if [ -n "$addr6" ] && [ -n "$allow6" ]; then
    [ "$HAS_IPV6" = 1 ] && ok "$base: v6 в туннеле (Address6+::/0)" || no "$base: профиль v6, но на ноде HAS_IPV6=0"
  else
    no "$base: v6 НЕТ (Address6='${addr6:-}' AllowedIPs ::/0='${allow6:-нет}') -> v6 клиентов должен REJECT-ить guard"
  fi
  [ -n "$dns6" ] && echo "[INFO] $base dns6=$dns6" || echo "[INFO] $base: нет v6 DNS"
  if wg show "$base" >/dev/null 2>&1; then
    hs="$(wg show "$base" latest-handshakes | awk '{print $2}' | sort -n | tail -n1)"
    [ -n "$hs" ] && [ "$hs" != 0 ] && ok "$base: handshake $(( $(date +%s) - hs )) c назад (без переподключения)" || no "$base: нет handshake"
  fi
done
[ "$found" = 1 ] || no "профили Proton/WARP не найдены в $PROFILE_DIR"

if [ -x "$PICK" ] || [ -r "$PICK" ]; then
  echo "== proton-pick --status (read-only; AUTO_SWITCH не включаем) =="
  python3 -I "$PICK" --status || warn "proton-pick --status завершился с ошибкой"
else warn "proton-pick.py не найден ($PICK)"; fi
echo "[INFO] Кандидатов на новый сервер/ключ тестировать ТОЛЬКО в отдельном netns с отдельным ключом (REKEY_URL), не на боевом iface."
summary
