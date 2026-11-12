# IPv6 в AntiZapret-VPN

## Режимы (`/root/antizapret/setup`)

| Переменная | Значения | Смысл |
|---|---|---|
| `ENABLE_IPV6` | `y` / `n` | Если не задана: `y` при `IPV6_MODE` b/c, иначе `n` |
| `IPV6_MODE` | `a` / `b` / `c` | a — только IPv4; b — Full-слои получают IPv6 (`::/0`), split без IPv6; c — b + Fake-IPv6 для заблокированных доменов в split |
| `IPV6_EGRESS` | `native` / `proton` / `warp` / `relay` | Выход IPv6 с узла. `proton`, `warp` и `relay` требуют готового интерфейса (`IPV6_PROTON_INTERFACE`, по умолчанию `proton`; `IPV6_WARP_INTERFACE`, по умолчанию `warp-antizapret`, IPv6-адрес берётся из `/etc/wireguard/<iface>.conf`, если его нет на интерфейсе; `IPV6_RELAY_INTERFACE`, по умолчанию `v6up`) |
| `IPV6_PROFILE_DEFAULT` | `dual` / `ipv4` | Профиль клиентов по умолчанию |

Эффективный режим пишет `up.sh` в `/etc/knot-resolver/ipv6-mode`, состояние — в `/run/antizapret-ipv6.state`.
Если выход IPv6 не отвечает (ping на 2606:4700:4700::1111 / 2001:4860:4860::8888 с интерфейса выхода), режим принудительно становится `a`, причина — в `reason=`.

## Как это работает в режиме c

1. `kresd@1` (split) отправляет AAAA заблокированных доменов в `proxy.py`; тот выдаёт Fake-IPv6 `fd00:30::N` и кладёт пару в `nft ip6 antizapret mapping6`.
2. DNAT-хук `mapping_hook` (prerouting, priority -50) для клиентов `fd29:*` подменяет `fd00:30::N` на настоящий адрес.
3. Прочие AAAA в split пустые (кроме .ru/.su/.рф), чтобы клиент без IPv6 у провайдера не зависал.
4. Full-слои (`fd28:*`) получают настоящий AAAA и маршрут `::/0`; выход — MASQUERADE через интерфейс выхода (`ip6tables`, policy-routing таблица 13337 для proton/relay).
5. Блок «AAAA NODATA» панели (`custom.lua`/`custom2.lua`) в режимах b/c не срабатывает: `kresd.conf` выставляет глобальную `ipv6_dual`.

## Подсети слоёв

OpenVPN: antizapret-udp `fd29:10::/64`, -tcp `fd29:11::/64`, vpn-udp `fd28:10::/64`, vpn-tcp `fd28:11::/64`.
WG/AWG 1.5: `fd29:8::/64` / `fd28:8::/64`. AWG 2.0: `fd29:9::/64` / `fd28:9::/64`. AWG 3.0: `fd29:7::/64` (split) / `fd28:7::/64` (full), адреса на `awg1` ставит `awg3-up.sh` только при эффективном режиме b/c.

## Списки

`config/include-ips6.txt` и `config/exclude-ips6.txt` (плюс `download/*ips6.txt`) собираются `ip6list.py` в `result/route-ips6.txt` (агрегация, исключения вычитаются). В режиме c маршруты попадают в `result/DEFAULT` (OpenVPN) и `/etc/wireguard/ips6` (AllowedIPs split-профилей). Применить: `/root/antizapret/doall.sh ip`.

## Профили клиентов

`/root/antizapret/config/ipv6-profile.txt`, строки `имя ipv4|dual`. `ipv4` — профиль без IPv6 (в WG/AWG нет v6-адреса и AllowedIPs, в OpenVPN `push-remove route-ipv6`, на Windows `block-ipv6`). Применяется при `client.sh` (пересоздание профиля) и при подключении OpenVPN.

## Проверка

```
cat /etc/knot-resolver/ipv6-mode /run/antizapret-ipv6.state
dig +short AAAA instagram.com @127.1.1.1      # fd00:30::N
dig +short AAAA google.com @127.2.2.2         # настоящий AAAA
nft list map ip6 antizapret mapping6
```

## Откат

В `setup`: `IPV6_MODE=a` (или `ENABLE_IPV6=n`), `systemctl restart antizapret`.

## Известные ограничения

Режимы `proton` и `relay` не настраиваются автоматически: нужен интерфейс с IPv6-адресом. Клиентские AWG 3.0 профили панель пока выдаёт без IPv6.
