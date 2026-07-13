# 04장. L3 라우팅 기본 & 기본 게이트웨이 — "왕복이 성립해야 통신이다"

> 01·02장의 "같은 네트워크"를 벗어난다. 다른 서브넷으로 가려면 **라우터**가 필요하고,
> 라우터는 오직 **라우팅 테이블**만 보고 움직인다. 이 장의 핵심 경험: **포워드(가는 길)가
> 되어도 리턴(오는 길)이 없으면 통신은 실패한다** — 그리고 그 증상을 tcpdump로 읽는다.

## 0. 학습 목표
- 라우팅 테이블과 **기본 게이트웨이**의 역할 (목적지 기반 포워딩)
- `ip route get` / `traceroute` 로 경로를 읽고 **어디서 멎는지** 찾는 법
- **ICMP 기초**: echo request/reply, destination unreachable — 오류를 "알려주는" 프로토콜
- 대표 고장 3종의 증상 구분: **리턴 라우트 누락 / ip_forward=0 / 기본 게이트웨이 누락**

---

## 1. 개념

### 1-1. 라우터는 테이블이 전부다
- 라우터는 패킷의 **목적지 IP**를 자기 라우팅 테이블과 대조해 next-hop을 정한다. 그게 전부다.
- 테이블에 길이 없으면? **버리고, 발신자에게 ICMP unreachable로 알려준다** (그래서 ICMP를 막으면 진단이 어려워진다 → 15장).
- 호스트의 **기본 게이트웨이** = "모르는 목적지는 전부 이 라우터로"라는 특수한 라우트(`default`).

### 1-2. 왕복은 별개의 두 결정이다
- h1→h2 경로와 h2→h1 경로는 **각 라우터가 따로** 결정한다. 가는 길이 있다고 오는 길이 자동으로 생기지 않는다.
- 실무 장애의 단골: **"요청은 가는데 응답이 못 돌아온다"** — 이 장에서 직접 관찰한다.

### 1-3. ICMP와 traceroute (이 장부터 상비 도구)
- `ping` = ICMP echo request/reply.
- `traceroute` = TTL을 1씩 늘려 보내며, 각 홉이 돌려주는 **ICMP time-exceeded**로 경로를 그린다 (TTL은 06장에서 깊게).
- 홉이 `*`이면: 그 라우터가 응답을 안 주거나, **응답이 돌아올 길이 없는 것**.

## 2. 토폴로지
```
   h1 ──────── r1 ──────── r2 ──────── h2
 10.4.1.10   .1 | .1     .2 | .1     10.4.2.10
   (10.4.1.0/24)  (10.4.0.0/30)  (10.4.2.0/24)
```
- h1/h2는 각자의 라우터를 기본 게이트웨이로 사용.
- r1은 완전(10.4.2.0/24 via r2 보유). **r2에는 10.4.1.0/24 리턴 라우트가 없다 = 배포된 고장.**

## 3. 실습 준비
```sh
./clab.sh deploy 04-l3-routing/04-l3-routing.clab.yml
```
> 노드 이름: `clab-04-l3-routing-<h1|r1|r2|h2>`

---

## 4. 실습 A — 증상 확인과 경로 읽기

**① h1은 어떻게 보내려 하는가**
```sh
docker exec clab-04-l3-routing-h1 ip route get 10.4.2.10
```
실측:
```
10.4.2.10 via 10.4.1.1 dev eth1 src 10.4.1.10     ← "다른 서브넷 → 게이트웨이로"
```

**② 증상: 타임아웃**
```sh
docker exec clab-04-l3-routing-h1 ping -c2 -W2 10.4.2.10
# 2 packets transmitted, 0 received, 100% packet loss   (실측)
```

**③ traceroute — 어디서 멎나**
```sh
docker exec clab-04-l3-routing-h1 traceroute -n -w1 -q1 -m4 10.4.2.10
```
실측:
```
 1  10.4.1.1  0.005 ms     ← r1까지는 응답
 2  *
 3  *                      ← r2부터 침묵
```

---

## 5. 실습 B — 결정적 관찰: "편도만 성립한다"

**① h2에서 캡처를 켜고, h1에서 다시 ping**
```sh
# (터미널1)
docker exec clab-04-l3-routing-h2 tcpdump -nli eth1 icmp
# (터미널2)
docker exec clab-04-l3-routing-h1 ping -c2 -W2 10.4.2.10
```
✅ 실측 — 이 세 줄이 이 장의 전부다:
```
10.4.1.10 > 10.4.2.10: ICMP echo request        ← ① 요청은 h2에 "도달했다"!
10.4.2.10 > 10.4.1.10: ICMP echo reply           ← ② h2는 성실히 "응답했다"!
10.4.2.1  > 10.4.2.10: ICMP net 10.4.1.10 unreachable   ← ③ 그런데 r2가 "그런 길 없다"며 반송
```
**해설**: 포워드 경로(h1→r1→r2→h2)는 완벽하다. 죽은 것은 **리턴**: h2의 응답이 r2에 도착했지만
r2의 테이블에 10.4.1.0/24가 없어 버려졌고, r2는 h2에게 ICMP로 그 사실을 알렸다.
h1 입장에선 그냥 "타임아웃" — **타임아웃의 원인이 자기 쪽 절반이 아닐 수 있다.**

**② 원인을 r2에게 직접 물어보기**
```sh
docker exec clab-04-l3-routing-r2 ip route get 10.4.1.10
# RTNETLINK answers: Network unreachable          (실측)
docker exec clab-04-l3-routing-r2 ip route show
# 10.4.0.0/30 dev eth1 ...
# 10.4.2.0/24 dev eth2 ...                        ← 10.4.1.0/24가 없다
```

## 6. 한 줄 수정
```sh
docker exec clab-04-l3-routing-r2 ip route replace 10.4.1.0/24 via 10.4.0.1
```
✅ **성공 판정** (실측):
```sh
docker exec clab-04-l3-routing-h1 ping -c2 10.4.2.10     # 0% packet loss
docker exec clab-04-l3-routing-h1 traceroute -n -w1 -q1 -m4 10.4.2.10
#  1  10.4.1.1   ← 이제 모든 홉이 보인다 (홉의 응답도 "돌아올 길"이 생겼으므로)
#  2  10.4.0.2
#  3  10.4.2.10
```

---

## 7. 실습 C — 변형 고장 2종: 같은 "타임아웃", 다른 지문

### C-1. `ip_forward=0` — 라우터가 라우터이길 그만두면
```sh
docker exec clab-04-l3-routing-r1 sysctl -w net.ipv4.ip_forward=0
docker exec clab-04-l3-routing-h1 ping -c2 -W1 10.4.2.10     # 100% loss (실측)
```
기본 고장(실습 B의 리턴 누락)과의 차이를 캡처로 확인 (실측):
```sh
docker exec clab-04-l3-routing-h2 timeout 4 tcpdump -nli eth1 -c2 icmp
# → 0 packets captured                  ← 요청이 h2에 "도달조차 안 함"
docker exec clab-04-l3-routing-r1 timeout 4 tcpdump -nli eth1 -c2 icmp
# → 10.4.1.10 > 10.4.2.10: ICMP echo request (2 packets)   ← r1까지는 들어옴 = r1이 조용히 삼킴
```
**해설**: 같은 타임아웃이라도 — 리턴 누락은 **목적지까지 갔다가 못 돌아온 것**,
포워딩 꺼짐은 **중간에서 소멸**한 것. **tcpdump를 어디에 꽂느냐로 두 고장이 구분된다.**
```sh
docker exec clab-04-l3-routing-r1 sysctl -w net.ipv4.ip_forward=1    # 복구
```

### C-2. 기본 게이트웨이 누락 — 01장의 콜백
```sh
docker exec clab-04-l3-routing-h1 ip route del default
docker exec clab-04-l3-routing-h1 ping -c1 10.4.2.10
# ping: connect: Network unreachable                (실측 — 즉시 에러!)
```
**해설**: 이번엔 타임아웃이 아니라 **즉시 에러**다. 커널이 보내기 전에 "갈 길 없음"을 아는 경우
(로컬 라우팅 테이블에 답이 없음) vs 보냈는데 소식이 없는 경우(타임아웃)는 **증상부터 다르다**.
→ 08장에서 이 "증상 지문 읽기"를 체계화한다.
```sh
docker exec clab-04-l3-routing-h1 ip route add default via 10.4.1.1    # 복구
```

---

## 8. 정리 / 교훈
- 라우터는 **테이블에 있는 대로만** 움직인다. 길이 없으면 버리고 ICMP로 알린다.
- **왕복은 두 개의 독립된 결정** — 포워드가 완벽해도 리턴 라우트 하나 없으면 타임아웃.
- 진단 순서: `ip route get`(내 판단) → `traceroute`(어디까지 가나) → **양 끝과 중간에 tcpdump**(어디서 소멸하나).
- 증상 지문: **즉시 Network unreachable**(내 테이블에 길 없음) vs **타임아웃**(가서 안 돌아옴/중간 소멸) — 이미 원인 후보가 갈린다.

## 9. 치트시트
| 목적 | 명령 |
|---|---|
| 이 목적지를 어디로 보내나 | `ip route get <IP>` |
| 라우팅 테이블 | `ip route show` |
| 경로 추적 | `traceroute -n <IP>` |
| 포워딩 여부 | `sysctl net.ipv4.ip_forward` |
| 라우트 추가/교체 | `ip route replace <net> via <nexthop>` |

## 10. 랩 정리
```sh
./clab.sh destroy 04-l3-routing/04-l3-routing.clab.yml
```

---
### 다음 장 예고
라우트가 여러 개 겹치면 누가 이길까? **가장 구체적인 경로가 이긴다** — 그리고 그 규칙이
잘못된 /32 하나로 전체를 죽이는 **블랙홀**을 만든다 → **05장**.
