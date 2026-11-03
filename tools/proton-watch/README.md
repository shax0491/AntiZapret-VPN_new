# proton-watch

Сторож Proton-туннелей на узле AntiZapret: каждые 5 минут проверяет рукопожатие WireGuard и реальный выход
(`curl --interface <iface> .../generate_204`) по каждому интерфейсу `warp-*` и `proton`. Журнал в
`/var/log/proton-watch.log`. Два сбоя подряд - сообщение через `rekey.py` управляющего сервера (поле `alert`
в POST на `REKEY_URL`, авторизация токеном узла `REKEY_TOKEN` из `/etc/proton-pick.conf`).

Установка: `proton-watch` в `/usr/local/sbin/` (chmod 755), `*.service` и `*.timer` в `/etc/systemd/system/`,
затем `systemctl daemon-reload && systemctl enable --now proton-watch.timer`. Токены в репозитории не хранятся.
