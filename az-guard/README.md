# az-guard: egress-guard, реверс-туннель и IPv6 для узлов AntiZapret

Принцип: **Ingress != Egress**. Трафик клиентов слоёв (AWG 1.5/2/3, WireGuard, OpenVPN) никогда не выходит напрямую с входного IP ноды: только в `EGRESS_IFACES` (Proton/WARP), иначе blackhole/DROP. Проверено на NL2 10.11.2026.

## Что где лежит
| Файл | Назначение |
|---|---|
| `az-common.sh` | общие функции: идемпотентные iptables-хелперы, бэкап + авто-откат (`systemd-run --on-active=300`), `ensure_rules` |
| `az-egress-guard-apply.sh` | `--dry-run` (по умолчанию) / `--apply` (откат через 300 с) / `--commit` (снять откат, поставить юниты) / `--boot` |
| `az-egress-monitor.sh` | каждые 30 с: handshake И HTTPS через egress; мёртвый egress уезжает за blackhole; возвращает базовые `ip rule` и jump'ы |
| `az-audit.sh` | read-only аудит узла (IPv6/NDP, слои, guard, NAT, egress != ingress, изоляция панели) |
| `az-guard-test.sh` | «теневой» guard (отдельные цепочки/mark/таблица/prio) + netns-клиент, 4 фазы, боевых клиентов не трогает |
| `az-reverse-test.sh` | реверс-туннель переживает бан входящих NEW от relay |
| `proton-ipv6-probe.sh` | read-only: v6-готовность Proton/WARP-профилей |
| `az-guard.conf.example` | пример `/etc/az-guard.conf` |
| `90-az-foreign-rules.networkd.conf` | drop-in networkd: не трогать чужие `ip rule` |
| `azr1.conf.example` | `wg-quick`-конфиг исходящего реверс-туннеля |

## Как устроен guard
1. `mangle/PREROUTING` цепочка `AZ_EGRESS_MARK`: пакеты с клиентских интерфейсов слоёв получают mark `0x1f40` (исключения: входной IP ноды и клиент<->клиент).
2. `ip rule fwmark 0x1f40 lookup 100`, **приоритет 900** (НЕ 1000: на 1000 живёт `oif proton lookup 51820` из PostUp wg-quick; guard при откате удаляет все правила своего приоритета). Таблица 100: egress-маршруты `metric 100*i`, `blackhole default metric 2000`; мёртвый egress монитор переносит на metric 5000 (за blackhole).
3. `filter/FORWARD` цепочка `AZ_EGRESS_GUARD` (jump только позицией 1): клиентский iface -> только `-o egress` (RETURN), иначе DROP (v4) / REJECT icmp6-adm-prohibited (v6).
4. `nat/POSTROUTING` цепочка `AZ_EGRESS_NAT` (jump позицией 1): `-s <подсеть слоя> -o <egress> -j MASQUERADE`. **Без неё пакеты клиентов уходят в Proton с приватным src и молча теряются** (нашёл сквозной тест, синтетика не ловила).
5. Монитор и `--boot` каждые 30 с переставляют jump'ы на позицию 1 (перезапуск `antizapret` вставляет свои правила выше) и возвращают `BASE_RULES` (`networkctl reconfigure` их стирает, если не стоит drop-in).

## Деплой (на ноде, под root)
```bash
install -d /root/az-guard && cp az-guard/*.sh /root/az-guard/ && chmod 700 /root/az-guard/*.sh
install -m 600 az-guard/az-guard.conf.example /etc/az-guard.conf   # править LAYERS/EGRESS_IFACES/BASE_RULES под ноду
install -D -m 644 az-guard/90-az-foreign-rules.networkd.conf /etc/systemd/networkd.conf.d/90-az-foreign-rules.conf
systemctl restart systemd-networkd                                  # чужие ip rule после этого сохраняются
cd /root/az-guard
./az-audit.sh --conf /etc/az-guard.conf                             # read-only
./az-egress-guard-apply.sh --conf /etc/az-guard.conf --dry-run
./az-guard-test.sh --conf /etc/az-guard.conf --apply                # теневой тест (можно на боевой ноде)
./az-egress-guard-apply.sh --conf /etc/az-guard.conf --apply        # откат сам через 300 с
./az-audit.sh --conf /etc/az-guard.conf && ./az-egress-guard-apply.sh --conf /etc/az-guard.conf --commit
```
`--commit` снимает таймер отката и включает `az-egress-guard.service` (до сети/туннелей, `--boot`) и `az-egress-monitor.service`.

## Откат
* До `--commit`: ничего не делать, через 300 с сработает `restore.sh` (точечно удаляет только наши цепочки/правила/таблицу).
* После: `systemctl disable --now az-egress-monitor az-egress-guard`, затем `/root/az-test-backup-<TS>/restore.sh` (нужен файл `.armed`: `touch` его) либо вручную: `-D` jump'ы AZ_*, `ip rule del priority 900`, `ip route flush table 100`. Бэкапы правил: `iptables-save` перед применением.
* Скрипты: предыдущая версия в `/root/az-guard.bak-<дата>/`.

## Реверс-туннель NL2 -> дом (`azr1` <-> `Wireguard30`)
Нода сама звонит на белый IP/IPv6 роутера, поэтому переживает бан входящих из РФ (conntrack ESTABLISHED + `PersistentKeepalive 25`).
* Роутер (NDM): `interface Wireguard30` (`10.77.0.1/24`, `wireguard listen-port 41992`, `security-level private`), peer = публичный ключ ноды, `allow-ips 10.77.0.2/32`, `keepalive-interval 25`; `system configuration save`.
* Нода: `azr1.conf.example` -> `/etc/wireguard/azr1.conf`, `systemctl enable --now wg-quick@azr1`.
* Проверено: handshake и ping 46 мс по v4; по IPv6 (`[WAN-IPv6 роутера]:41992`) свежий handshake, ping 200 мс; `az-reverse-test.sh` 7/7. Адрес WAN-IPv6 роутера динамический.

## IPv6
* Нода: v6 включается снятием `disable_ipv6=1` из `/etc/sysctl.d/99-disable-ipv6.conf` (бэкап) и адресом/шлюзом из netplan. **Не вызывать `netplan apply`/`networkctl reconfigure` без drop-in из этого каталога.**
* Роутер: `interface <WAN> ipv6 address auto` даёт только /128 самому роутеру (нужен для реверса по v6). `ipv6 prefix auto` + `ipv6 subnet Default` раздаст /56 в LAN, но клиенты политики Mihomo тогда выйдут по v6 мимо Mihomo, поэтому в LAN IPv6 **не раздаётся**, а `ipv6: false` остаётся в `home.yaml`.

## Известные ограничения
* v6 через WARP на нодах нет (профили без `::/0`): аудит пишет `warp-antizapret / warp-vpn v6: выхода нет` - это не утечка, v6 клиентов идёт через proton, при его падении blackhole. Через Proton v6 есть.
* Ребут проверен на LV1 (20.11): после старта guard-юнит, правила (v4+v6), цепочки, таблица 100, Proton/WARP, MTProxy восстанавливаются сами. Первый ребут выявил ошибку: `oif proton lookup 51820` в `BASE_RULES` вместе с PostUp wg-quick даёт `RTNETLINK: File exists`, `wg-quick@proton` падает. Правила `oif ...` в `BASE_RULES` не класть.
* IPv6 слоёв: установщик `az-guard-install.sh` выставляет `HAS_IPV6=0`, если на хосте нет нативного v6, и не заполняет v6-подсети слоёв. Для панели (колонка IPv6) и NAT66 нужно `HAS_IPV6=1` и v6-подсети из адресов интерфейсов (`ip -6 addr show dev <iface> scope global`): awg1 `fd28:7::/64,fd29:7::/64`, antizapret-udp `fd29:10::/64`, antizapret-tcp `fd29:11::/64`, vpn-udp `fd28:10::/64`, vpn-tcp `fd28:11::/64`. Без `AZ_EGRESS_NAT` для этих подсетей v6 клиента уходит в Proton с ULA-источником и теряется (v4 при этом работает; случай роутера клиента AWG3 на NL2, 20.11).
* Процедура на узле: `az-guard-install.sh --guard y --no-apply` -> проверить `/etc/az-guard.conf` (HAS_IPV6, v6-подсети, `BASE_RULES` без `oif`) -> `az-guard-test.sh --apply` -> снять его таймер отката и `.armed` -> `--apply` (при `RTNETLINK: File exists` повторить) -> `az-audit.sh` -> `--commit` -> `systemctl start az-egress-monitor` -> убрать остаточные `az-rollback-*.timer`.
* `AZ_EGRESS_NAT` подразумевает MASQUERADE на egress; при наличии собственных SNAT-правил AntiZapret они дублируются безвредно (наша цепочка первая).

## Ревью и проверки (10.11.2026)
* Ревью Kimi `KIMI-7D42F1A3`. Принято: новый `--apply` снимает таймеры предыдущих откатов (иначе старый откат сносил живую конфигурацию); jump сначала вставляется на позицию 1 и только потом удаляются дубли (нет окна без guard); `ensure_rules` не роняет монитор и логирует всё, кроме EEXIST; валидация `LAYERS`. Отклонено: удаление `BASE_RULES` в `restore.sh` (это штатные правила системы, не таблицы 100).
* Живые тесты на NL2: теневой guard 6/6; сквозной через боевой WG `vpn` (временный peer + netns): клиент выходит с IP Proton, guard-счётчик растёт; `az-reverse-test` 7/7; `networkctl reconfigure` и `systemctl restart systemd-networkd` не стирают правила; смещённый jump и удалённые `ip rule` монитор возвращает за <=40 с; двойной `--apply` оставляет один таймер отката.

## Установщик, IPv6 и статус реверса
* **Установка:** `az-guard-install.sh --dualstack y|n --guard y|n --reverse y|n [--yes] [--no-apply] [--ingress-ip IP]` (вызывается из `setup.sh`; см. корневой README). Слои берутся из реально существующих интерфейсов (kernel-маршруты подсетей), `/etc/az-guard.conf` генерируется автоматически; самопроверка: `az-guard-install.test.sh` (нужен root + iproute2, создаёт и удаляет dummy-интерфейсы).
* **IPv6 через Proton:** профиль Proton должен содержать `Address = <v4>/32, <v6>/128` и `AllowedIPs = 0.0.0.0/0, ::/0` (эталон NL2: `2a07:b944::2:2/128`); `warp-antizapret` на NL2 — тоже профиль Proton (не Cloudflare WARP). SNAT клиентов в v6 — цепочка `AZ_EGRESS_NAT` в `ip6tables -t nat`.
* **Reverse-Tunnel и IPv6 на домашнем роутере:** тестировались 10.11.2026 и **сняты** (на роутере остаётся только штатный Mihomo; раздача IPv6 в LAN давала утечку мимо Mihomo). Боевой реверс создаётся панелью AdminPanel, а не этим пакетом.
