#!/bin/bash
# 전장 스윕(회귀 테스트) — 모든 랩을 deploy→고장 확인→수정→판정→destroy 순으로 실행.
# 사용: bash tools/sweep.sh   (저장소 루트 기준, Linux+docker. 소요 ~25-35분)
# 결과: /tmp/sweep-results.txt (PASS/FAIL 한 줄씩), 종료 마커 /tmp/sweep-done
cd "$(dirname "$0")/.."
R=/tmp/sweep-results.txt; : > "$R"; rm -f /tmp/sweep-done
say(){ echo "$(date +%H:%M:%S) $*" >> "$R"; }
dep(){ ./clab.sh deploy "$1" >/dev/null 2>&1; }
des(){ ./clab.sh destroy "$1" >/dev/null 2>&1; }
loss(){ docker exec "$1" ping -c2 -W2 $3 "$2" 2>&1 | grep -o '[0-9]*% packet loss' | head -1; }

# ── 00 온램프 ─────────────────────────────────────────────
dep 00-onramp/playground.clab.yml
[ "$(loss clab-00-onramp-h1 10.0.0.2)" = "0% packet loss" ] && say "PASS 00 ping 왕복" || say "FAIL 00"
des 00-onramp/playground.clab.yml

# ── 01 ARP ───────────────────────────────────────────────
dep 01-l2-arp/01-l2-arp.clab.yml
P=clab-01-l2-arp; ok=1
[ "$(loss $P-h1 10.10.10.2)" = "0% packet loss" ] || ok=0
docker exec $P-h2 bash -c "ip addr flush dev eth1 && ip addr add 10.10.20.2/24 dev eth1"
docker exec $P-h1 ping -c1 -W1 10.10.20.2 2>&1 | grep -q "Network unreachable" || ok=0
docker exec $P-h2 bash -c "ip addr flush dev eth1 && ip addr add 10.10.10.2/24 dev eth1"
docker exec $P-h3 ip addr add 10.10.10.2/24 dev eth1
MACS=$(docker exec $P-h1 arping -c3 -I eth1 10.10.10.2 2>/dev/null | grep -oE '\[[0-9A-F:]+\]' | sort -u | wc -l)
[ "$MACS" -eq 2 ] || ok=0
[ $ok = 1 ] && say "PASS 01 정상/서브넷불일치/중복IP(MAC ${MACS}종)" || say "FAIL 01"
des 01-l2-arp/01-l2-arp.clab.yml

# ── 02 루프/스톰 ─────────────────────────────────────────
dep 02-bcast-loop/02-bcast-loop.clab.yml
P=clab-02-bcast-loop; ok=1
[ "$(loss $P-h1 10.2.0.2)" = "0% packet loss" ] || ok=0
R0=$(docker exec $P-h2 cat /sys/class/net/eth1/statistics/rx_packets)
docker exec $P-sw1 ip link set eth3 up
docker exec $P-h1 bash -c "ip neigh flush all; ping -c2 -W1 10.2.0.2" >/dev/null 2>&1
sleep 2; R1=$(docker exec $P-h2 cat /sys/class/net/eth1/statistics/rx_packets)
[ $((R1-R0)) -gt 1000 ] || ok=0          # 스톰 점화 확인
docker exec $P-sw1 ip link set br0 type bridge stp_state 1
docker exec $P-sw2 ip link set br0 type bridge stp_state 1
sleep 40
BLK=$(docker exec $P-sw1 bash -c "bridge -d link show" 2>/dev/null | grep -c "state blocking")
BLK2=$(docker exec $P-sw2 bash -c "bridge -d link show" 2>/dev/null | grep -c "state blocking")
[ $((BLK+BLK2)) -eq 1 ] || ok=0
[ "$(loss $P-h1 10.2.0.2)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 02 스톰(+$((R1-R0))pkt/2s)→STP blocking→회복" || say "FAIL 02"
des 02-bcast-loop/02-bcast-loop.clab.yml

# ── 03 VLAN ──────────────────────────────────────────────
dep 03-vlan-trunk/03-vlan-trunk.clab.yml
P=clab-03-vlan-trunk; ok=1
[ "$(loss $P-h1 10.3.10.2)" = "100% packet loss" ] || ok=0
./03-vlan-trunk/fix.sh >/dev/null
docker exec $P-h1 ping -c3 -W2 10.3.10.2 2>&1 | grep -q " 0% packet loss" || ok=0
[ "$(loss $P-h1 10.3.10.3)" = "100% packet loss" ] || ok=0    # 격리 유지
[ $ok = 1 ] && say "PASS 03 트렁크VID→수정→격리유지" || say "FAIL 03"
des 03-vlan-trunk/03-vlan-trunk.clab.yml

# ── 04 라우팅 ────────────────────────────────────────────
dep 04-l3-routing/04-l3-routing.clab.yml
P=clab-04-l3-routing; ok=1
[ "$(loss $P-h1 10.4.2.10)" = "100% packet loss" ] || ok=0
docker exec $P-r2 ip route get 10.4.1.10 2>&1 | grep -q unreachable || ok=0
./04-l3-routing/fix.sh >/dev/null
[ "$(loss $P-h1 10.4.2.10)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 04 리턴누락→수정" || say "FAIL 04"
des 04-l3-routing/04-l3-routing.clab.yml

# ── 05 LPM ───────────────────────────────────────────────
dep 05-lpm-blackhole/05-lpm-blackhole.clab.yml
P=clab-05-lpm-blackhole; ok=1
[ "$(loss $P-h1 10.5.2.11)" = "0% packet loss" ] || ok=0
[ "$(loss $P-h1 10.5.2.10)" = "100% packet loss" ] || ok=0
./05-lpm-blackhole/fix.sh >/dev/null
[ "$(loss $P-h1 10.5.2.10)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 05 옆IP대조→blackhole제거" || say "FAIL 05"
des 05-lpm-blackhole/05-lpm-blackhole.clab.yml

# ── 06 TTL 루프 ──────────────────────────────────────────
dep 06-ttl-loop/06-ttl-loop.clab.yml
P=clab-06-ttl-loop; ok=1
docker exec $P-h1 ping -c2 -W2 198.51.100.1 2>&1 | grep -q "Time to live exceeded" || ok=0
./06-ttl-loop/fix.sh >/dev/null
docker exec $P-h1 ping -c1 -W2 198.51.100.1 2>&1 | grep -q "Unreachable" || ok=0
[ $ok = 1 ] && say "PASS 06 TTL루프→명시거절" || say "FAIL 06"
des 06-ttl-loop/06-ttl-loop.clab.yml

# ── 07 VXLAN ─────────────────────────────────────────────
dep 07-vxlan-overlay/07-vxlan-overlay.clab.yml
P=clab-07-vxlan-overlay; ok=1
[ "$(loss $P-vtep1 10.7.2.1)" = "0% packet loss" ] || ok=0            # underlay
[ "$(loss $P-vtep1 192.168.100.2)" = "100% packet loss" ] || ok=0     # overlay(VNI 불일치)
./07-vxlan-overlay/fix.sh >/dev/null
[ "$(loss $P-vtep1 192.168.100.2)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 07 VNI불일치→재생성" || say "FAIL 07"
des 07-vxlan-overlay/07-vxlan-overlay.clab.yml

# ── 08 3-way ─────────────────────────────────────────────
dep 08-tcp-3way/08-tcp-3way.clab.yml
P=clab-08-tcp-3way; ok=1
probe(){ docker exec $P-cli timeout 8 nc -zv -w 5 10.8.2.10 $1 2>&1 | grep -oE 'succeeded|refused|timed out'; }
[ "$(probe 6060)" = "succeeded" ] || ok=0
[ "$(probe 8080)" = "timed out" ] || ok=0
[ "$(probe 9090)" = "refused" ]   || ok=0
[ "$(probe 7070)" = "refused" ]   || ok=0
./08-tcp-3way/fix.sh >/dev/null; sleep 1
for p in 6060 8080 9090 7070; do [ "$(probe $p)" = "succeeded" ] || ok=0; done
[ $ok = 1 ] && say "PASS 08 4포트4증상→전부회복" || say "FAIL 08"
des 08-tcp-3way/08-tcp-3way.clab.yml

# ── 09 conntrack ─────────────────────────────────────────
dep 09-conntrack/09-conntrack.clab.yml
P=clab-09-conntrack; ok=1
docker exec -d $P-cli bash -c "sleep 120 | nc 10.9.2.10 7777"; sleep 2
docker exec $P-nat bash -c "conntrack -L 2>/dev/null | grep -q 7777" || ok=0     # 엔트리 존재
sleep 35
[ "$(docker exec $P-nat bash -c 'conntrack -L 2>/dev/null | grep -c 7777')" = "0" ] || ok=0   # idle 만료
docker exec -d $P-cli bash -c "sleep 60 | nc 10.9.2.10 7777"
docker exec -d $P-cli bash -c "sleep 60 | nc 10.9.2.10 7777"; sleep 2
docker exec $P-cli timeout 7 nc -zv -w 4 10.9.2.10 7777 2>&1 | grep -q "timed out" || ok=0    # 고갈
./09-conntrack/fix.sh >/dev/null
docker exec $P-cli nc -zv -w 4 10.9.2.10 7777 2>&1 | grep -q succeeded || ok=0
[ $ok = 1 ] && say "PASS 09 idle만료+포트고갈→수정" || say "FAIL 09"
des 09-conntrack/09-conntrack.clab.yml

# ── 10 NAT 기본 ──────────────────────────────────────────
dep 10-nat-basics/10-nat-basics.clab.yml
P=clab-10-nat-basics; ok=1
docker exec $P-cli timeout 7 nc -zv -w 4 10.10.2.10 80 2>&1 | grep -q "timed out" || ok=0
docker exec $P-srv ip route get 10.10.1.10 2>&1 | grep -q unreachable || ok=0
./10-nat-basics/fix.sh >/dev/null
[ "$(docker exec $P-cli bash -c 'echo hi | timeout 3 nc 10.10.2.10 80')" = "pong-from-srv" ] || ok=0
[ "$(docker exec $P-ext bash -c 'echo hi | timeout 3 nc 10.10.3.1 8080')" = "pong-from-cli" ] || ok=0
[ $ok = 1 ] && say "PASS 10 SNAT필연성+DNAT" || say "FAIL 10"
des 10-nat-basics/10-nat-basics.clab.yml

# ── 11 대칭성 ────────────────────────────────────────────
dep 11-symmetry-nat/11-symmetry-nat.clab.yml
P=clab-11-symmetry-nat; ok=1
docker exec -d $P-cli bash -c "timeout 10 tcpdump -nli eth1 -c 3 'tcp port 443' > /tmp/b.txt 2>/dev/null"; sleep 1
docker exec $P-cli timeout 8 nc -zv -w 5 10.11.2.10 443 2>&1 | grep -q "timed out" || ok=0
sleep 1; docker exec $P-cli grep -q "10.11.4.1.443" /tmp/b.txt || ok=0     # SYN-ACK 소스 = nat
./11-symmetry-nat/fix.sh >/dev/null
[ "$(docker exec $P-cli bash -c 'echo hi | timeout 3 nc 10.11.2.10 443')" = "pong" ] || ok=0
[ $ok = 1 ] && say "PASS 11 SYN-ACK←nat 재현→대칭수정" || say "FAIL 11"
des 11-symmetry-nat/11-symmetry-nat.clab.yml

# ── 12 MTU/PMTUD ─────────────────────────────────────────
dep 12-mtu-pmtud/12-mtu-pmtud.clab.yml
P=clab-12-mtu-pmtud; ok=1
[ "$(loss $P-h1 10.12.2.10 '-s 100')" = "0% packet loss" ] || ok=0
docker exec $P-h1 ping -M do -c2 -W2 -s 1472 10.12.2.10 2>&1 | grep -q "100% packet loss" || ok=0
./12-mtu-pmtud/fix.sh >/dev/null
docker exec $P-h1 ping -M do -c2 -W2 -s 1472 10.12.2.10 2>&1 | grep -q "mtu = 1400" || ok=0
docker exec $P-h1 ip route get 10.12.2.10 | grep -q "mtu 1400" || ok=0
[ $ok = 1 ] && say "PASS 12 블랙홀→frag-needed 통보+캐시" || say "FAIL 12"
des 12-mtu-pmtud/12-mtu-pmtud.clab.yml

# ── 13 터널 MTU ──────────────────────────────────────────
dep 13-tunnel-mtu/13-tunnel-mtu.clab.yml
P=clab-13-tunnel-mtu; ok=1
docker exec $P-vtep1 ip link show vxlan100 | grep -q "mtu 1450" || ok=0
docker exec $P-vtep2 ip link show vxlan100 | grep -q "mtu 1350" || ok=0
docker exec $P-vtep1 ping -M dont -c2 -W2 -s 1300 192.168.100.2 2>&1 | grep -q " 0% packet loss" || ok=0
docker exec $P-vtep1 ping -M dont -c2 -W2 -s 1400 192.168.100.2 2>&1 | grep -q "100% packet loss" || ok=0
./13-tunnel-mtu/fix.sh >/dev/null
docker exec $P-vtep1 ping -M dont -c3 -W2 -s 1400 192.168.100.2 2>&1 | grep -q " 0% packet loss" || ok=0
[ $ok = 1 ] && say "PASS 13 자동MTU비대칭+조각거부→경로기준수정" || say "FAIL 13"
des 13-tunnel-mtu/13-tunnel-mtu.clab.yml

# ── 14 DNS ───────────────────────────────────────────────
dep 14-dns/14-dns.clab.yml
P=clab-14-dns; ok=1; sleep 3
[ "$(docker exec $P-cli dig +short app.lab)" = "10.14.0.101" ] || ok=0
docker exec $P-cli curl -s -m 3 http://app.lab/ >/dev/null 2>&1 && ok=0   # 죽은 서버여야 함
./14-dns/fix.sh >/dev/null; sleep 2
[ "$(docker exec $P-cli dig +short app.lab)" = "10.14.0.102" ] || ok=0
[ "$(docker exec $P-cli curl -s -m 3 http://app.lab/)" = "pong-from-srv2" ] || ok=0
[ $ok = 1 ] && say "PASS 14 스테일→플러시" || say "FAIL 14"
des 14-dns/14-dns.clab.yml

# ── 15 ICMP 차단 ─────────────────────────────────────────
dep 15-icmp-blocked/15-icmp-blocked.clab.yml
P=clab-15-icmp-blocked; ok=1
[ "$(loss $P-h1 10.15.2.10)" = "100% packet loss" ] || ok=0
[ "$(docker exec $P-h1 curl -s -m 3 http://10.15.2.10/)" = "alive" ] || ok=0   # 오판 조합
./15-icmp-blocked/fix.sh >/dev/null
[ "$(loss $P-h1 10.15.2.10)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 15 ping죽음+서비스생존→선별허용" || say "FAIL 15"
des 15-icmp-blocked/15-icmp-blocked.clab.yml

# ── 16 헤어핀 ────────────────────────────────────────────
dep 16-nat-hairpin/16-nat-hairpin.clab.yml
P=clab-16-nat-hairpin; ok=1
docker exec $P-cli curl -s -m 4 http://10.16.99.1:8080/ >/dev/null 2>&1 && ok=0
./16-nat-hairpin/fix.sh >/dev/null
[ "$(docker exec $P-cli curl -s -m 4 http://10.16.99.1:8080/)" = "pong-hairpin" ] || ok=0
[ $ok = 1 ] && say "PASS 16 헤어핀→SNAT" || say "FAIL 16"
des 16-nat-hairpin/16-nat-hairpin.clab.yml

# ── 17a OSPF ─────────────────────────────────────────────
dep 17-dynamic-routing/ospf.clab.yml
P=clab-17-ospf; ok=1; sleep 12
[ "$(docker exec $P-r1 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -cE '^[0-9]')" = "0" ] || ok=0
./17-dynamic-routing/fix.sh >/dev/null 2>&1; sleep 40
docker exec $P-r1 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -q "Full" || ok=0
sleep 15
[ "$(loss $P-h1 10.17.2.10)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 17a area불일치→Full→왕복" || say "FAIL 17a"
des 17-dynamic-routing/ospf.clab.yml

# ── 17b BGP ──────────────────────────────────────────────
dep 17-dynamic-routing/bgp.clab.yml
P=clab-17-bgp; ok=1; sleep 30
docker exec $P-r2 vtysh -c 'show ip bgp summary' 2>/dev/null | grep 10.17.0.1 | awk '{print $(NF-2)}' | grep -q "^0$" || ok=0
./17-dynamic-routing/fix.sh >/dev/null 2>&1; sleep 15
docker exec $P-r2 vtysh -c 'show ip bgp summary' 2>/dev/null | grep 10.17.0.1 | awk '{print $(NF-2)}' | grep -q "^1$" || ok=0
[ "$(loss $P-h1 10.17.2.10)" = "0% packet loss" ] || ok=0
[ $ok = 1 ] && say "PASS 17b PfxRcd 0→1→왕복" || say "FAIL 17b"
des 17-dynamic-routing/bgp.clab.yml

# ── CP-1 ─────────────────────────────────────────────────
dep checkpoints/cp1/scenario.clab.yml
P=clab-cp1; ok=1
docker exec $P-h1 curl -s -m 3 http://10.91.2.10/ >/dev/null 2>&1 && ok=0
docker exec $P-r1 ip route del blackhole 10.91.2.10/32
docker exec $P-h1 curl -s -m 3 http://10.91.2.10/ >/dev/null 2>&1 && ok=0   # 1차 수정 후에도 실패해야(이중 고장)
docker exec $P-r2 ip route replace 10.91.1.0/24 via 10.91.0.1
[ "$(docker exec $P-h1 curl -s -m 3 http://10.91.2.10/)" = "cp1-ok" ] || ok=0
[ $ok = 1 ] && say "PASS CP1 이중고장 2단계 아크" || say "FAIL CP1"
des checkpoints/cp1/scenario.clab.yml

# ── CP-2 ─────────────────────────────────────────────────
dep checkpoints/cp2/scenario.clab.yml
P=clab-cp2; ok=1
docker exec $P-cli timeout 7 nc -zv -w 4 10.92.2.10 443 2>&1 | grep -q "timed out" || ok=0
docker exec $P-srtr ip route replace 10.92.1.0/24 via 10.92.0.1
[ "$(docker exec $P-cli bash -c 'echo hi | timeout 3 nc 10.92.2.10 443')" = "cp2-ok" ] || ok=0
[ $ok = 1 ] && say "PASS CP2 비대칭+미끼→한줄수정" || say "FAIL CP2"
des checkpoints/cp2/scenario.clab.yml

say "SWEEP_COMPLETE $(grep -c '^..:..:.. PASS' $R)/21 PASS"
touch /tmp/sweep-done
