#!/usr/bin/env -S python3 -u
# -*- coding: utf-8 -*-

import re,subprocess,time,argparse,threading,os
from ipaddress import IPv4Network
from dnslib import DNSRecord,RCODE,QTYPE,A
from dnslib.server import DNSServer,DNSHandler,BaseResolver,DNSLogger,TCPServer
from proxy6 import Fake6

class ProxyResolver(BaseResolver):
    def __init__(self,dns,dns_port,dns_timeout,fake_cidr,dns_ttl,expire,fake6_cidr="fd00:30::/64",fake6_force=False):
        self._env=os.environ.copy()
        # Fake-IPv6 для AAAA включается, когда /etc/knot-resolver/ipv6-mode (его пишет up.sh) равен 'c'
        # (или принудительно --ipv6); иначе AAAA отдаются как есть, как до IPv6
        self.fake6_cidr=fake6_cidr
        self.fake6_force=fake6_force
        self.fake6_obj=None
        self._fake6_on=fake6_force
        self._fake6_ts=0
        self.ip_pool={str(x) for x in IPv4Network(fake_cidr).hosts()}
        self.ip_map={}
        # Loading existing fake IP mapping
        mapping=subprocess.run(["/usr/sbin/nft","list","map","ip","antizapret","mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=self._env)
        if mapping.returncode:
            subprocess.run(["/usr/sbin/nft","add","table","ip","antizapret"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","map","ip","antizapret","mapping","{","type","ipv4_addr",":","ipv4_addr",";","size","131072",";","}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        warp_ips=set()
        warp=subprocess.run(["/usr/sbin/nft","list","set","ip","antizapret","warp"],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=self._env)
        if warp.returncode:
            subprocess.run(["/usr/sbin/nft","add","table","ip","antizapret"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","set","ip","antizapret","warp","{","type","ipv4_addr",";","size","131072",";","}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        else:
            warp_ips.update(re.findall(r"\d+\.\d+\.\d+\.\d+",warp.stdout))
        now=time.time()
        for fake_ip,real_ip in re.findall(r"(\d+\.\d+\.\d+\.\d+)\s*:\s*(\d+\.\d+\.\d+\.\d+)",mapping.stdout):
            if not self.mapping_ip(real_ip,fake_ip,now,fake_ip in warp_ips):
                print("Restarting: Invalid loaded fake IP mapping")
                try:
                    subprocess.run(["/usr/sbin/nft","flush","map","ip","antizapret","mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                    subprocess.run(["/usr/sbin/nft","flush","set","ip","antizapret","warp"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                finally:
                    os._exit(1)
        print(f"Loaded: {len(self.ip_map)} fake IPs")
        self.dns=dns
        self.dns_port=dns_port
        self.dns_timeout=dns_timeout
        self.dns_ttl=dns_ttl
        self.expire=expire
        self.lock=threading.Lock()
        # Start thread for expire fake IP mapping
        threading.Thread(target=self.expire_mapping_worker,daemon=True).start()

    @property
    def fake6(self):
        now=time.time()
        if not self.fake6_force and now-self._fake6_ts>5:
            self._fake6_ts=now
            try:
                with open("/etc/knot-resolver/ipv6-mode",encoding="utf-8") as f:
                    self._fake6_on=f.read().strip()=="c"
            except OSError:
                self._fake6_on=False
        if self._fake6_on and self.fake6_obj is None:
            obj=Fake6(self.fake6_cidr)
            try:
                obj.load()
            except Exception as e:
                print(f"Error: Fake-IPv6 disabled: {e}")
                self._fake6_on=False
                return None
            self.fake6_obj=obj
        return self.fake6_obj if self._fake6_on else None

    def get_fake_ip(self,real_ip,now,warp):
        with self.lock:
            entry=self.ip_map.get((real_ip,warp))
            if entry:
                entry["used"]=now
                return entry["fake_ip"]
            if not self.ip_pool:
                print("Error: No fake IP left in IP pool")
                return None
            fake_ip=self.ip_pool.pop()
            self.ip_map[(real_ip,warp)]={"fake_ip": fake_ip,"used": now}
        try:
            if warp:
                subprocess.run(["/usr/sbin/nft","add","element","ip","antizapret","warp","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","element","ip","antizapret","mapping","{",fake_ip,":",real_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        except Exception as e:
            print(f"Error: {e} (real_ip={real_ip} fake_ip={fake_ip} warp={warp})")
            with self.lock:
                del self.ip_map[(real_ip,warp)]
                self.ip_pool.add(fake_ip)
            if warp:
                subprocess.run(["/usr/sbin/nft","delete","element","ip","antizapret","warp","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","delete","element","ip","antizapret","mapping","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            return None
        #print(f"Mapping: {fake_ip} to {real_ip} warp={warp}")
        return fake_ip

    def mapping_ip(self,real_ip,fake_ip,now,warp):
        if self.ip_map.get((real_ip,warp)):
            print(f"Error: Real IP {real_ip} already mapped")
            return False
        if fake_ip not in self.ip_pool:
            print(f"Error: Fake IP {fake_ip} not in IP pool")
            return False
        self.ip_pool.discard(fake_ip)
        self.ip_map[(real_ip,warp)]={"fake_ip": fake_ip,"used": now}
        #print(f"Mapping: {fake_ip} to {real_ip} warp={warp}")
        return True

    def expire_mapping_worker(self):
        while True:
            time.sleep(self.expire)
            try:
                self.expire_mapping()
                if self.fake6_obj:
                    n6=self.fake6_obj.expire(time.time(),self.expire)
                    if n6:
                        print(f"Expired: {n6} fake IPv6")
            except Exception as e:
                print(f"Error: {e}")
                print("Restarting: Expire fake IP mapping failed")
                try:
                    subprocess.run(["/usr/sbin/nft","flush","map","ip","antizapret","mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                    subprocess.run(["/usr/sbin/nft","flush","set","ip","antizapret","warp"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                finally:
                    os._exit(2)

    def expire_mapping(self):
        with self.lock:
            now=time.time()
            expired=[]
            warp_ips=[]
            mapping_ips=[]
            for (real_ip,warp),entry in self.ip_map.items():
                if now - entry["used"] > self.expire:
                    expired.append((real_ip,warp,entry["fake_ip"]))
            for real_ip,warp,fake_ip in expired:
                self.ip_pool.add(fake_ip)
                del self.ip_map[(real_ip,warp)]
                if warp:
                    warp_ips.append(fake_ip)
                mapping_ips.append(fake_ip)
                #print(f"Unmapping: {fake_ip} to {real_ip} warp={warp}")
        if expired:
            rules=[]
            if warp_ips:
                rules.append("delete element ip antizapret warp { "+", ".join(warp_ips)+" }")
            rules.append("delete element ip antizapret mapping { "+", ".join(mapping_ips)+" }")
            subprocess.run(["/usr/sbin/nft","-f","-"],input="\n".join(rules).encode(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            print(f"Expired: {len(expired)} fake IPs")

    def resolve(self,request,handler):
        warp=handler.server.warp
        fake6=self.fake6 if request.q.qtype==QTYPE.AAAA else None
        if fake6 and warp:
            # v6 через WARP не поддерживается: пустой ответ, клиент остаётся на IPv4
            return request.reply()
        try:
            if handler.protocol=="udp":
                data=request.send(self.dns,self.dns_port,timeout=self.dns_timeout)
            else:
                data=request.send(self.dns,self.dns_port,tcp=True,timeout=self.dns_timeout)
            reply=DNSRecord.parse(data)
            if fake6:
                if not fake6.rewrite_aaaa(reply,time.time(),self.dns_ttl):
                    reply=request.reply()
                    reply.header.rcode=RCODE.SERVFAIL
                    return reply
            if request.q.qtype==QTYPE.A:
                now=time.time()
                for record in reply.rr:
                    record.ttl=self.dns_ttl
                    if record.rtype!=QTYPE.A:
                        continue
                    real_ip=str(record.rdata)
                    fake_ip=self.get_fake_ip(real_ip,now,warp)
                    if not fake_ip:
                        reply=request.reply()
                        reply.header.rcode=RCODE.SERVFAIL
                        return reply
                    record.rdata=A(fake_ip)
        except Exception as e:
            print(f"Error: {e} (qname={request.q.qname} qtype={QTYPE[request.q.qtype]} protocol={handler.protocol})")
            reply=request.reply()
            reply.header.rcode=RCODE.SERVFAIL
        return reply

if __name__=="__main__":
    p=argparse.ArgumentParser(description="DNS Proxy")
    p.add_argument("--dns",default="127.3.3.3:53",help="Upstream DNS server:port (default: 127.3.3.3:53)")
    p.add_argument("--dns-timeout",type=float,default=5,help="Upstream DNS timeout (default: 5s)")
    p.add_argument("--fake-cidr",default="198.18.0.0/15",help="Fake IP CIDR (default: 198.18.0.0/15)")
    p.add_argument("--dns-ttl",type=int,default=300,help="TTL in seconds for A records (default: 300)")
    p.add_argument("--expire",type=int,default=3600,help="Seconds of inactivity before fake IP is removed (default: 3600)")
    p.add_argument("--proxy",default="127.4.4.4:53",help="Local Fake IP proxy listen address:port (default: 127.4.4.4:53)")
    p.add_argument("--warp",default="127.5.5.5:53",help="Local WARP proxy listen address:port (default: 127.5.5.5:53)")
    p.add_argument("--ipv6",action="store_true",default=False,help="Force Fake-IPv6 for AAAA (default: only when /etc/knot-resolver/ipv6-mode is 'c')")
    p.add_argument("--fake6-cidr",default="fd00:30::/64",help="Fake IPv6 CIDR (default: fd00:30::/64)")
    p.add_argument("--log",default="truncated,error",help="Log hooks to enable (default: +truncated,+error,-request,-reply,-recv,-send,-data)")
    p.add_argument("--log-prefix",action="store_true",default=False,help="Log prefix (timestamp/handler/resolver) (default: False)")
    args=p.parse_args()
    args.dns,_,args.dns_port=args.dns.partition(":")
    args.dns_port=int(args.dns_port or 53)
    args.proxy,_,args.proxy_port=args.proxy.partition(":")
    args.proxy_port=int(args.proxy_port or 53)
    args.warp,_,args.warp_port=args.warp.partition(":")
    args.warp_port=int(args.warp_port or 53)
    TCPServer.request_queue_size=128
    print("Starting...")
    resolver=ProxyResolver(args.dns,args.dns_port,args.dns_timeout,args.fake_cidr,args.dns_ttl,args.expire,args.fake6_cidr,args.ipv6)
    logger=DNSLogger(args.log,prefix=args.log_prefix)
    def start_server(address,port,tcp=False):
        server=DNSServer(resolver,port=port,address=address,tcp=tcp,logger=logger,handler=DNSHandler)
        server.server.warp=address==args.warp
        server.start_thread()
        return server
    udp_server=start_server(args.proxy,args.proxy_port)
    tcp_server=start_server(args.proxy,args.proxy_port,tcp=True)
    print(f"Started proxy resolver {args.proxy}:{args.proxy_port} -> {args.dns}:{args.dns_port}")
    udp_warp=start_server(args.warp,args.warp_port)
    tcp_warp=start_server(args.warp,args.warp_port,tcp=True)
    print(f"Started WARP resolver {args.warp}:{args.warp_port} -> {args.dns}:{args.dns_port}")
    while all(s.thread.is_alive() for s in (udp_server,tcp_server,udp_warp,tcp_warp)):
        time.sleep(1)
    print("Restarting: A server thread died")
    os._exit(3)
