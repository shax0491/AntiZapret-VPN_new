#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fake-IPv6 (AAAA) маппинг для АнтиЗапрета.

Аналог механизма proxy.py, но только для IPv6: AAAA-ответы подменяются
адресами из fd00:30::/64, пары fake->real пишутся в nft-карту
`ip6 antizapret mapping6` (dnat через mapping_hook).

shortcut: v6 без WARP, как в v4 только нативный выход
"""

import ipaddress
import re
import subprocess
import threading
import time

from dnslib import AAAA, QTYPE


class Fake6:
    _PAIR_RE = re.compile(r'([0-9a-fA-F:]{2,})\s*:\s*([0-9a-fA-F:]{2,})')

    def __init__(self, cidr="fd00:30::/64", nft="/usr/sbin/nft", env=None, run=subprocess.run, size=131071):
        self.network = ipaddress.IPv6Network(cidr)
        self.nft = nft
        self.env = env
        self.run = run
        self.size = size
        self.lock = threading.Lock()
        self.real2fake = {}  # real_str -> (fake_str, used_ts)
        self.fake2real = {}  # fake_str -> real_str
        self.freed = []      # освобождённые номера N (переиспользование)
        self.next_n = 1      # следующий невыданный номер

    def _run(self, args, **kw):
        return self.run([self.nft] + args, capture_output=True, text=True, env=self.env, **kw)

    @staticmethod
    def _c(addr):
        return ipaddress.IPv6Address(addr).compressed

    def _flush_and_raise(self):
        self._run(["flush", "map", "ip6", "antizapret", "mapping6"])
        raise RuntimeError("mapping6 state inconsistent, flushed")

    def load(self):
        """Создаёт table/map, если нет; восстанавливает состояние из `nft list map`.

        При несоответствии/дубле: flush map и RuntimeError.
        """
        with self.lock:
            self._run(["add", "table", "ip6", "antizapret"])
            r = self._run(["list", "map", "ip6", "antizapret", "mapping6"])
            if r.returncode != 0:
                self._run(["add", "map", "ip6", "antizapret", "mapping6",
                           '{ type ipv6_addr : ipv6_addr ; size 131072 ; }'])
                self.real2fake = {}
                self.fake2real = {}
                self.freed = []
                self.next_n = 1
                return
            out = getattr(r, "stdout", "") or ""
            base = int(self.network.network_address)
            real2fake = {}
            fake2real = {}
            used = set()
            for fake_s, real_s in self._PAIR_RE.findall(out):
                try:
                    fake = ipaddress.IPv6Address(fake_s)
                    real = ipaddress.IPv6Address(real_s)
                except ipaddress.AddressValueError:
                    continue
                n = int(fake) - base
                if (n < 1 or n > self.size or fake not in self.network
                        or n in used
                        or fake.compressed in fake2real
                        or real.compressed in real2fake):
                    self._flush_and_raise()
                used.add(n)
                fake2real[fake.compressed] = real.compressed
                real2fake[real.compressed] = (fake.compressed, time.time())
            self.real2fake = real2fake
            self.fake2real = fake2real
            if used:
                hi = max(used)
                self.next_n = hi + 1
                self.freed = [n for n in range(1, hi + 1) if n not in used]
            else:
                self.next_n = 1
                self.freed = []

    def get(self, real_ip, now):
        """Возвращает fake для real; повтор → тот же fake; пул исчерпан → None;
        ошибка nft → откат состояния и None."""
        real = self._c(real_ip)
        with self.lock:
            item = self.real2fake.get(real)
            if item:
                fake, _ = item
                self.real2fake[real] = (fake, now)
                return fake
            if self.freed:
                n = self.freed.pop()
            elif self.next_n <= self.size:
                n = self.next_n
                self.next_n += 1
            else:
                return None
            fake = (self.network.network_address + n).compressed
            self.real2fake[real] = (fake, now)
            self.fake2real[fake] = real
            r = self._run(["add", "element", "ip6", "antizapret", "mapping6",
                           "{ %s : %s }" % (fake, real)])
            if r.returncode != 0:
                del self.real2fake[real]
                del self.fake2real[fake]
                self.freed.append(n)  # откат состояния
                return None
            return fake

    def expire(self, now, ttl):
        """Удаляет просроченные (now - used > ttl) одним `nft -f -`, возвращает число."""
        with self.lock:
            stale = [real for real, (_, used) in self.real2fake.items()
                     if now - used > ttl]
            if not stale:
                return 0
            fakes = [self.real2fake[real][0] for real in stale]
            body = "delete element ip6 antizapret mapping6 { %s }" % ", ".join(fakes)
            r = self._run(["-f", "-"], input=body)
            if r.returncode != 0:
                return 0
            base = int(self.network.network_address)
            for real in stale:
                fake, _ = self.real2fake.pop(real)
                del self.fake2real[fake]
                self.freed.append(int(ipaddress.IPv6Address(fake)) - base)
            return len(stale)

    def rewrite_aaaa(self, reply, now, ttl_dns):
        """Заменяет все AAAA в dnslib DNSRecord на Fake6, TTL=ttl_dns.
        False, если get() для любой записи вернул None (A-записи не трогает)."""
        targets = []
        for record in reply.rr:
            if record.rtype != QTYPE.AAAA:
                continue
            fake = self.get(str(record.rdata), now)
            if fake is None:
                return False
            targets.append((record, fake))
        # shortcut: v6 без WARP, как в v4 только нативный выход
        for record, fake in targets:
            record.ttl = ttl_dns
            record.rdata = AAAA(fake)
        return True
