import re, shutil, sys, time
B="/opt/mh-app"; ts=time.strftime("%Y%m%d%H%M%S")
tp=B+"/templates/home.yaml"; bp=B+"/build_configs.py"
shutil.copy(tp, tp+".bak-ipchk-"+ts); shutil.copy(bp, bp+".bak-ipchk-"+ts)
t=open(tp,encoding="utf-8").read()
if "ip-checkers" not in t:
    doms=["ifconfig.me","ifconfig.co","checkip.amazonaws.com","ident.me","icanhazip.com","ipify.org","api64.ipify.org","ipinfo.io","ip-api.com","myip.com","wtfismyip.com","ipecho.net","browserleaks.com","whoer.net","dnsleaktest.com","bash.ws"]
    rules="  # ip-checkers: сервисы проверки IP/DNS идут через VPN и честно показывают выходной IP (иначе «Остальной интернет» = прямой, домашний IP)\n"+"".join("  - DOMAIN-SUFFIX,%s,Авто — самый быстрый\n"%d for d in doms)
    anchor="  - IP-CIDR,192.168.0.0/16,Напрямую (провайдер),no-resolve\n"
    assert anchor in t
    t=t.replace(anchor, anchor+"  - IP-CIDR,10.0.0.0/8,Напрямую (провайдер),no-resolve\n".replace("  - IP-CIDR,10.0.0.0/8,Напрямую (провайдер),no-resolve\n","")+rules,1)
    pol='    "'+",".join("+."+d for d in doms)+'": ["1.1.1.1#Авто — самый быстрый"]\n'
    a2='    "rule-set:az-include,az-full,ru-blocked,my-vpn"'
    assert a2 in t
    t=t.replace(a2,pol+a2,1)
    open(tp,"w",encoding="utf-8").write(t)
b=open(bp,encoding="utf-8").read()
if "ipv6.flag" not in b:
    inj=r'''    # IPv6 управляется флагом /opt/mh-app/ipv6.flag ("1" = Dual-Stack, иначе только IPv4); панель/setup.sh пишут его
    try:
        v6 = open(BASE + "/ipv6.flag").read().strip() == "1"
    except OSError:
        v6 = False
    text = re.sub(r"^(\s*ipv6: )(true|false)$", lambda m: m.group(1) + ("true" if v6 else "false"), text, flags=re.M)
'''
    anchor='    return HEAD + text' + chr(10)
    assert anchor in b
    b=b.replace(anchor, inj+anchor,1)
    open(bp,"w",encoding="utf-8").write(b)
print("patched",ts)
