# 06장. TTL & 라우팅 루프 — 패킷이 영원히 돌지 않는 이유

> 02장에서 L2 루프가 스톰이 됐던 걸 기억하라 — 이더넷 프레임엔 수명이 없어서였다.
> L3는 다르다: **IP 패킷은 TTL이라는 수명**을 갖고, 홉을 지날 때마다 1씩 깎여 0이 되면
> 죽는다. 이 장은 라우팅 루프를 일부러 만들어 **TTL이 루프를 끊는 현장**을 관찰한다.

## 0. 학습 목표
- **TTL(Time To Live)** 의 동작: 홉마다 −1, 0이면 폐기 + **ICMP time-exceeded** 통보
- 라우팅 루프의 전형적 원인: **상호 디폴트**("모르면 쟤한테" ↔ "모르면 쟤한테")
- traceroute가 사실 **TTL을 이용한 해킹**임을 이해 (04장의 복선 회수)
- 루프의 지문 3종과, "모르는 목적지는 명시적으로 버려라"는 설계 원칙

---

## 1. 개념

### 1-1. TTL — L3의 자폭 장치
- 발신자가 TTL을 채워 보낸다(리눅스 기본 64). 라우터는 포워딩할 때마다 1을 깎고,
  **0이 되면 버리며 발신자에게 ICMP time-exceeded로 알린다.**
- 덕분에 라우팅이 꼬여도 패킷이 영원히 돌며 대역폭을 태우는 일은 없다(02장 스톰과의 결정적 차이).

### 1-2. 루프는 어떻게 생기나
- 대표 패턴: r1 "모르는 건 r2로(default)" + r2 "모르는 건 r1으로(default)" — **상호 디폴트**.
- 존재하지 않는/광고가 끊긴 목적지로 향하는 트래픽이 두 라우터 사이에 갇힌다.
- 실무에선 디폴트 체인 설계 실수, 라우팅 프로토콜 수렴 중 과도기 등에서 발생.

### 1-3. traceroute의 정체 (복선 회수)
- traceroute는 **TTL을 1, 2, 3...으로 늘려가며** 보내고, 각 홉이 돌려주는 time-exceeded의
  발신자를 기록하는 도구다. TTL이 없으면 traceroute도 없다.

## 2. 토폴로지
```
   h1 ──── r1 ⇄ r2          r1: default → r2
 10.6.1.10   (10.6.0.0/30)    r2: default → r1   ← 장전된 고장 (상호 디폴트)
```

## 3. 실습 준비
```sh
./clab.sh deploy 06-ttl-loop/06-ttl-loop.clab.yml
```
> 노드: `clab-06-ttl-loop-<h1|r1|r2>`

---

## 4. 실습 A — 증상: 루프는 자기 정체를 밝힌다

h1에서 **존재하지 않는 목적지**로:
```sh
docker exec clab-06-ttl-loop-h1 ping -c2 198.51.100.1
```
✅ 실측:
```
From 10.6.0.2 icmp_seq=1 Time to live exceeded     ← r2가 "수명 다했다"고 알려온다!
From 10.6.0.2 icmp_seq=2 Time to live exceeded
2 packets transmitted, 0 received, +2 errors, 100% packet loss
```
**해설**: 05장 블랙홀(침묵)·04장 unreachable(길 없음)과 또 다른 제3의 지문 —
**"Time to live exceeded" = 어딘가에서 내 패킷이 뱅뱅 돌다 죽었다**는 자백이다.
발신지(10.6.0.2)는 TTL이 다한 지점의 라우터.

## 5. 실습 B — traceroute: 루프의 시각화

```sh
docker exec clab-06-ttl-loop-h1 traceroute -n -w1 -q1 -m8 198.51.100.1
```
✅ 실측:
```
 1  10.6.1.1      ← r1
 2  10.6.0.2      ← r2
 3  10.6.1.1      ← 다시 r1?!
 4  10.6.0.2
 5  10.6.1.1
 6  10.6.0.2      ← ... 같은 두 홉이 영원히 교대 = 루프 확정
```

## 6. 실습 C — 현장 검증: 같은 패킷의 TTL이 깎이며 왕복한다

```sh
docker exec clab-06-ttl-loop-r1 tcpdump -vnli eth2 icmp    # 전송 링크에서
# (다른 터미널에서 ping 1발)
```
✅ 실측 — 캡처된 연속 프레임의 TTL:
```
ttl 63 → ttl 62 → ttl 61 → ttl 60 → ttl 59 → ttl 58 ...
```
**해설**: **동일한 echo request가** r1↔r2 사이를 오가며 지날 때마다 1씩 늙는다.
64에서 시작해 0이 되는 순간 그 자리의 라우터가 폐기 + time-exceeded 발신 — 실습 A에서
받은 그 메시지다. (02장 스톰과 비교: L2 프레임엔 이 카운터가 없어 증폭이 무한했다.)

## 7. 한 줄 수정 — 모르는 목적지는 버려라

루프의 근본 원인은 "모르는 걸 서로에게 미루는" 설계다. r2가 정직해지게 한다:
```sh
docker exec clab-06-ttl-loop-r2 ip route replace unreachable default
```
✅ **성공 판정** (실측):
```
ping → From 10.6.0.2: Destination Host Unreachable   ← 즉시, 명시적 거절 (루프 소멸)
traceroute → 2  10.6.0.2 !H                           ← r2에서 딱 끊긴다
```
**해설**: 여전히 목적지엔 못 간다(원래 없는 곳이니까). 하지만 **수십 홉을 태우며 돌다
죽는 것**과 **한 홉 만에 명시적으로 거절되는 것**은 하늘과 땅 차이다 — 대역폭, 지연,
그리고 무엇보다 **진단 가능성**에서. 라우팅 설계의 격언: *default를 서로에게 겨누지 말라.*

---

## 8. 정리 / 교훈
- **TTL은 L3의 안전핀**: 루프를 없애주진 않지만, 루프의 피해를 유한하게 만들고 정체를 자백시킨다.
- 지문 정리: **time-exceeded 반복** = 루프 / **traceroute 홉 교대 반복** = 루프 확정 /
  전송 구간 tcpdump의 **TTL 감소 행렬** = 물증.
- 상호 디폴트는 루프의 왕도. **"모르는 목적지"의 운명(버림/거절)을 명시적으로 설계**하라.
- traceroute = TTL 해킹. ICMP time-exceeded를 막으면 traceroute도 눈먼다(→ 15장).

## 9. 치트시트
| 목적 | 명령 |
|---|---|
| 루프 의심 확인 | `traceroute -n <IP>` — 홉 반복 여부 |
| TTL 물증 | `tcpdump -vnli <if> icmp` — ttl 필드 |
| 모르는 목적지 명시 거절 | `ip route replace unreachable default` |
| 디폴트 체인 추적 | 각 라우터에서 `ip route get <IP>` 연쇄 실행 |

## 10. 랩 정리
```sh
./clab.sh destroy 06-ttl-loop/06-ttl-loop.clab.yml
```

---
### 다음 장 예고
time-exceeded, frag-needed, unreachable... 진단은 온통 ICMP에 기대고 있다.
그걸 "보안"이라며 전부 막으면? → **15장 (ICMP 차단의 대가)**.
