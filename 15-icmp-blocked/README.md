# 15장. ICMP 차단의 대가 — "보안"이 진단을 눈멀게 할 때 (실패편)

> 이 시리즈 내내 ICMP가 일해 왔다: echo(00·04장), dest-unreachable(04·05장),
> time-exceeded(06장·traceroute), frag-needed(12·13장·PMTUD). 그런데 실무엔
> **"보안상 ICMP는 전부 막으세요"** 라는 정책이 흔하다. 이 장은 그 정책이 무엇을
> 부수는지 — 그리고 **ping이 안 된다 ≠ 죽었다**는 오판 체험을 시킨다.

## 0. 학습 목표
- **ping 실패 ≠ 서비스 다운** — 관측 도구와 서비스 경로는 다른 채널이다
- ICMP 전면 차단이 부수는 것들: 생존 확인 / traceroute / **PMTUD(12장)**
- 올바른 타협: **전면 차단이 아니라 필수 타입 선별 허용**

---

## 1. 개념

### 1-1. ICMP는 "옵션"이 아니라 제어 채널이다
| 타입 | 없으면 부서지는 것 |
|---|---|
| echo request/reply | ping — 가장 싼 생존/지연 측정 |
| time-exceeded (11) | traceroute 전부, 루프 탐지(06장) |
| destination-unreachable (3) | "길 없음" 통보(04장) — 특히 **code 4(frag-needed) = PMTUD(12장)** |

- frag-needed 차단의 결말은 12장에서 이미 봤다: **큰 전송만 조용히 죽는 블랙홀.**

### 1-2. 왜 다들 막을까, 뭘 허용해야 할까
- 근거가 없진 않다: ICMP 스캔/터널링/redirect 악용의 역사. 문제는 **전면** 차단이라는 과잉.
- 통설적 타협: `echo`, `destination-unreachable`(특히 frag-needed), `time-exceeded`는
  허용하고 나머지(redirect 등)를 선별 차단.

## 2. 토폴로지
```
   h1 ──── fw ──── srv(:80 웹, 멀쩡히 살아있음)
 10.15.1.10  └ 고장: ip protocol icmp drop (전면 차단)
```

## 3. 실습 준비
```sh
./clab.sh deploy 15-icmp-blocked/15-icmp-blocked.clab.yml
```
> 노드: `clab-15-icmp-blocked-<h1|fw|srv>`

---

## 4. 실습 A — 오판 체험: "서버 죽은 것 같은데요?"

```sh
docker exec clab-15-icmp-blocked-h1 ping -c2 10.15.2.10
docker exec clab-15-icmp-blocked-h1 curl -s -m 3 http://10.15.2.10/
```
✅ 실측:
```
ping → 100% packet loss        ← 모니터링/직감: "죽었다!"
curl → alive (0.005s)          ← 서비스: "저 멀쩡한데요"
```
**해설**: ping(ICMP)과 서비스(TCP/80)는 **다른 채널**이다. 중간 장비가 채널별로 다르게
다루면 관측과 실재가 갈라진다. **"ping 안 됨"만으로 장애 선언하지 마라** — 반대로,
"ping 되는데 서비스 죽음"도 성립한다(08장). 항상 서비스 채널로 최종 확인.

## 5. 실습 B — 진단 도구의 연쇄 붕괴

```sh
docker exec clab-15-icmp-blocked-h1 traceroute -n -w1 -q1 -m4 10.15.2.10
```
✅ 실측:
```
 1  10.15.1.1    ← fw 자신 (여기까진 fw가 직접 응답)
 2  *
 3  *
 4  *            ← 그 너머는 암흑 — time-exceeded가 차단되므로
```
**해설**: 06장에서 배웠듯 traceroute = TTL + time-exceeded. ICMP를 막으면
**경로 전체가 진단 불가 영역**이 된다. 여기에 12장의 조합(경로에 좁은 MTU 구간)이 겹치면
frag-needed도 차단 → **PMTUD 블랙홀까지 덤으로.** 장애 시 이 구간은 "아무것도 안 보이는" 지옥이 된다.

## 6. 수정 — 전면 차단 대신 선별 허용

```sh
docker exec clab-15-icmp-blocked-fw nft flush chain ip fw forward
docker exec clab-15-icmp-blocked-fw nft 'add rule ip fw forward \
  icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept'
docker exec clab-15-icmp-blocked-fw nft 'add rule ip fw forward ip protocol icmp drop'   # 나머지는 계속 차단
```
✅ **성공 판정** (실측):
```
ping       → 0% packet loss
traceroute → 1  10.15.1.1 / 2  10.15.2.10     ← 경로가 다시 보인다
curl       → alive                             ← 서비스는 그대로
```
**해설**: 보안 요구(redirect 등 차단)와 운영 요구(진단·PMTUD)가 **양립한다** —
전면 차단은 게으른 선택이었을 뿐.

---

## 7. 정리 / 교훈
- **ping은 서비스가 아니라 ICMP의 생사**를 알려줄 뿐. 최종 판정은 항상 서비스 채널로.
- ICMP 전면 차단의 청구서: 생존 확인 오판 + traceroute 실명 + **PMTUD 블랙홀(12장)**.
- 방화벽 정책 리뷰 때 물어라: *"echo / dest-unreachable(frag-needed!) / time-exceeded는
  살아 있는가?"* — 이 셋이 진단 가능성의 최소 조건이다.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| 서비스 채널로 생존 확인 | `curl -m 3` / `nc -zv -w3 <IP> <port>` |
| ICMP 선별 허용(nft) | `icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept` |
| 정책 확인 | `nft list ruleset` |

## 9. 랩 정리
```sh
./clab.sh destroy 15-icmp-blocked/15-icmp-blocked.clab.yml
```

---
### 다음 장 예고
확장 트랙의 남은 조각들 — VLAN 태그의 세계(03장), NAT 헤어핀(16장), 그리고 라우트가
"스스로 걸어오는" 동적 라우팅(17장).
