#!/bin/bash
# Безопасное обновление Jellyfin (CT106, apt-пакеты jellyfin/-server/-web на hold) с бэкапом и автооткатом.
# Использование:  jellyfin-safe-update.sh [--check]
#   --check  только показать установленную и доступную версию.
# Порядок: apt update -> сравнение версий -> скачать ТЕКУЩИЕ deb (для отката) -> стоп -> tar баз и настроек ->
# снять hold, обновить server/web/jellyfin, вернуть hold -> старт -> ждём HTTP 200 /health до 60 с ->
# нет 200: dpkg -i старых deb, возвращаем базы и настройки, код выхода 1.
# jellyfin-ffmpeg не трогаем. Каталог /var/lib/jellyfin/{metadata,data/трикплей...} (гигабайты) в бэкап не входит.
set -u
BK=/root/jf-backups; LOG=/var/log/jf-safe-update.log; WAIT=60; KEEP=3; MINFREE_KB=3000000
PK="jellyfin-server jellyfin-web jellyfin"; HOLD="jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg8"
TS=$(date +%Y%m%d-%H%M%S); CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
exec 9>/var/lock/jf-safe-update.lock; flock -n 9 || { echo "уже запущен"; exit 2; }
inst() { dpkg-query -W -f='${Version}' jellyfin-server 2>/dev/null; }
cand() { apt-cache policy jellyfin-server | awk '/Candidate:/{print $2}'; }
ok() { local i; for ((i = 0; i < WAIT; i += 3)); do [ "$(curl -s -m4 -o /dev/null -w '%{http_code}' http://127.0.0.1:8096/health)" = 200 ] && return 0; sleep 3; done; return 1; }
# что бэкапим: базы, настройки, конфиги плагинов (без кэшей и метаданных)
files() { { ls /var/lib/jellyfin/data/*.db* 2>/dev/null; echo /etc/jellyfin; echo /var/lib/jellyfin/plugins/configurations; echo /var/lib/jellyfin/root; } | sed 's#^/##'; }

apt-get update -qq >/dev/null 2>&1 || { log "apt update не прошёл — выход"; exit 1; }
OLD=$(inst); NEW=$(cand)
[ "$OLD" = "$NEW" ] && { log "Jellyfin $OLD актуален"; exit 0; }
log "установлен $OLD, доступен $NEW"; [ $CHECK = 1 ] && exit 0
[ "$(df --output=avail -k / | tail -1 | tr -d ' ')" -lt $MINFREE_KB ] && { log "мало места — выход"; exit 3; }
[ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8096/health)" = 200 ] || { log "до обновления /health не 200 — выход"; exit 1; }
mkdir -p "$BK/debs-$TS"; ( cd "$BK/debs-$TS" && for p in $PK; do apt-get download -qq "$p=$OLD" 2>/dev/null; done )
ls "$BK/debs-$TS"/*.deb >/dev/null 2>&1 || { log "старые deb не скачались (версия ушла из репо) — без обновления"; rm -rf "$BK/debs-$TS"; exit 1; }
systemctl stop jellyfin
tar -czf "$BK/jf-$TS.tar.gz" -C / $(files) || { log "бэкап не создался — старт без обновления"; systemctl start jellyfin; exit 1; }
log "бэкап $BK/jf-$TS.tar.gz ($(du -h "$BK/jf-$TS.tar.gz" | cut -f1)), обновляю"
apt-mark unhold $HOLD >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confold $(for p in $PK; do echo "$p=$NEW"; done) >>"$LOG" 2>&1
apt-mark hold $HOLD >/dev/null
systemctl start jellyfin
if ok; then log "OK: Jellyfin $NEW, /health 200"; rc=0
else
  log "ОТКАТ на $OLD"; systemctl stop jellyfin
  apt-mark unhold $HOLD >/dev/null
  dpkg -i --force-downgrade "$BK/debs-$TS"/*.deb >>"$LOG" 2>&1
  apt-mark hold $HOLD >/dev/null
  tar -xzf "$BK/jf-$TS.tar.gz" -C /
  systemctl start jellyfin
  if ok; then log "после отката /health 200 (версия $(inst))"; else log "!!! после отката /health не 200 — нужен ручной разбор (бэкап $BK/jf-$TS.tar.gz)"; fi
  rc=1
fi
ls -1dt "$BK"/jf-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1dt "$BK"/debs-* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf
exit $rc
