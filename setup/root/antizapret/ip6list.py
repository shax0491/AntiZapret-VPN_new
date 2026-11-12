#!/usr/bin/env python3
# Список IPv6-подсетей для маршрутов АнтиЗапрета: include минус exclude, валидация и агрегация.
# Использование: ip6list.py ВЫХОД --include ФАЙЛ... --exclude ФАЙЛ...
# Строки с комментариями (#) и пустые пропускаются, мусор игнорируется с сообщением в stderr.
import argparse
import ipaddress
import sys


def read_nets(paths):
	nets = []
	for path in paths:
		try:
			f = open(path, encoding="utf-8")
		except OSError:
			continue
		with f:
			for line in f:
				token = "".join(line.split())
				if not token or not (token[0].isalnum() or token[0] == ":"):
					continue
				try:
					net = ipaddress.ip_network(token, strict=False)
				except ValueError:
					print(f"ip6list: пропущено {token!r} в {path}", file=sys.stderr)
					continue
				if net.version == 6:
					nets.append(net)
	return nets


def subtract(nets, excludes):
	for ex in excludes:
		out = []
		for net in nets:
			if net.overlaps(ex):
				out.extend(net.address_exclude(ex) if net.supernet_of(ex) and net != ex else [] if ex.supernet_of(net) else [net])
			else:
				out.append(net)
		nets = out
	return nets


def main():
	p = argparse.ArgumentParser()
	p.add_argument("output")
	p.add_argument("--include", nargs="*", default=[])
	p.add_argument("--exclude", nargs="*", default=[])
	args = p.parse_args()
	nets = list(ipaddress.collapse_addresses(read_nets(args.include)))
	nets = subtract(nets, read_nets(args.exclude))
	nets = sorted(ipaddress.collapse_addresses(nets))
	with open(args.output, "w", encoding="utf-8", newline="\n") as f:
		for net in nets:
			f.write(f"{net}\n")
	print(f"{len(nets)} - route-ips6.txt")


if __name__ == "__main__":
	main()
