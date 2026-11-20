#!/bin/bash
# Безопасное обновление контейнеров arr-стека (CT107, /opt/arr-stack) с бэкапом и автооткатом.
# Использование:  arr-safe-update.sh [--check] [сервис ...]     по умолчанию: sonarr radarr prowlarr
#   --check  только скачать образ и показать, есть ли обновление; контейнеры не трогает.
# Порядок на сервис: тег отката старого образа -> pull -> стоп -> tar конфига -> up -d ->
# ждём HTTP 200 /ping до 60 с -> нет 200: возвращаем старый образ и старый конфиг, код выхода 1.
set -u
STACK=/opt/arr-stack; BK=$STACK/backups; LOG=/var/log/arr-safe-update.log
WAIT=60; KEEP=3; MINFREE_KB=2000000; TS=$(date +%Y%m%d-%H%M%S)
declare -A PORT=([sonarr]=8989 [radarr]=7878 [prowlarr]=9696)
CHECK=0; [ "${1:-}" = "--check" ] && { CHECK=1; shift; }
SVCS=("$@"); [ ${#SVCS[@]} -eq 0 ] && SVCS=(sonarr radarr prowlarr)
DC="docker compose -f $STACK/docker-compose.yml"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
exec 9>/var/lock/arr-safe-update.lock; flock -n 9 || { echo "уже запущен"; exit 2; }
# /ping без ключа API, изнутри контейнера (prowlarr порт наружу не публикует)
code() { docker exec "$1" curl -s -m5 -o /dev/null -w '%{http_code}' "http://localhost:${PORT[$1]}/ping" 2>/dev/null; }
wait200() { local i; for ((i = 0; i < WAIT; i += 3)); do [ "$(code "$1")" = 200 ] && return 0; sleep 3; done; return 1; }
free_kb() { df --output=avail -k "$STACK" | tail -1 | tr -d ' '; }

# lscr.io из дома рвётся на blob: тянем с ghcr и тегируем как compose-ссылку (см. память 22.10)
pull() {
  local svc=$1 ref=$2
  docker pull -q "$ref" >/dev/null 2>&1 && return 0
  case $ref in lscr.io/linuxserver/*)
    docker pull -q "ghcr.io/linuxserver/${ref#lscr.io/linuxserver/}" >/dev/null 2>&1 \
      && docker tag "ghcr.io/linuxserver/${ref#lscr.io/linuxserver/}" "$ref" && return 0;; esac
  return 1
}

rollback() {
  local svc=$1 ref=$2 bk=$3
  log "$svc: ОТКАТ — возвращаю старый образ и конфиг"
  $DC rm -sf "$svc" >/dev/null 2>&1
  docker tag "local/rollback-$svc:$TS" "$ref"
  mv "$STACK/config/$svc" "$STACK/config/$svc.failed-$TS"
  tar -xzf "$bk" -C "$STACK/config"
  [ -d "$STACK/config/$svc.failed-$TS/MediaCover" ] && mv "$STACK/config/$svc.failed-$TS/MediaCover" "$STACK/config/$svc/"
  $DC up -d --no-deps "$svc" >/dev/null 2>&1
  if wait200 "$svc"; then log "$svc: после отката /ping 200, неудачный конфиг сохранён в config/$svc.failed-$TS"
  else log "$svc: !!! после отката /ping не 200 — нужен ручной разбор (бэкап $bk)"; fi
}

rc=0
[ "$(free_kb)" -lt $MINFREE_KB ] && { log "мало места ($(free_kb) КБ) — выход"; exit 3; }
mkdir -p "$BK"
for svc in "${SVCS[@]}"; do
  [ -n "${PORT[$svc]:-}" ] || { log "$svc: нет в списке (sonarr radarr prowlarr)"; rc=1; continue; }
  ref=$(docker inspect -f '{{.Config.Image}}' "$svc") || { log "$svc: контейнера нет"; rc=1; continue; }
  old=$(docker inspect -f '{{.Image}}' "$svc")
  [ "$(code "$svc")" = 200 ] || { log "$svc: до обновления /ping не 200 — пропуск, чинить руками"; rc=1; continue; }
  docker tag "$old" "local/rollback-$svc:$TS"
  pull "$svc" "$ref" || { log "$svc: образ не скачался (lscr и ghcr) — без изменений"; rc=1; continue; }
  new=$(docker image inspect -f '{{.Id}}' "$ref")
  if [ "$new" = "$old" ]; then log "$svc: уже актуален"; docker rmi "local/rollback-$svc:$TS" >/dev/null 2>&1; continue; fi
  if [ $CHECK = 1 ]; then log "$svc: ЕСТЬ обновление ($(docker image inspect -f '{{.Config.Labels}}' "$ref" | grep -o 'build_version:[^ ]*' | head -1))"; docker rmi "local/rollback-$svc:$TS" >/dev/null 2>&1; continue; fi
  bk="$BK/$svc-$TS.tar.gz"
  docker stop "$svc" >/dev/null                       # холодная копия: SQLite без гонок
  tar -czf "$bk" --exclude="$svc/MediaCover" --exclude="$svc/logs" -C "$STACK/config" "$svc" || { log "$svc: бэкап не создался — старт без обновления"; docker start "$svc" >/dev/null; rc=1; continue; }
  log "$svc: бэкап $bk ($(du -h "$bk" | cut -f1)), обновляю"
  $DC up -d --no-deps "$svc" >/dev/null 2>&1
  if wait200 "$svc"; then log "$svc: OK, /ping 200 на новой версии"
  else rollback "$svc" "$ref" "$bk"; rc=1; fi
  ls -1t "$BK/$svc"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  docker images --format '{{.Repository}}:{{.Tag}}' "local/rollback-$svc" | sort -r | tail -n +$((KEEP + 1)) | xargs -r docker rmi >/dev/null 2>&1
done
docker image prune -f >/dev/null 2>&1
exit $rc
