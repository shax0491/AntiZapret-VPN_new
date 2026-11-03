# IPv6 на узлах (03.11.2026)

- `nft-az-nat66.nft` + `az-nat66.service`: NAT66 для клиентов по ULA и изоляция клиентов друг от друга (стоят на DE1, DE2, DE4, NL2).
- Рабочий нативный IPv6: DE1 (`2602:fc16:2:6df::ec5a/64`, шлюз хостера `2602:fc16:2:600::1`) и NL2 (`2a12:9080:9:2b::a/64`, шлюз `2a12:9080:9::1`). Нужно `net.ipv6.conf.<iface>.disable_ipv6=0` и `net.ipv6.conf.all.forwarding=1` (`/etc/sysctl.d/99-ipv6-forward.conf`), иначе `99-disable-ipv6.conf` от AntiZapret глушит адрес.
- DE2 и DE4: статика прописана (netplan `60-ipv6.yaml`), но маршрутизатор хостера не отвечает на NS шлюза `2a0c:4ac1:4::1`, IPv6 не работает; в `/etc/gai.conf` стоит предпочтение IPv4.
- xray: outbound `proton` - `domainStrategy: UseIPv4` (туннель Proton только IPv4); `direct` - `UseIPv4v6` на DE1 и NL2, `UseIPv4` на остальных.
- AAAA клиентам AntiZapret/VPN подавляет `kresd` (экземпляры 127.1.1.1 и 127.2.2.2), настоящие AAAA отдаёт только внутренний резолвер 127.3.3.3.
