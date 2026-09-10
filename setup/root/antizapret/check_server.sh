#!/bin/bash
#
# Предстартовая диагностика сервера AntiZapret VPN.
#
# Поочерёдно запускает набор сторонних open-source утилит для проверки сети,
# гео/блокировок и производительности сервера. Каждый шаг можно прервать
# через Ctrl+C - скрипт перейдёт к следующему пункту, а не завершится целиком.
#
export LC_ALL=C
set -uo pipefail

echo 'Server diagnostics for AntiZapret VPN:'

# Ctrl+C должен убивать только текущий дочерний процесс (например, зависший
# speedtest), а не весь check_server.sh - иначе пользователь не сможет
# пропустить один долгий тест и перейти к следующим.
run_check() {
	local title="$1"
	shift

	echo
	echo "--- $title ---"

	trap '' INT
	( trap - INT; "$@" )
	local rc=$?
	trap - INT

	if [[ $rc -eq 130 ]]; then
		echo "[$title] прервано пользователем (Ctrl+C)"
	elif [[ $rc -ne 0 ]]; then
		echo "[$title] завершено с кодом $rc"
	fi
}

run_check 'IP region (ipregion.vrnt.xyz)' \
	bash -c 'bash <(wget -qO- https://ipregion.vrnt.xyz)'

run_check 'RU Speedtest (speedtest.artydev.ru)' \
	bash -c 'wget -qO- speedtest.artydev.ru | bash'

run_check 'RU iPerf3 (itdoginfo/russian-iperf3-servers)' \
	bash -c 'bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh)'

run_check 'Зарубежные блокировки (Check.Place)' \
	bash -c 'bash <(curl -Ls ip.check.place) -l en'

run_check 'IPQuality (Check.Place)' \
	bash -c 'bash <(curl -Ls https://check.place) -EI'

run_check 'Бенчмарк сервера (bench.sh)' \
	bash -c 'wget -qO- bench.sh | bash'

run_check 'CPU benchmark (sysbench)' \
	bash -c 'command -v sysbench &>/dev/null || apt-get install -y sysbench; sysbench cpu run --threads=1 --time=10'

echo
echo 'Server diagnostics finished.'
exit 0
