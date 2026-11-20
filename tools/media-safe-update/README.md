# Безопасное обновление медиа-стека (Proxmox: CT107 arr-stack, CT106 Jellyfin)

Скрипты делают бэкап, обновляют и сами откатываются, если сервис не ответил HTTP 200 за 60 с.

| Скрипт | Где лежит | Что обновляет |
|---|---|---|
| `arr-safe-update.sh` | CT107 `/opt/arr-stack/scripts/` | контейнеры sonarr, radarr, prowlarr (docker compose) |
| `jellyfin-safe-update.sh` | CT106 `/root/` | пакеты jellyfin, jellyfin-server, jellyfin-web (apt, hold) |

`--check` — только показать, есть ли обновление, ничего не менять. Запуск из контейнера: `pct exec 107 -- /opt/arr-stack/scripts/arr-safe-update.sh [--check] [сервис…]`, `pct exec 106 -- /root/jellyfin-safe-update.sh [--check]`.

**arr:** старый образ тегируется `local/rollback-<сервис>:<время>`; pull (lscr.io, при обрыве на blob — ghcr.io/linuxserver); холодный tar конфига без MediaCover/logs в `/opt/arr-stack/backups/<сервис>-<время>.tar.gz`; `compose up -d --no-deps`; не 200 — старый образ и конфиг возвращаются, неудачный конфиг остаётся в `config/<сервис>.failed-<время>`. Хранится 3 последних бэкапа.
**Jellyfin:** перед обновлением скачиваются текущие deb (`/root/jf-backups/debs-*`), tar баз/настроек/плагин-конфигов (`jf-*.tar.gz`, без metadata и кэшей); hold снимается и возвращается; откат = `dpkg -i --force-downgrade` + возврат баз. ffmpeg не трогается. Сразу после старта `/health` бывает `Degraded` («Server is still starting up») — скрипт ждёт 200, итоговый `Healthy` приходит через несколько секунд.

Ловушки: данные на диске 8 ТБ скрипты не трогают; перед ручным запуском в рабочее время помнить, что Jellyfin перезапускается (потоки обрываются на ~30 с); прыжковый хост 77.37.174.115 троттлит — все команды одним батчем.
