import json, sys, urllib.request
kind = sys.argv[1]; j = json.load(open(f"/tmp/azsetup-{kind}.json"))
cfg = dict(l.strip().split("=", 1) for l in open("/etc/proton-pick.conf") if "=" in l and not l.startswith("#"))
r = urllib.request.Request(cfg["REKEY_URL"], data=json.dumps({"iface": j["iface"], "entry_ip": j["entry_ip"], "confirm": j["device"], "ok": True}).encode(), headers={"X-Rekey-Token": cfg["REKEY_TOKEN"], "Content-Type": "application/json"})
print(urllib.request.urlopen(r, timeout=60).read().decode()[:100])
