# 12장. MTU / MSS / PMTUD — "작은 건 되는데 큰 것만 멎어요"

> 연결도 되고 ping도 되는데 **파일 전송/TLS만 죽는** 미스터리. 원인은 경로 중간의
> **좁은 MTU 구간** + 그것을 알려줄 **ICMP가 차단**된 조합 — 이른바 **PMTUD 블랙홀**이다.
> 실무에서 VPN/터널 도입 직후 단골로 터지는 부류의 장애를 재현한다.

## 0. 학습 목표
- **MTU**(링크당 최대 프레임)와 **MSS**(TCP 세그먼트 크기 협상)의 관계
- **PMTUD**: 경로 전체의 최소 MTU를 ICMP frag-needed로 알아내는 메커니즘
- PMTUD가 침묵당하면(블랙홀) 왜 **큰 패킷만 조용히** 죽는지
- 두 처방의 차이: **ICMP 허용**(근본) vs **MSS clamp**(TCP 한정 응급)

---

## 1. 개념

### 1-1. MSS 협상은 "양 끝"만 안다
- TCP는 3-way 때 서로의 MSS를 교환한다 — 각자 **자기 링크**의 MTU 기준(1500 → MSS 1460).
- **중간에 더 좁은 구간(1400)이 있다는 건 양 끝 다 모른다.** 그걸 알아내는 게 PMTUD.

### 1-2. PMTUD의 동작
1. 발신자는 DF(Don't Fragment)를 켜고 자기 MTU 크기로 보낸다.
2. 좁은 링크의 라우터가 "못 지나감"을 발견 → 패킷을 버리고 **ICMP frag-needed(type3/code4,
   "MTU는 1400이야")** 를 발신자에게 돌려준다.
3. 발신자는 경로 캐시에 그 MTU를 **학습**하고 재전송한다. 끝.

### 1-3. 블랙홀의 탄생
- 위 2번의 ICMP를 누가 막으면? ("보안상 ICMP 차단"이 흔한 범인) —
  발신자는 **영원히 통보받지 못하고** 큰 패킷만 재전송하다 죽는다.
- 작은 패킷(제어/핸드셰이크)은 잘 통과하므로 **"연결은 되는데 데이터만 멎는"** 기묘한 증상.

## 2. 토폴로지
```
   h1 ──1500── r1 ──[1400]── r2 ──1500── h2(iperf3 서버)
 10.12.1.10                               10.12.2.10
              └─ 고장: r1이 자기가 만든 frag-needed를 차단
```
(중간 1400 구간 = VPN/터널 구간의 모사. 13장에서 진짜 VXLAN으로 재연한다)

## 3. 실습 준비
```sh
./clab.sh deploy 12-mtu-pmtud/12-mtu-pmtud.clab.yml
```
> 노드 이름: `clab-12-mtu-pmtud-<h1|r1|r2|h2>`

---

## 4. 실습 A — 증상: 크기가 운명을 가른다

```sh
docker exec clab-12-mtu-pmtud-h1 ping -c2 -s 100 10.12.2.10          # 작은 패킷
docker exec clab-12-mtu-pmtud-h1 ping -M do -c2 -s 1472 10.12.2.10   # 1500B 프레임, DF
```
✅ 실측:
```
-s 100        → 2 received, 0% packet loss      ← 잘만 된다
-s 1472 (DF)  → 0 received, 100% packet loss    ← 에러 메시지도 없이 침묵
```
> `-M do` = DF 강제(단편화 금지), `-s 1472` = 페이로드 1472 + 헤더 28 = 1500바이트.

**큰 전송(TCP)은?**
```sh
docker exec clab-12-mtu-pmtud-h1 iperf3 -c 10.12.2.10 -t 3
```
✅ 실측:
```
[  5]  0.00-3.00 sec  0.00 Bytes  0.00 bits/sec   3   sender
```
**해설**: iperf3의 **연결 자체는 성립**했다(제어 메시지 = 작은 패킷). 그러나 데이터(1500B 세그먼트)는
전부 r1에서 죽는다 → **0.00 bits/sec**. "TLS 핸드셰이크는 되는데 인증서/응답에서 멎어요"의 실체.

## 5. 실습 B — 왜 h1은 모를까 (블랙홀 관찰)

```sh
docker exec clab-12-mtu-pmtud-h1 tracepath -n 10.12.2.10
```
✅ 실측 (고장 상태):
```
 1?: [LOCALHOST]   pmtu 1500          ← 여기서 멈춤. 1400의 존재를 끝내 못 배운다
```
**해설**: r1은 1500B DF 패킷을 버리며 frag-needed를 **만들긴 했지만**, 자신의 output 필터가
그걸 차단한다(이 랩의 고장). h1에게 세상은 조용하기만 하다 — 08장의 "조용한 실패" 지문의 MTU 판.

## 6. 두 가지 처방 — 차이를 알고 쓰라

### 처방① MSS clamp (TCP 한정 응급처치)
```sh
docker exec clab-12-mtu-pmtud-r1 iptables -t mangle -A FORWARD \
  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```
✅ 실측: iperf3 `0.00 → 8.28 Gbits/sec` — **ICMP가 여전히 차단된 채로** TCP가 살아났다!
그러나:
```
ping -M do -s 1472  → 여전히 100% loss (침묵)     ← clamp는 TCP SYN의 MSS만 만진다
```
**해설**: 라우터가 지나가는 **SYN의 MSS 값을 몰래 1360으로 고쳐 써서** 양 끝이 처음부터
작게 보내게 만든다. TCP엔 특효지만 **UDP/ICMP/터널엔 무력** — 증상을 가리는 응급처치임을 알고 쓰라.

### 처방② ICMP frag-needed 허용 (근본 수정)
```sh
docker exec clab-12-mtu-pmtud-r1 nft flush chain ip fw output
docker exec clab-12-mtu-pmtud-h1 ping -M do -c2 -s 1472 10.12.2.10
```
✅ 실측 — 이번엔 **침묵이 아니라 정보**를 받는다:
```
From 10.12.1.1 icmp_seq=1 Frag needed and DF set (mtu = 1400)   ← r1이 알려준다!
```
그리고 h1의 경로 캐시 (이 장의 백미):
```sh
docker exec clab-12-mtu-pmtud-h1 ip route get 10.12.2.10
# 10.12.2.10 via 10.12.1.1 ...
#     cache expires 597sec mtu 1400        ← PMTU가 "학습"되었다 (실측)
```
```
iperf3   → 8.44 Gbits/sec                           ← TCP도 정상
tracepath → 2: 10.12.1.1  pmtu 1400  ("Resume: pmtu 1400")   ← 발견 성공
```

---

## 7. 정리 / 교훈
- **"작은 건 되는데 큰 전송/TLS만 멎음" = MTU 블랙홀의 지문.** 접속 성공이 경로 건강을 보증하지 않는다.
- PMTUD는 **ICMP frag-needed에 전적으로 의존**한다. "보안상 ICMP 전면 차단"은 이 메커니즘의
  숨통을 끊는다 (→ 15장에서 전면 차단의 대가를 총정리).
- 진단 3종: `ping -M do -s <크기>`(이진 탐색 가능), `tracepath`(경로 pmtu), `ip route get`(캐시 확인).
- MSS clamp는 **터널 구간의 표준 관행이자 응급처치** — 단 TCP에만 듣는다는 한계를 기억.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| DF 강제 큰 ping | `ping -M do -s 1472 <IP>` (1500 프레임) |
| 경로 MTU 발견 | `tracepath -n <IP>` |
| 학습된 PMTU 캐시 | `ip route get <IP>` → `mtu` 항목 |
| MSS clamp | `iptables -t mangle ... -j TCPMSS --clamp-mss-to-pmtu` |
| 내 링크 MTU | `ip link show eth1` |

## 9. 랩 정리
```sh
./clab.sh destroy 12-mtu-pmtud/12-mtu-pmtud.clab.yml
```

---
### 다음 장 예고
이 장의 "중간 1400 구간"은 모사였다. 13장(확장)에서는 **07장의 진짜 VXLAN 터널** 위에서
50바이트 오버헤드가 같은 장애를 만드는 걸 본다. 코어 트랙은 → **14장(DNS)**.
