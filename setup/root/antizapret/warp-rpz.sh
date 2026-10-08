#!/bin/bash
# Собирает warp.rpz под текущий режим ANTIZAPRET_WARP из готовых result/*.
# В режиме 3 через WARP идут все домены антизапрета (вся proxy.rpz) плюс список WARP,
# в остальных режимах - только список WARP. Вызывается из parse.sh и up.sh: смена режима
# в setup применяется перезапуском, без полного doall.sh.
set -e
export LC_ALL=C
shopt -s nullglob

cd /root/antizapret
source setup

[[ -f result/include-warp-hosts.txt && -f result/exclude-warp-hosts.txt ]] || exit 0

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ "$ANTIZAPRET_WARP" == '3' ]]; then
	[[ -f result/proxy.rpz ]] || exit 0
	cp result/proxy.rpz "$tmp"
else
	echo -e '$TTL 10800\n@ SOA . . (1 1 1 1 10800)' > "$tmp"
fi
sed '/^\.$/ s/.*/*. CNAME ./; t; s/$/ CNAME ./; p; s/^/*./' result/include-warp-hosts.txt >> "$tmp"
sed '/^\.$/ s/.*/*. CNAME rpz-passthru./; t; s/$/ CNAME rpz-passthru./; p; s/^/*./' result/exclude-warp-hosts.txt >> "$tmp"
sed 's/\r//g; /^;/d; /^$/d' config/*warp-rpz.txt >> "$tmp"
cp "$tmp" result/warp.rpz
chmod 644 result/warp.rpz

if diff -q result/warp.rpz /etc/knot-resolver/warp.rpz &>/dev/null; then
	exit 0
fi

touch /etc/knot-resolver/warp.rpz
changed="$(diff /etc/knot-resolver/warp.rpz result/warp.rpz | grep -E '^[<>]' | sed -E 's/^[<>] //; s/^\*\.//; s/[[:space:]]+CNAME.*//' | grep -vE '^\$TTL|^@|^;' | sort -u)" || true
cp -f result/warp.rpz /etc/knot-resolver/warp.rpz.tmp
mv -f /etc/knot-resolver/warp.rpz.tmp /etc/knot-resolver/warp.rpz
echo "warp.rpz updated for ANTIZAPRET_WARP=$ANTIZAPRET_WARP ($(wc -l < result/warp.rpz) lines)"

# Закэшированные ответы помнят прежний маршрут: без очистки смена доходит до клиентов
# только по истечении TTL. Мало доменов - чистим точечно, смена режима 3 - весь кэш.
sock=/run/knot-resolver/control/1
[[ -S "$sock" && -n "$changed" ]] || exit 0
sleep 5
if (( $(wc -l <<< "$changed") > 2000 )); then
	echo 'cache.clear()' | socat - "$sock" &>/dev/null || true
else
	while read -r name; do
		if [[ -n "$name" ]]; then
			echo "cache.clear('$name', true)" | socat - "$sock" &>/dev/null || true
		fi
	done <<< "$changed"
fi
exit 0
