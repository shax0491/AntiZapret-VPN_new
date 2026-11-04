#!/bin/sh
# Конфиг mihomo собирается на DE3 (templates/home.yaml + реестр серверов nodes.json, команда mh-node) и проверяется там.
# Раз в 30 минут: если он изменился - применяем без перезапуска mihomo (API reload); не принял - возвращаем прежний.
URL=https://de3.hoststatus2346.ru/lists/__LISTS_TOKEN__/work-config.yaml
M=/opt/etc/mihomo
N=/tmp/mh-cfg.new
TK=$(cat /opt/etc/mihomo/cfg.token 2>/dev/null)
curl -fsS -m 60 -x http://127.0.0.1:7890 -H "X-Cfg-Token: $TK" -o $N "$URL" 2>/dev/null || curl -fsS -m 60 -H "X-Cfg-Token: $TK" -o $N "$URL" 2>/dev/null || exit 0
grep -q '^proxy-groups:' $N && grep -q '^rules:' $N || exit 0
cmp -s $N $M/config.yaml && exit 0
SEC=$(grep -oE '^secret: "[^"]+"' $M/config.yaml | cut -d'"' -f2)
reload() { curl -s -m 120 -o /tmp/mh-reload.log -w '%{http_code}' -X PUT -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"path":"/opt/etc/mihomo/config.yaml"}' 'http://127.0.0.1:9190/configs?force=true'; }
cp $M/config.yaml $M/config.yaml.prev && cp $N $M/config.yaml
code=$(reload "$SEC")
if [ "$code" = 204 ]; then
	logger -t config-sync "новый конфиг с DE3 применён"
	# после перечитывания конфига история замеров пустая - автовыбор пересчитать сразу, а не через 5 минут
	[ -x /opt/bin/mh-ut-delay.sh ] && /opt/bin/mh-ut-delay.sh
else
	cp $M/config.yaml.prev $M/config.yaml; reload "$SEC" >/dev/null
	logger -t config-sync "конфиг с DE3 НЕ применён ($code: $(head -c 200 /tmp/mh-reload.log)), оставлен прежний"
fi
