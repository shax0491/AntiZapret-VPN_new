# mihomo — сборка клиентских конфигов (сервер-сборщик, `/opt/mh-app`)

Конфиги для роутеров собираются **одним шаблоном** `/opt/mh-app/templates/home.yaml` + реестр серверов `nodes.json`
скриптом `/opt/mh-app/build_configs.py`. Результат (`home-config.yaml`, `work-config.yaml`) публикуется в
`/var/www/az-lists/` **только если `mihomo -t` прошёл**; роутеры забирают его сами раз в 30 минут (`:00`/`:30`).
Правила и карточки правьте в шаблоне, не на роутере. Шаблон содержит секреты (секрет контроллера, ссылка подписки) — в git не кладётся.

## Флаг IPv6

`mh-ipv6.sh on|off|status` пишет `/opt/mh-app/ipv6.flag` (`1`/`0`; нет файла = выключено) и пересобирает конфиги.
При сборке строки `ipv6: true|false` шаблона (верхний уровень и `dns:`) перезаписываются значением флага.

**`on` включайте только если** провайдер выдаёт префикс (DHCPv6-PD) **и** роутер раздаёт IPv6 в LAN через Mihomo.
Иначе IPv6-трафик устройств пойдёт мимо Mihomo (утечка мимо VPN). Если сомневаетесь — оставьте `off` (только IPv4).

## IP-чекеры и DNS

Сайты проверки IP/DNS (`ifconfig.me`, `ifconfig.co`, `checkip.amazonaws.com`, `ident.me`, `icanhazip.com`, `ipify.org`,
`ipinfo.io`, `ip-api.com`, `whoer.net`, `dnsleaktest.com` и др.) направлены в «Авто — самый быстрый», а их DNS —
`1.1.1.1` через тот же выход. Иначе они попадали в «Остальной интернет» (по умолчанию «Напрямую») и показывали домашний IP.
Список и вставка в шаблон — `apply-ipcheck-patch.py` (идемпотентен, делает бэкап шаблона и `build_configs.py`, патчит сборщик флагом IPv6).
Запуск на сборщике: `python3 apply-ipcheck-patch.py && python3 /opt/mh-app/build_configs.py`.

## Откат

Бэкапы лежат рядом: `templates/home.yaml.bak-ipchk-<TS>`, `build_configs.py.bak-ipchk-<TS>` — вернуть файлы и запустить `build_configs.py`.
