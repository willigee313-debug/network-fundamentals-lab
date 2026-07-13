# 01장. L2 인접성과 ARP — "같은 네트워크"란 무엇인가

> 신입 교육용. 이 장은 **가장 아래(2계층)** 부터 시작한다. IP·라우팅·방화벽을 배우기 전에,
> "**같은 네트워크 안에서 두 기기가 어떻게 서로를 찾아 통신하는가**"를 눈으로 확인한다.

## 0. 학습 목표
이 장을 마치면 다음을 설명/재현할 수 있다.
- MAC 주소와 IP 주소가 각각 무엇이고 왜 둘 다 필요한지
- "같은 네트워크(=같은 서브넷=같은 브로드캐스트 도메인)"의 의미
- **ARP**가 IP를 MAC으로 바꾸는 과정 (패킷으로 직접 관찰)
- **서브넷 마스크**가 "직접 통신 vs 라우터 경유"를 어떻게 결정하는지
- 대표 장애 2가지: **서브넷 불일치**, **중복 IP(ARP 충돌)**

---

## 1. 개념

### 1-1. MAC 주소와 IP 주소
- **IP 주소**(L3): 논리 주소. 설정으로 부여·변경하며, 네트워크 간 라우팅의 기준. (예: `10.10.10.2`)
- **MAC 주소**(L2): NIC마다 고유한 물리 주소. 같은 링크(세그먼트) 안에서 프레임을 전달하는 기준. (예: `aa:bb:cc:11:22:33`)
- 이더넷 프레임은 **목적지 MAC**으로 전달된다. 보통 목적지 IP만 알고 있으므로, 프레임을 만들려면 **"그 IP의 MAC"** 을 먼저 알아내야 한다 → 이 역할이 **ARP**.

### 1-2. 브로드캐스트 도메인과 "같은 네트워크"
- 하나의 스위치(=브리지)에 연결된 포트들은 하나의 **브로드캐스트 도메인**을 공유한다(브로드캐스트·ARP가 서로에게 도달).
- 목적지가 **같은 서브넷**이면 ARP로 MAC을 구해 **직접 전달**, **다른 서브넷**이면 **라우터(게이트웨이)** 로 넘긴다.

### 1-3. ARP 동작 (IP → MAC)
h1이 `10.10.10.2`로 보내려 할 때:
1. h1 → 브로드캐스트: `who-has 10.10.10.2 tell 10.10.10.1`
2. 해당 IP를 가진 h2만 유니캐스트 응답: `10.10.10.2 is-at aa:bb:cc:…`
3. h1은 IP↔MAC을 **ARP 캐시(`ip neigh`)** 에 저장하고, 이후 프레임을 그 MAC으로 전달한다.

### 1-4. 서브넷 마스크의 역할
- `10.10.10.1/24` 에서 `/24`가 마스크. 목적지 IP를 **자신의 IP/마스크로 계산**해 같은 네트워크 주소면 "같은 서브넷"으로 판단한다.
- 같은 서브넷 → ARP로 직접 / 다른 서브넷 → 게이트웨이로.
- **핵심**: "같은 네트워크"는 **물리 케이블이 아니라 IP+마스크가 결정한다.** (실습 B에서 확인)

---

## 2. 토폴로지
```
  10.10.10.1        10.10.10.2        10.10.10.3
     h1 ──────┐        h2 ──────┐        h3 ──────┐
              └──────── sw (브리지 br0) ───────────┘
                   전부 같은 10.10.10.0/24 (같은 서브넷)
```

## 3. 실습 준비
```sh
# 배포 (저장소 루트에서)
./clab.sh deploy 01-l2-arp/01-l2-arp.clab.yml
# (Linux에 containerlab을 직접 설치했다면: sudo containerlab deploy -t 01-l2-arp.clab.yml)
# 접속 (예: h1)
docker exec -it clab-01-l2-arp-h1 bash
```
> 노드 이름 규칙: `clab-01-l2-arp-<노드>` (h1/h2/h3/sw)

---

## 4. 실습 A — 정상 통신과 ARP 눈으로 보기 (도구 익히기)

**① h1의 주소/경로 확인**
```sh
docker exec clab-01-l2-arp-h1 ip addr show eth1     # 10.10.10.1/24 확인
docker exec clab-01-l2-arp-h1 ip route              # 10.10.10.0/24 dev eth1 (직접 연결)
```

**② h2에서 ARP를 엿듣기 (다른 터미널)**
```sh
docker exec clab-01-l2-arp-h2 tcpdump -e -ni eth1 arp
```
> `-e` = MAC 주소까지 표시, `-n` = 이름 해석 안 함(빠르게).

**③ h1에서 캐시 지우고 핑**
```sh
docker exec clab-01-l2-arp-h1 ip neigh flush all
docker exec clab-01-l2-arp-h1 ping -c1 10.10.10.2
```

**④ 관찰 (h2 tcpdump에 이렇게 뜬다)**
```
ARP, Request who-has 10.10.10.2 tell 10.10.10.1   ← h1이 방송으로 MAC 물음
ARP, Reply 10.10.10.2 is-at 02:..:..              ← h2가 자기 MAC 응답
```
그 다음에야 ICMP(핑)가 오간다.

**⑤ 학습된 ARP 캐시 확인**
```sh
docker exec clab-01-l2-arp-h1 ip neigh        # 10.10.10.2 lladdr 02:.. REACHABLE
```
**해설**: IP만으로는 못 보낸다. **ARP로 MAC을 먼저 알아내는 것**이 모든 IP 통신의 첫 단추다.

---

## 5. 실습 B — "같은 선에 꽂혀 있는데 왜 안 돼?" (서브넷 불일치)
실무에서 흔한 실수: 물리적으론 같은 스위치인데 **IP를 다른 서브넷으로** 잘못 준 경우.

**① h2를 다른 서브넷 주소로 바꿔 재현**
```sh
docker exec clab-01-l2-arp-h2 ip addr flush dev eth1
docker exec clab-01-l2-arp-h2 ip addr add 10.10.20.2/24 dev eth1   # 다른 서브넷!
```

**② h1에서 통신 시도** (이 랩은 라우터/기본 게이트웨이가 없다 — 순수 L2)
```sh
docker exec clab-01-l2-arp-h1 ip route get 10.10.20.2
#   → RTNETLINK answers: Network unreachable
docker exec clab-01-l2-arp-h1 ping -c1 10.10.20.2
#   → ping: connect: Network unreachable
```

**③ 관찰/해설**: h1 기준 `10.10.20.2`는 **다른 서브넷**이라, 같은 링크에 물려 있어도 ARP(직접 전달)를 시도하지 않는다. 다른 서브넷으로 보내려면 라우터가 필요한데 이 랩엔 없으므로 커널이 즉시 **`Network unreachable`** 로 거절한다. (h2에서 `tcpdump -e -ni eth1 arp` 를 켜둬도 h1의 ARP 요청이 오지 않는다.)

**해설**: **같은 케이블/스위치라도 IP·마스크상 다른 서브넷이면 L2로 직접 못 간다.** 통신하려면 라우터가 필요(→ 04장).
> 변형 실험: h1은 `/24`, h2는 `/25`처럼 **마스크만 다르게** 주면, 한쪽만 "같은 서브넷"으로 판단하는 **비대칭** 상황도 만들어진다.

**④ 되돌리기**
```sh
docker exec clab-01-l2-arp-h2 ip addr flush dev eth1
docker exec clab-01-l2-arp-h2 ip addr add 10.10.10.2/24 dev eth1
```

---

## 6. 실습 C — 중복 IP (ARP 충돌)
"가끔 되고 가끔 안 되는" 대표 원인.

**① h3에도 h2와 같은 IP를 부여(중복)**
```sh
docker exec clab-01-l2-arp-h3 ip addr add 10.10.10.2/24 dev eth1   # h2와 동일!
```

**② h1에서 관찰 — `arping` 으로 중복 응답 확인**
```sh
# 먼저 h2와 h3의 실제 MAC 확인
docker exec clab-01-l2-arp-h2 cat /sys/class/net/eth1/address
docker exec clab-01-l2-arp-h3 cat /sys/class/net/eth1/address
# h1에서 10.10.10.2로 arping → 서로 다른 MAC이 응답하면 중복 IP
docker exec clab-01-l2-arp-h1 arping -c3 -I eth1 10.10.10.2
```
실제 출력(예):
```
ARPING 10.10.10.2 from 10.10.10.1 eth1
Unicast reply from 10.10.10.2 [AA:C1:AB:BE:F5:63]   ← h3
Unicast reply from 10.10.10.2 [AA:C1:AB:68:04:27]   ← h2
Unicast reply from 10.10.10.2 [AA:C1:AB:68:04:27]
Sent 3 probes ...  Received 4 response(s)           ← probe보다 응답이 많다 = 중복!
```

**관찰**: 하나의 IP(`10.10.10.2`)에 **서로 다른 MAC 2개가 응답**한다(probe 수보다 응답이 많음). h1의 ARP 캐시 MAC이 흔들리고(플랩), 트래픽이 h2/h3 중 엉뚱한 쪽으로 간다.

**해설**: 같은 IP를 두 대가 쓰면 ARP 응답이 경쟁 → **간헐 실패**. 진단은 `ip neigh`(MAC 플랩)와 `tcpdump arp`(중복 응답)로.

**③ 되돌리기**
```sh
docker exec clab-01-l2-arp-h3 ip addr flush dev eth1
docker exec clab-01-l2-arp-h3 ip addr add 10.10.10.3/24 dev eth1
```

---

## 7. 정리 / 교훈
- IP 통신은 **항상 ARP(IP→MAC)가 선행**한다(같은 서브넷일 때).
- **"같은 네트워크"는 케이블이 아니라 IP+마스크가 정한다.** 다르면 라우터가 필요.
- **중복 IP = 간헐 장애.** `ip neigh` MAC 플랩 + `tcpdump arp` 중복 응답으로 잡는다.
- 이 원리는 위 계층 문제(라우팅·방화벽)를 진단할 때도 "**L2부터 성립하나?**"를 먼저 확인하는 습관으로 이어진다.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| 내 주소/링크 | `ip addr` , `ip -br addr` |
| 목적지로 어떻게 가나 | `ip route get <IP>` |
| ARP 캐시 보기/지우기 | `ip neigh` / `ip neigh flush all` |
| ARP 패킷 엿보기 | `tcpdump -e -ni eth1 arp` |
| 연결 확인 | `ping -c1 <IP>` |

## 9. 랩 정리(destroy)
```sh
./clab.sh destroy 01-l2-arp/01-l2-arp.clab.yml
```

---
### 다음 장 예고
이 장 내내 당연하게 썼던 **스위치(sw)는 어떻게 프레임을 옮기고 있었을까** — MAC 학습의 내부와,
그것이 루프 앞에서 무너지는 과정(브로드캐스트 스톰) → **02장**.
(다른 서브넷을 이어주는 라우터는 04장에서)
