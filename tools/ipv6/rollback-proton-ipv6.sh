set -e
ts=$(date +%Y%m%d%H%M)
cp /opt/xray-az/config.json /opt/xray-az/config.json.bak-rollback-$ts
cp /etc/wireguard/proton.conf /etc/wireguard/proton.conf.bak-rollback-$ts
sed -i -E 's/"domainStrategy": "UseIPv(4v6|6v4)"/"domainStrategy": "UseIPv4"/' /opt/xray-az/config.json
sed -i -E 's#^AllowedIPs = 0\.0\.0\.0/0, ::/0#AllowedIPs = 0.0.0.0/0#' /etc/wireguard/proton.conf
sed -i -E '/^(PostUp|PostDown)/{s/sysctl -q -w net\.ipv6\.conf\.%i\.disable_ipv6=0; //; s/ip -6 [^;]*; ?//g; s/; *$//}' /etc/wireguard/proton.conf
python3 -c "import json;json.load(open('/opt/xray-az/config.json'))"
# живое состояние без рестарта wg
for pk in $(wg show proton peers); do wg set proton peer $pk allowed-ips 0.0.0.0/0; done
ip -6 rule del oif proton lookup 51820 pref 1000 2>/dev/null || true
ip -6 route flush table 51820 2>/dev/null || true
ip -6 addr del 2a07:b944::2:2/128 dev proton 2>/dev/null || true
sysctl -q -w net.ipv6.conf.proton.disable_ipv6=1
systemctl restart xray-az; sleep 2; systemctl is-active xray-az
grep -n domainStrategy /opt/xray-az/config.json | tr -s ' '
grep -nE "^(AllowedIPs|PostUp|PostDown)" /etc/wireguard/proton.conf
wg show proton allowed-ips; ip -6 addr show dev proton | grep -c inet6 || true
curl -4 -s -m 8 -o /dev/null --interface proton -w "proton v4: %{http_code} %{time_total}\n" https://www.google.com
