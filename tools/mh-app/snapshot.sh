#!/bin/bash
# Снимок шаблона с DE3 в репозиторий: реальные секрет контроллера и токены подписки/списков заменяются метками.
# Никогда не копируйте /opt/mh-app/templates/home.yaml напрямую (так значения попали в публичный git 03.11.2026).
set -e
H=root@5.231.45.169; K=${1:-$HOME/Desktop/de_htb_claude}
ssh -i "$K" $H 'cd /opt/mh-app; SUB=$(cat sub.token); CTL=$(cat mihomo.secret); LST=$(cat /opt/az-lists/token);
  sed "s/$SUB/__SUB_TOKEN__/g; s/$CTL/__CONTROLLER_SECRET__/g; s/$LST/__LISTS_TOKEN__/g" templates/home.yaml' > "$(dirname "$0")/templates/home.yaml"
! grep -qE '[0-9a-f]{16,}' "$(dirname "$0")/templates/home.yaml" || { echo "в снимке остались длинные hex-значения - проверьте"; exit 1; }
