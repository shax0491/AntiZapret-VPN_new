#!/bin/bash
# Повторяет запросы KinolinkTV после входа: bash diag.sh <логин Jellyfin> <пароль>. Пароль в репозиторий не попадает.
B=${JF:-https://jellyfin.hoststatus2342.ru:8443}; L=${LAMPAC:-https://lampa.hoststatus2343.ru:8443}
A='MediaBrowser Client="KinolinkTV", Device="AndroidTV", DeviceId="diag0001", Version="0.1"'
R=$(curl -s -m20 -X POST "$B/Users/AuthenticateByName" -H "Authorization: $A" -H 'Content-Type: application/json' -d "{\"Username\":\"$1\",\"Pw\":\"$2\"}")
TOK=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessToken"])') || { echo "вход не удался: $R" | head -c 200; exit 1; }
UID_=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["User"]["Id"])'); H="Authorization: $A, Token=\"$TOK\""
F="Fields=Overview,PremiereDate,DateCreated,CommunityRating,ProductionYear,SeriesId,SeriesName&EnableImageTypes=Primary,Backdrop"
t(){ curl -s -m30 -o /tmp/diag.out -w "$1: HTTP %{http_code} %{time_total}s\n" -H "$H" "${@:2}"; }
t resume "$B/Users/$UID_/Items/Resume?MediaTypes=Video&Limit=20&$F"
t каталог "$B/Users/$UID_/Items?Recursive=true&IncludeItemTypes=Movie,Series&SortBy=PremiereDate&SortOrder=Descending&Limit=60&$F"
python3 - <<PY
import json
d=json.load(open("/tmp/diag.out")); it=d.get("Items",[]); print("элементов:",len(it)); open("/tmp/diag.id","w").write(next((i["Id"] for i in it if i["Type"]=="Movie"),it[0]["Id"] if it else ""))
PY
ID=$(cat /tmp/diag.id); [ -n "$ID" ] && {
 curl -s -m30 -X POST -H "$H" -H 'Content-Type: application/json' -d '{}' "$B/Items/$ID/PlaybackInfo?UserId=$UID_&AutoOpenLiveStream=false" -o /tmp/diag.out -w "PlaybackInfo: HTTP %{http_code}\n"
 MS=$(python3 -c 'import json;print(json.load(open("/tmp/diag.out"))["MediaSources"][0]["Id"])')
 curl -s -m30 -r 0-1023 -o /dev/null -w "прямой поток: HTTP %{http_code} %{size_download}B\n" "$B/Videos/$ID/stream?static=true&MediaSourceId=$MS&PlaySessionId=d1&api_key=$TOK"; }
curl -s -m10 -o /dev/null -w "Lampac /lite/events: HTTP %{http_code}\n" "$L/lite/events"
curl -s -m10 -X POST "$L/jfauth/login" -d "username=$1&password=$2&uid=diag000000000001" | python3 -c 'import sys,json;j=json.load(sys.stdin);print("Lampac uid:",bool(j.get("uid")),j.get("msg"))'
