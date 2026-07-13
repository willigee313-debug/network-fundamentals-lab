# 07장. VXLAN 기초 — L2 over L3: "같은 네트워크"조차 만들어낼 수 있다

> 01장의 결론은 "같은 네트워크는 케이블이 아니라 IP+마스크가 정한다"였다. 이 장은 그걸
> 한 단계 밀어붙인다: **이더넷 프레임을 UDP에 싸서 라우터 너머로 보내면, "같은 L2 세그먼트"
> 자체를 만들어낼 수 있다.** 이것이 VXLAN — 컨테이너 오버레이 네트워크(CNI)들이 쓰는 바로 그 원리다.

## 0. 학습 목표
- **캡슐화(encapsulation)**: 이더넷 프레임이 UDP/IP 안에 실려 라우팅되는 것을 tcpdump로
- **VTEP**(터널 끝점)과 **VNI**(24bit 터널 식별자 = 대형 VLAN 태그)의 역할
- 대표 고장: **VNI 불일치** — "outer는 도착하는데 조용히 소실"
- 오버레이의 **50바이트 세금** (13장의 예고)

---

## 1. 개념

### 1-1. 구조
```
[ 원래 프레임: EthII | IP 192.168.100.x | payload ]      ← 오버레이 (L2 세계)
          ↓ VTEP가 감싼다
[ EthII | IP 10.7.x | UDP :4789 | VXLAN(VNI) | 원래 프레임 ]  ← underlay (L3 세계를 여행)
```
- **VTEP**: 감싸고(encap) 푸는(decap) 끝점. **VNI**: 어느 가상 네트워크의 프레임인지 표식(24bit = 1,677만 개 — VLAN 4096개의 한계를 넘는 대형판).
- 중간 라우터(r1)는 그냥 **UDP 패킷을 라우팅**할 뿐, 안에 이더넷이 들었는지 모른다.
- ARP·브로드캐스트도 캡슐에 실려 넘어간다 → 오버레이 위 호스트들은 서로 "같은 L2"라고 믿는다.
- (Calico/Flannel 등 CNI의 VXLAN 모드가 노드 사이에 정확히 이 구조를 만든다 — 원리는 이 장이 전부다.)

### 1-2. 이 랩의 형태
```
   vtep1 ────────── r1 ────────── vtep2
 10.7.1.1/30    (underlay 라우터)   10.7.2.1/30
     └─ vxlan100: 192.168.100.1 ─ ─ ─ 192.168.100.2 ┘   ← "같은 서브넷"(오버레이)
```
**장전된 고장**: vtep2의 VNI가 **200** (vtep1은 100).

## 2. 실습 준비
```sh
./clab.sh deploy 07-vxlan-overlay/07-vxlan-overlay.clab.yml
```
> 노드: `clab-07-vxlan-overlay-<vtep1|r1|vtep2>` · P2P 유니캐스트 VTEP(`remote` 지정) 사용

---

## 3. 실습 A — 증상: underlay는 되는데 overlay만 죽는다

```sh
docker exec clab-07-vxlan-overlay-vtep1 ping -c1 10.7.2.1        # underlay (터널 끝점끼리)
docker exec clab-07-vxlan-overlay-vtep1 ping -c2 192.168.100.2   # overlay
```
✅ 실측:
```
underlay → rtt 0.068ms (정상)
overlay  → 2 packets transmitted, 0 received, 100% packet loss   ← 조용한 소실
```

## 4. 실습 B — 결정적 관찰: outer는 도착하고 있다

```sh
docker exec clab-07-vxlan-overlay-vtep2 tcpdump -nli eth1 'udp port 4789 and src host 10.7.1.1'
# (다른 터미널에서 overlay ping)
```
✅ 실측 — vtep2의 문 앞까지는 왔다:
```
IP 10.7.1.1.49159 > 10.7.2.1.4789: VXLAN, flags [I], vni 100     ← vni 100 이 도착!
ARP, Request who-has 192.168.100.2 tell 192.168.100.1            ← 안에는 ARP가 들어 있다
```
**해설**: 05장 블랙홀과 닮았지만 다르다 — **패킷은 목적지까지 도달**했다. tcpdump가 outer와
inner를 함께 해독해 준다: "vni 100의 캡슐 안에 ARP". 그런데 vtep2는 응답하지 않는다. 왜?

## 5. 실습 C — 원인: 터널 ID가 다르다

```sh
docker exec clab-07-vxlan-overlay-vtep1 ip -d link show vxlan100 | grep "vxlan id"
docker exec clab-07-vxlan-overlay-vtep2 ip -d link show vxlan100 | grep "vxlan id"
```
✅ 실측:
```
vtep1: vxlan id 100
vtep2: vxlan id 200      ← 불일치!
```
**해설**: vtep2의 커널은 "vni 200 프레임만 내 것"이라 여긴다. **vni 100 캡슐은 도착하고도
디캡 단계에서 조용히 버려진다** — 에러도, ICMP도 없다. 03장의 VLAN 태그 불일치와 완전히 같은
운명(태그가 달라 같은 편인 줄 모름)의 오버레이판.

## 6. 수정 (fix.sh — "한 줄" 예외: VNI는 재생성만 가능)
```sh
docker exec clab-07-vxlan-overlay-vtep2 bash -c "ip link del vxlan100 && \
  ip link add vxlan100 type vxlan id 100 local 10.7.2.1 remote 10.7.1.1 dstport 4789 dev eth1 && \
  ip addr add 192.168.100.2/24 dev vxlan100 && ip link set vxlan100 up"
```
✅ **성공 판정** (실측): overlay ping `rtt 0.162ms`. 그리고 **중간 라우터 r1에서** 캡처하면:
```
10.7.1.1.49159 > 10.7.2.1.4789: VXLAN vni 100 / ARP Request who-has 192.168.100.2 ...
10.7.2.1.49159 > 10.7.1.1.4789: VXLAN vni 100 / ARP Reply 192.168.100.2 is-at ba:0e:...
```
**ARP가 라우터를 건너다닌다** — 01장에서 "브로드캐스트는 같은 세그먼트 안"이라 배웠는데,
캡슐화가 그 "세그먼트"를 L3 위에 새로 그렸기 때문이다.

## 7. 관찰 보너스 — 오버레이의 세금 (13장 예고)
```sh
docker exec clab-07-vxlan-overlay-vtep1 ip link show vxlan100 | grep -o "mtu [0-9]*"
# mtu 1450        (실측 — underlay 1500인데?)
```
커널이 **스스로 50을 뺐다**: outer Eth 14 + outer IP 20 + UDP 8 + VXLAN 8 = **50바이트**가
캡슐 비용이기 때문. 이 자동 계산을 사람이 무시하면(수동 MTU 강제, 중간 경로의 더 낮은 MTU 등)
무슨 일이 나는지 → **13장**.

---

## 8. 정리 / 교훈
- **"같은 L2"는 케이블(01장)도, 태그(03장)도 아니고, 궁극적으로는 encap이 정의할 수 있다.**
- VXLAN 진단의 축: ① underlay 먼저 (터널 끝점끼리 ping) ② outer 도착 여부 (`udp port 4789`)
  ③ **양쪽 VNI/포트/remote 대조** (`ip -d link show`).
- "outer는 오는데 무응답" = decap 쪽 설정(VNI/포트) 불일치의 지문. 조용히 죽는다.
- 오버레이는 50B의 세금을 낸다 — MTU 설계 없이는 반드시 청구서가 날아온다(13장).

## 9. 치트시트
| 목적 | 명령 |
|---|---|
| VXLAN 상세(VNI/remote/포트) | `ip -d link show vxlan100` |
| outer 캡처 | `tcpdump -nli eth1 udp port 4789` |
| 터널 FDB | `bridge fdb show dev vxlan100` |
| VXLAN 생성 | `ip link add vxlan100 type vxlan id <VNI> local <IP> remote <IP> dstport 4789 dev eth1` |

## 10. 랩 정리
```sh
./clab.sh destroy 07-vxlan-overlay/07-vxlan-overlay.clab.yml
```

---
### 다음 장 예고
이 터널 위에서 **1500바이트를 그대로 밀어 넣으면** 무슨 일이 벌어질까 — 오버레이 MTU의
청구서 → **13장**.
