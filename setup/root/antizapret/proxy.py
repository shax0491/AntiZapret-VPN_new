#!/usr/bin/env -S python3 -u
# -*- coding: utf-8 -*-

import re,subprocess,time,argparse,threading,os
from ipaddress import IPv4Network,IPv6Network
from dnslib import DNSRecord,RCODE,QTYPE,A,AAAA
from dnslib.server import DNSServer,DNSHandler,BaseResolver,DNSLogger,TCPServer

class ProxyResolver(BaseResolver):
    def __init__(self,dns,dns_port,dns_timeout,fake_cidr,dns_ttl,expire,fake_cidr6="",table="antizapret"):
        self._env=os.environ.copy()
        self.table=table
        self.ip_pool={str(x) for x in IPv4Network(fake_cidr).hosts()}
        self.ip_map={}
        # Loading existing fake IP mapping
        mapping=subprocess.run(["/usr/sbin/nft","list","map","ip",self.table,"mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=self._env)
        if mapping.returncode:
            subprocess.run(["/usr/sbin/nft","add","table","ip",self.table],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","map","ip",self.table,"mapping","{","type","ipv4_addr",":","ipv4_addr",";","size","131072",";","}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        warp_ips=set()
        warp=subprocess.run(["/usr/sbin/nft","list","set","ip",self.table,"warp"],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=self._env)
        if warp.returncode:
            subprocess.run(["/usr/sbin/nft","add","table","ip",self.table],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","set","ip",self.table,"warp","{","type","ipv4_addr",";","size","131072",";","}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        else:
            warp_ips.update(re.findall(r"\d+\.\d+\.\d+\.\d+",warp.stdout))
        now=time.time()
        for fake_ip,real_ip in re.findall(r"(\d+\.\d+\.\d+\.\d+)\s*:\s*(\d+\.\d+\.\d+\.\d+)",mapping.stdout):
            if not self.mapping_ip(real_ip,fake_ip,now,fake_ip in warp_ips):
                print("Restarting: Invalid loaded fake IP mapping")
                try:
                    subprocess.run(["/usr/sbin/nft","flush","map","ip",self.table,"mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                    subprocess.run(["/usr/sbin/nft","flush","set","ip",self.table,"warp"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                finally:
                    os._exit(1)
        print(f"Loaded: {len(self.ip_map)} fake IPs")
        # IPv6 (необязательно): фиктивные адреса из fake_cidr6 -> настоящие, карта ip6 <table> mapping6; после перезапуска карта пустая (TTL короткий)
        self.pool6=IPv6Network(fake_cidr6) if fake_cidr6 else None
        self.ip_map6={}
        self.next6=1
        self.free6=[]
        if self.pool6:
            nft=lambda *a,check=False: subprocess.run(["/usr/sbin/nft",*a],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=check,env=self._env)
            nft("add","table","ip6",self.table)
            nft("add","map","ip6",self.table,"mapping6","{","type","ipv6_addr",":","ipv6_addr",";","size","131072",";","}",check=True)
            nft("flush","map","ip6",self.table,"mapping6",check=True)
        self.dns=dns
        self.dns_port=dns_port
        self.dns_timeout=dns_timeout
        self.dns_ttl=dns_ttl
        self.expire=expire
        self.lock=threading.Lock()
        # Start thread for expire fake IP mapping
        threading.Thread(target=self.expire_mapping_worker,daemon=True).start()

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
                subprocess.run(["/usr/sbin/nft","add","element","ip",self.table,"warp","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            subprocess.run(["/usr/sbin/nft","add","element","ip",self.table,"mapping","{",fake_ip,":",real_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        except Exception as e:
            print(f"Error: {e} (real_ip={real_ip} fake_ip={fake_ip} warp={warp})")
            with self.lock:
                del self.ip_map[(real_ip,warp)]
                self.ip_pool.add(fake_ip)
            if warp:
                subprocess.run(["/usr/sbin/nft","delete","element","ip",self.table,"warp","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            subprocess.run(["/usr/sbin/nft","delete","element","ip",self.table,"mapping","{",fake_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,env=self._env)
            return None
        #print(f"Mapping: {fake_ip} to {real_ip} warp={warp}")
        return fake_ip

    def get_fake_ip6(self,real_ip,now):
        with self.lock:
            entry=self.ip_map6.get(real_ip)
            if entry:
                entry["used"]=now
                return entry["fake_ip"]
            if self.free6:
                fake_ip=self.free6.pop()
            elif self.next6<self.pool6.num_addresses-1:
                fake_ip=str(self.pool6[self.next6])
                self.next6+=1
            else:
                print("Error: No fake IPv6 left in pool")
                return None
            self.ip_map6[real_ip]={"fake_ip": fake_ip,"used": now}
        try:
            subprocess.run(["/usr/sbin/nft","add","element","ip6",self.table,"mapping6","{",fake_ip,":",real_ip,"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        except Exception as e:
            print(f"Error: {e} (real_ip6={real_ip} fake_ip6={fake_ip})")
            with self.lock:
                del self.ip_map6[real_ip]
                self.free6.append(fake_ip)
            return None
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
            except Exception as e:
                print(f"Error: {e}")
                print("Restarting: Expire fake IP mapping failed")
                try:
                    subprocess.run(["/usr/sbin/nft","flush","map","ip",self.table,"mapping"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                    subprocess.run(["/usr/sbin/nft","flush","set","ip",self.table,"warp"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
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
        if self.pool6:
            with self.lock:
                now=time.time()
                exp6=[(r,e["fake_ip"]) for r,e in self.ip_map6.items() if now-e["used"]>self.expire]
                for r,f in exp6:
                    del self.ip_map6[r]
                    self.free6.append(f)
            if exp6:
                subprocess.run(["/usr/sbin/nft","delete","element","ip6",self.table,"mapping6","{",", ".join(f for _,f in exp6),"}"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                print(f"Expired: {len(exp6)} fake IPv6")
        if expired:
            rules=[]
            if warp_ips:
                rules.append(f"delete element ip {self.table} warp "+"{ "+", ".join(warp_ips)+" }")
            rules.append(f"delete element ip {self.table} mapping "+"{ "+", ".join(mapping_ips)+" }")
            subprocess.run(["/usr/sbin/nft","-f","-"],input="\n".join(rules).encode(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            print(f"Expired: {len(expired)} fake IPs")

    def resolve(self,request,handler):
        warp=handler.server.warp
        try:
            if handler.protocol=="udp":
                data=request.send(self.dns,self.dns_port,timeout=self.dns_timeout)
            else:
                data=request.send(self.dns,self.dns_port,tcp=True,timeout=self.dns_timeout)
            reply=DNSRecord.parse(data)
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
            elif request.q.qtype==QTYPE.AAAA and self.pool6 and not warp:
                now=time.time()
                for record in reply.rr:
                    record.ttl=self.dns_ttl
                    if record.rtype!=QTYPE.AAAA:
                        continue
                    fake_ip=self.get_fake_ip6(str(record.rdata),now)
                    if not fake_ip:
                        reply=request.reply()
                        reply.header.rcode=RCODE.SERVFAIL
                        return reply
                    record.rdata=AAAA(fake_ip)
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
    p.add_argument("--fake-cidr6",default="",help="Fake IPv6 CIDR for AAAA (default: empty = IPv6 disabled)")
    p.add_argument("--table",default="antizapret",help="nft table name for ip/ip6 maps (default: antizapret)")
    p.add_argument("--dns-ttl",type=int,default=300,help="TTL in seconds for A records (default: 300)")
    p.add_argument("--expire",type=int,default=3600,help="Seconds of inactivity before fake IP is removed (default: 3600)")
    p.add_argument("--proxy",default="127.4.4.4:53",help="Local Fake IP proxy listen address:port (default: 127.4.4.4:53)")
    p.add_argument("--warp",default="127.5.5.5:53",help="Local WARP proxy listen address:port (default: 127.5.5.5:53)")
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
    resolver=ProxyResolver(args.dns,args.dns_port,args.dns_timeout,args.fake_cidr,args.dns_ttl,args.expire,args.fake_cidr6,args.table)
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
