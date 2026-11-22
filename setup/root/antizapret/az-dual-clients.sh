#!/bin/sh
# Карта dual-клиентов AWG3 для kresd: IPv4 берётся из комментария пира в awg1.conf ("[Peer]" -> "# имя" -> ... ->
# "AllowedIPs = 10.9.0.N/32, ..."). В карте: клиенты со строкой "имя dual" в ipv6-profile.txt и, если IPV6_PROFILE_DEFAULT=dual
# (как в client.sh), клиенты без строки профиля, у которых на сервере есть IPv6 (fd29:7::N). "имя ipv4" исключает клиента.
# Вызывается из панели (sync_dual_map) как `sh az-dual-clients.sh`.
#
# Ошибка = ненулевой код, понятное сообщение в stderr и НЕТ изменений в прежней карте:
#   1 - нет/не читается/повреждён awg1.conf или не читается ipv6-profile.txt
#   2 - не удалось собрать или записать карту
# Запись атомарная: временный файл в каталоге карты + mv, права и владелец прежней карты сохраняются.
AZ_DUAL_PROFILE=${AZ_DUAL_PROFILE:-/root/antizapret/config/ipv6-profile.txt}
AZ_DUAL_AWG_CONF=${AZ_DUAL_AWG_CONF:-/etc/amnezia/amneziawg3/awg1.conf}
AZ_DUAL_MAP=${AZ_DUAL_MAP:-/etc/knot-resolver/dual-clients.txt}
AZ_DUAL_SETUP=${AZ_DUAL_SETUP:-/root/antizapret/setup}

die() { echo "az-dual-clients: $2" >&2; exit "$1"; }

[ -r "$AZ_DUAL_AWG_CONF" ] || die 1 "нет или не читается $AZ_DUAL_AWG_CONF, карта не изменена"
grep -q '^\[Interface\]' "$AZ_DUAL_AWG_CONF" || die 1 "$AZ_DUAL_AWG_CONF повреждён (нет секции [Interface]), карта не изменена"
if [ -e "$AZ_DUAL_PROFILE" ] && [ ! -r "$AZ_DUAL_PROFILE" ]; then
	die 1 "не читается $AZ_DUAL_PROFILE, карта не изменена"
fi

[ ! -d "$AZ_DUAL_MAP" ] || die 2 "$AZ_DUAL_MAP - каталог, а не файл карты, карта не изменена"
T=$(mktemp "$AZ_DUAL_MAP.XXXXXX") || die 2 "не удалось создать временный файл рядом с $AZ_DUAL_MAP (нет каталога или нет прав), карта не изменена"
trap 'rm -f "$T"' EXIT

printf '' > "$T" || die 2 "не удалось записать временный файл $T, карта не изменена"
DEF=$(sed -n "s/^IPV6_PROFILE_DEFAULT=//p" "$AZ_DUAL_SETUP" 2>/dev/null | tail -n 1 | tr -d "'\"")
[ -n "$DEF" ] || DEF=dual # как в client.sh: без значения профиль по умолчанию dual
# dual: явная строка "имя dual", либо (профиль по умолчанию dual) пир с IPv6 на сервере (fd29:7::N) без явной строки "имя ipv4".
# Без второго правила клиент с профилем «по умолчанию» получал IPv6 в конфиге и на сервере, но не попадал в карту kresd (AAAA не отдавался).
[ -e "$AZ_DUAL_PROFILE" ] || AZ_DUAL_PROFILE=/dev/null
awk -v prof="$AZ_DUAL_PROFILE" -v def="$DEF" '
	BEGIN { while ((getline l < prof) > 0) { split(l, p, " "); if (p[1] != "" && p[1] !~ /^#/) pr[p[1]] = p[2] } }
	/^\[Peer\]/ { name = ""; next }
	/^# / { if (name == "") { name = substr($0, 3); base = name; sub(/_(az|vpn)$/, "", base) } next }
	/^AllowedIPs/ { if (match($0, /10\.9\.0\.[0-9]+/)) { ip = substr($0, RSTART, RLENGTH); d = (pr[name] != "") ? pr[name] : pr[base]
		if (d == "dual" || (d == "" && def == "dual" && $0 ~ /fd29:7::/)) print ip } }' "$AZ_DUAL_AWG_CONF" >> "$T" || die 2 "не удалось построить карту из $AZ_DUAL_AWG_CONF (ошибка разбора или записи, возможно нет места на диске), карта не изменена"
sort -u "$T" -o "$T" || die 2 "не удалось отсортировать карту, карта не изменена"

if [ -e "$AZ_DUAL_MAP" ]; then
	cmp -s "$T" "$AZ_DUAL_MAP" && exit 0
	chmod --reference="$AZ_DUAL_MAP" "$T" 2>/dev/null || chmod 644 "$T"
	chown --reference="$AZ_DUAL_MAP" "$T" 2>/dev/null || true
else
	chmod 644 "$T" || die 2 "не удалось выставить права на $T, карта не изменена"
fi
mv -f "$T" "$AZ_DUAL_MAP" || die 2 "не удалось записать $AZ_DUAL_MAP, прежняя карта не изменена"
