# mh-app: шаблон домашнего конфига Mihomo

`templates/home.yaml` - снимок шаблона с DE3 (`/opt/mh-app/templates/home.yaml`), из него `build_configs.py` вместе с реестром узлов `nodes.json` собирает `home-config.yaml` и `work-config.yaml`.

Секреты заменены метками `__CONTROLLER_SECRET__`, `__SUB_TOKEN__`, `__LISTS_TOKEN__`. На DE3 лежит рабочий файл с настоящими значениями, поэтому симлинк на репозиторий невозможен: при правке на DE3 снимок обновляют вручную (скачать файл и повторить подстановку меток).
