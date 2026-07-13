# 05장. Longest Prefix Match & 블랙홀 — 가장 구체적인 경로가 이긴다

> 04장에서 "라우터는 테이블이 전부"임을 봤다. 그렇다면 테이블에 **겹치는 경로**가 있으면?
> 규칙은 하나: **가장 구체적인(프리픽스가 긴) 경로가 이긴다(LPM)**. 이 규칙 때문에
> 잘못된 `/32` 하나가 멀쩡한 `/24` 전체 경로를 무력화할 수 있다 — 그것도 **아주 조용히**.

## 0. 학습 목표
- **LPM(Longest Prefix Match)**: /32 > /24 > /16 > default 의 우선순위
- **blackhole 라우트**의 증상: 에러 없이 조용히 소실 (vs `unreachable`: 즉시 에러)
- 실무 단골 증상 **"옆 IP는 되는데 이 IP만 안 됨"** 을 만들고, 잡는 법
- `ip route get`이 블랙홀을 만나면 어떻게 되는지 (기묘한 지문)

---

## 1. 개념

### 1-1. LPM — 라우팅 테이블의 유일한 심판
- 목적지에 매칭되는 경로가 여러 개면, **프리픽스 길이가 가장 긴 것** 하나만 쓰인다.
- `10.5.2.0/24 dev eth2` (연결됨, 정상)와 `10.5.2.10/32 blackhole` (오설정)이 공존하면
  → `10.5.2.10`행 패킷은 **/32가 낚아채고**, 나머지 253개 IP는 /24로 정상 흐른다.
- 그래서 증상이 **"거의 다 되는데 딱 하나만 안 됨"** — 전면 장애보다 훨씬 찾기 어렵다.

### 1-2. blackhole vs unreachable — 같은 차단, 다른 지문
| 라우트 타입 | 패킷의 운명 | 발신자가 보는 것 |
|---|---|---|
| `blackhole` | 조용히 폐기 | **타임아웃** (아무 소식 없음) |
| `unreachable` | 폐기 + ICMP 반송 | **즉시 "Destination Unreachable"** |

- 운영에서 blackhole은 DDoS 흡수(RTBH, 원격 블랙홀 라우팅) 등에 일부러 쓰지만, **실수로 남으면 최악의 장애**가 된다: 흔적 없이 사라지므로.

## 2. 토폴로지
```
   h1 ──────── r1 ──────── h2 (.10 = 주 IP, .11 = secondary)
 10.5.1.10    .1 | .1      10.5.2.0/24
```
**배포된 고장**: r1에 `blackhole 10.5.2.10/32` — h2의 주 IP만 정확히 저격.

## 3. 실습 준비
```sh
./clab.sh deploy 05-lpm-blackhole/05-lpm-blackhole.clab.yml
```
> 노드 이름: `clab-05-lpm-blackhole-<h1|r1|h2>`

---

## 4. 실습 A — 킬러 증상: "옆 IP는 되는데 이 IP만 안 됨"

```sh
docker exec clab-05-lpm-blackhole-h1 ping -c2 10.5.2.11    # 같은 서브넷의 옆 IP
docker exec clab-05-lpm-blackhole-h1 ping -c2 10.5.2.10    # 목표 IP
```
✅ 실측:
```
10.5.2.11 →  2 received, 0% packet loss        ← 옆 IP는 멀쩡
10.5.2.10 →  0 received, 100% packet loss      ← 이 IP만 조용히 죽음
```
**해설**: 같은 서브넷, 같은 호스트(!), 같은 NIC인데 IP 하나만 죽는다. L2 문제(01장)면 호스트째 죽고,
04장식 라우트 누락이면 **서브넷째** 죽는다. **"딱 한 IP"는 구체 경로(/32)의 지문**이다.

## 5. 실습 B — 범인 추적

**① `ip route get` — 기묘한 에러가 곧 힌트**
```sh
docker exec clab-05-lpm-blackhole-r1 ip route get 10.5.2.11
docker exec clab-05-lpm-blackhole-r1 ip route get 10.5.2.10
```
✅ 실측:
```
10.5.2.11 dev eth2 src 10.5.2.1          ← 정상: 연결된 /24로
RTNETLINK answers: Invalid argument      ← 10.5.2.10은 에러?! = blackhole에 매칭됐다는 뜻
```
> `ip route get`이 낯선 에러를 뱉으면 blackhole/prohibit류 특수 라우트를 의심하라.

**② 테이블에서 범인 확인**
```sh
docker exec clab-05-lpm-blackhole-r1 ip route show
```
✅ 실측:
```
10.5.1.0/24 dev eth1 ...
10.5.2.0/24 dev eth2 ...      ← 정상 경로는 멀쩡히 있다!
blackhole 10.5.2.10           ← 그러나 /32가 LPM으로 이긴다
```

**③ traceroute — 블랙홀은 첫 홉부터 침묵한다** (04장과 대조)
```sh
docker exec clab-05-lpm-blackhole-h1 traceroute -n -w1 -q1 -m3 10.5.2.10
```
✅ 실측:
```
 1  *
 2  *
 3  *        ← 04장(리턴 누락)은 1번 홉(r1)이 응답했지만, 여기선 그마저 없다
```
**해설**: 블랙홀 드랍은 **라우팅 단계**에서 일어난다 — TTL 검사(포워딩 단계)에 도달하기 전에
패킷이 사라지므로 r1은 time-exceeded조차 만들지 않는다. "첫 홉부터 전부 `*`"는 강한 블랙홀 신호.

## 6. 실습 C — 변형: unreachable로 바꾸면 증상이 바뀐다
```sh
docker exec clab-05-lpm-blackhole-r1 ip route replace unreachable 10.5.2.10/32
docker exec clab-05-lpm-blackhole-h1 ping -c2 10.5.2.10
```
✅ 실측:
```
From 10.5.1.1 icmp_seq=1 Destination Host Unreachable    ← 즉시, r1이 발신자에게 알림
```
**해설**: 차단이라는 결과는 같지만 — blackhole은 **타임아웃**, unreachable은 **즉시 에러**.
발신자가 보는 증상만으로 중간 장비의 처리 방식을 역추론할 수 있다 (08장에서 TCP 버전으로 확장).

## 7. 한 줄 수정
```sh
docker exec clab-05-lpm-blackhole-r1 ip route del blackhole 10.5.2.10/32
# (실습 C를 했다면: ip route del unreachable 10.5.2.10/32)
```
✅ **성공 판정** (실측):
```
ping 10.5.2.10 → 2 received, 0% packet loss
ip route get 10.5.2.10 → 10.5.2.10 dev eth2 src 10.5.2.1   ← 이제 /24가 답한다
```

---

## 8. 정리 / 교훈
- **구체 경로 하나가 광역 경로를 무력화한다.** 라우트를 볼 때는 "경로가 있나"가 아니라
  "**이 목적지에 누가 이기나**"(`ip route get`)를 물어라.
- 증상 지문: **딱 한 IP만 안 됨** = /32 의심 · **첫 홉부터 traceroute 전멸** = 블랙홀 의심 ·
  **즉시 unreachable** = 명시적 거부.
- blackhole은 도구이자 흉기 — 남겨진 /32 하나가 몇 시간짜리 장애가 된다.

## 9. 치트시트
| 목적 | 명령 |
|---|---|
| 이 목적지에 누가 이기나 | `ip route get <IP>` |
| 특수 라우트 포함 전체 | `ip route show` (blackhole/unreachable도 표시) |
| 블랙홀 설치/제거 | `ip route add/del blackhole <IP>/32` |
| 명시적 거부 | `ip route add unreachable <IP>/32` |

## 10. 랩 정리
```sh
./clab.sh destroy 05-lpm-blackhole/05-lpm-blackhole.clab.yml
```

---
### 다음 장 예고
증상을 3-way 핸드셰이크 수준에서 읽는다 — **타임아웃 vs refused vs reset**, 같은 "안 됨"의
서로 다른 지문 → **08장**. (06·07장은 확장편: TTL 루프, VXLAN 오버레이)
