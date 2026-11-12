import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "setup", "root", "antizapret"))
# -*- coding: utf-8 -*-
"""pytest для Fake6 без реального nft: поддельный run хранит карту в словаре."""

import re
import types
import ipaddress
import pytest

from dnslib import A, AAAA, DNSRecord, QTYPE, RR

from proxy6 import Fake6


class FakeNft:
    """Эмулирует nft: add/list/flush/delete element|map|table и `nft -f -`."""

    def __init__(self):
        self.map = {}
        self.fail_add = False

    @staticmethod
    def _c(addr):
        return ipaddress.IPv6Address(addr).compressed

    def __call__(self, cmd, input=None, **kw):
        args = cmd[1:]
        ok = types.SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[:3] == ["add", "table", "ip6"]:
            return ok
        if args[:3] == ["add", "map", "ip6"]:
            return ok
        if args[:2] == ["flush", "map"]:
            self.map.clear()
            return ok
        if args[:2] == ["delete", "map"]:
            self.map.clear()
            return ok
        if args[:2] == ["delete", "table"]:
            self.map.clear()
            return ok
        if args[:2] == ["list", "map"]:
            if not self.map:
                return types.SimpleNamespace(returncode=1, stdout="", stderr="No such file or directory")
            elements = ", ".join("%s : %s" % (k, v) for k, v in sorted(self.map.items()))
            out = "table ip6 antizapret {\n\tmap mapping6 {\n\t\telements = { %s }\n\t}\n}\n" % elements
            return types.SimpleNamespace(returncode=0, stdout=out, stderr="")
        if args[:2] == ["add", "element"]:
            if self.fail_add:
                return types.SimpleNamespace(returncode=1, stdout="", stderr="boom")
            m = re.search(r"\{\s*([0-9a-fA-F:]+)\s*:\s*([0-9a-fA-F:]+)\s*\}", args[-1])
            self.map[self._c(m.group(1))] = self._c(m.group(2))
            return ok
        if args == ["-f", "-"]:
            m = re.search(r"\{(.*)\}", input)
            for fake in m.group(1).split(","):
                self.map.pop(self._c(fake.strip()), None)
            return ok
        return types.SimpleNamespace(returncode=1, stdout="", stderr="unknown command: %r" % (args,))


def make(size=131071):
    fake = FakeNft()
    return Fake6(nft="/usr/sbin/nft", run=fake, size=size), fake


def test_repeat_get_returns_same_fake():
    f6, _ = make()
    a = f6.get("2606:4700::1", now=100.0)
    b = f6.get("2606:4700::1", now=200.0)
    assert a == b
    assert a == "fd00:30::1"


def test_different_reals_get_distinct_fakes_within_cidr():
    f6, _ = make()
    net = ipaddress.IPv6Network("fd00:30::/64")
    a = f6.get("2606:4700::1", now=0.0)
    b = f6.get("2606:4700::2", now=0.0)
    assert a != b
    for fake in (a, b):
        assert ipaddress.IPv6Address(fake) in net


def test_pool_exhausted_returns_none():
    f6, _ = make(size=3)
    assert f6.get("2001:db8::1", now=0.0) is not None
    assert f6.get("2001:db8::2", now=0.0) is not None
    assert f6.get("2001:db8::3", now=0.0) is not None
    assert f6.get("2001:db8::4", now=0.0) is None


def test_expire_frees_and_number_is_reused():
    f6, fake = make(size=2)
    f6.get("2001:db8::1", now=0.0)
    f6.get("2001:db8::2", now=10.0)
    assert f6.expire(now=55.0, ttl=50) == 1
    # номер fd00:30::1 освобождён и переиспользован
    assert f6.get("2001:db8::3", now=55.0) == "fd00:30::1"
    calls = fake.map  # состояние карты согласовано: старой пары нет, новая есть
    assert "fd00:30::2" in calls and calls["fd00:30::2"] == "2001:db8::2"
    assert "fd00:30::1" in calls and calls["fd00:30::1"] == "2001:db8::3"


def test_load_restores_state_from_nft_output():
    fake = FakeNft()
    fake.map["fd00:30::1"] = "2606:4700::1"
    fake.map["fd00:30::2"] = "2606:4700::2"
    f6 = Fake6(nft="/usr/sbin/nft", run=fake)
    f6.load()
    # повторный get даёт тот же fake, новый real получает следующий номер
    assert f6.get("2606:4700::1", now=5.0) == "fd00:30::1"
    assert f6.get("2606:4700::9", now=5.0) == "fd00:30::3"


def test_load_inconsistent_flushes_and_raises():
    fake = FakeNft()
    fake.map["fd00:31::1"] = "2606:4700::1"  # вне fd00:30::/64
    f6 = Fake6(nft="/usr/sbin/nft", run=fake)
    with pytest.raises(RuntimeError):
        f6.load()
    assert fake.map == {}


def test_rewrite_aaaa_rewrites_only_aaaa():
    f6, _ = make()
    reply = DNSRecord.question("example.com", "AAAA").reply()
    reply.add_answer(RR("example.com", QTYPE.AAAA, rdata=AAAA("2606:4700::1"), ttl=60))
    reply.add_answer(RR("example.com", QTYPE.AAAA, rdata=AAAA("2606:4700::2"), ttl=60))
    reply.add_answer(RR("example.com", QTYPE.A, rdata=A("1.2.3.4"), ttl=60))
    assert f6.rewrite_aaaa(reply, now=0.0, ttl_dns=300) is True
    aaaas = [r for r in reply.rr if r.rtype == QTYPE.AAAA]
    assert len(aaaas) == 2
    for r in aaaas:
        assert str(r.rdata).startswith("fd00:30::")
        assert r.ttl == 300
    a_rec = [r for r in reply.rr if r.rtype == QTYPE.A][0]
    assert str(a_rec.rdata) == "1.2.3.4"
    assert a_rec.ttl == 60


def test_nft_add_error_returns_none_and_state_is_clean():
    fake = FakeNft()
    fake.fail_add = True
    f6 = Fake6(nft="/usr/sbin/nft", run=fake, size=3)
    assert f6.get("2606:4700::1", now=0.0) is None
    assert f6.real2fake == {}
    assert f6.fake2real == {}
    assert fake.map == {}
    # номер не потерян: после снятия ошибки пул работает
    fake.fail_add = False
    assert f6.get("2606:4700::1", now=0.0) == "fd00:30::1"
