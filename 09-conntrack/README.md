# 09장. conntrack / 포트 & idle timeout — 방화벽과 NAT는 "기억"으로 동작한다

> 08장은 연결이 **맺어지는 순간**의 실패였다. 이 장은 **잘 맺어진 연결이 나중에 죽는** 이야기다.
> 상태형 장비(방화벽/NAT)는 지나가는 연결을 **상태 테이블(conntrack)** 에 기억하는데,
> 이 기억이 **만료**되거나(idle timeout) **가득 차면**(포트 고갈) 기묘한 장애가 난다:
> **"어제까지 되던 게 조용히 죽는다" / "기존 연결은 되는데 새 연결만 안 된다".**

## 0. 학습 목표
- **conntrack 테이블** 읽기: 원방향/응답방향 튜플, 상태, 남은 타임아웃
- **idle timeout**: 오래 조용하던 연결이 어떻게 "조용히" 죽는지 (커넥션 풀의 적)
- **SNAT 포트 고갈**: ephemeral(임시 발신) 포트의 유한함 → "신규만 실패" 증상
- 진단 도구: `conntrack -L` / `-S` (insert_failed)

---

## 1. 개념

### 1-1. 상태 테이블 = 왕복표
- NAT/상태형 방화벽은 첫 패킷에서 **엔트리**를 만든다: "원방향 (cli:포트→srv:포트)" ↔ "응답방향 (srv→NAT:포트)".
- 이후 패킷은 이 표로 번역/허용된다. **표에 없으면(INVALID) 버려진다** — 엄격한 장비일수록 그렇다.

### 1-2. idle timeout — 기억은 공짜가 아니다
- 테이블은 유한하므로 **한동안 조용한 엔트리는 지운다**. 문제는 **양 끝의 소켓은 그걸 모른다**는 것.
- 연결은 애플리케이션 입장에선 멀쩡히 "열려" 있는데, 중간 장비의 기억만 사라진 상태 →
  다음에 보낸 데이터가 조용히 버려진다. **커넥션 풀, DB 연결, 롱폴링**이 단골 피해자.

### 1-3. 포트 고갈 — NAT의 수학
- SNAT는 (프로토콜, NAT IP:**포트**, 목적지 IP:포트) 튜플로 연결을 구분한다.
- 같은 목적지로 갈 때 쓸 수 있는 포트가 N개면 **동시 연결 최대 N개**. 다 차면 **신규 연결만** 실패한다 (기존은 멀쩡!).

## 2. 토폴로지
```
   cli ──────── nat ──────── srv(:7777 echo 서버)
 10.9.1.10   (SNAT+상태 FW)   10.9.2.10
```
**장전된 고장**: ① established idle timeout = **30초** (기본 5일)
② TCP SNAT 포트 = **30000-30001 딱 2개**  (+ INVALID DROP, loose=0 — 엄격한 실무 방화벽 모사)

## 3. 실습 준비
```sh
./clab.sh deploy 09-conntrack/09-conntrack.clab.yml
```
> 노드 이름: `clab-09-conntrack-<cli|nat|srv>`

---

## 4. 실습 A — 번역표 읽기

```sh
docker exec -d clab-09-conntrack-cli bash -c "sleep 120 | nc 10.9.2.10 7777"   # 연결 하나 열어두기
docker exec clab-09-conntrack-nat conntrack -L | grep 7777
```
✅ 실측:
```
tcp  6  27 ESTABLISHED  src=10.9.1.10 dst=10.9.2.10 sport=36706 dport=7777 \
                        src=10.9.2.10 dst=10.9.2.1  sport=7777  dport=30000  [ASSURED]
```
읽는 법:
- 앞 튜플 = **원방향** (cli:36706 → srv:7777), 뒤 튜플 = **응답방향** (srv → **NAT IP:30000**)
  → cli의 36706이 NAT의 30000으로 **재작성**되어 있음이 표에 그대로 보인다.
- 둘째 숫자 **27 = 남은 수명(초)**. 30에서 깎이는 중 — 고장 ①이 카운트다운되고 있다!

## 5. 실습 B — 장수 연결의 조용한 죽음

echo 서버에 "hello"를 보내고, **40초 방치**(timeout 30초보다 길게) 후 "world"를 보낸다:
```sh
docker exec clab-09-conntrack-cli bash -c \
  '( echo hello; sleep 40; echo world; sleep 8 ) | timeout 55 nc 10.9.2.10 7777'
```
✅ 실측 타임라인:
```
t=0s   hello 발신 → 즉시 "hello" 에코 수신              ← 연결 정상
t=10s  conntrack: 6 19 ESTABLISHED (수명 19초 남음)      ← 기억이 줄어드는 중
t=38s  conntrack: 엔트리 0개                             ← 기억 소멸 (양끝 소켓은 모름!)
t=40s  world 발신 → ...에코가 영원히 안 온다
```
world 패킷의 운명 (cli 캡처, 실측):
```
Flags [P.] length 6   ← world\n 발신
Flags [P.] seq 0:6    ← 0.2초 뒤 재전송
Flags [P.] seq 0:6    ← 0.2, 0.4, 0.9, 1.7초... 지수 백오프로 무한 재전송
                        (응답 ACK 없음 — nat이 INVALID로 조용히 폐기 중)
```
**해설**: 에러는 어디에도 없다. RST도 ICMP도 없이 **그냥 조용하다** — 상태 만료 장애의 지문.
애플리케이션 입장에선 "write는 됐는데(로컬 버퍼) 응답이 없는" 상태로 한참을 매달린다.

**수정(택1)**:
```sh
# ① 장비 쪽: timeout 상향
docker exec clab-09-conntrack-nat sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600
# ② 앱 쪽(콜아웃): TCP keepalive — 조용한 연결에 주기적 심장박동을 넣어 기억을 갱신
```

## 6. 실습 C — SNAT 포트 고갈: "신규만 안 됨"

**① 동시 연결 2개로 포트를 다 쓴다**
```sh
docker exec -d clab-09-conntrack-cli bash -c "sleep 60 | nc 10.9.2.10 7777"
docker exec -d clab-09-conntrack-cli bash -c "sleep 60 | nc 10.9.2.10 7777"
docker exec clab-09-conntrack-nat bash -c "conntrack -L | grep -oE 'dport=3000[01]' | sort | uniq -c"
```
✅ 실측: `1 dport=30000` / `1 dport=30001` — **할당 가능한 포트 2개가 전부 점유**.

**② 3번째 연결 (기대: 신규만 타임아웃)**
```sh
docker exec clab-09-conntrack-cli bash -c "time nc -zv -w 4 10.9.2.10 7777"
```
✅ 실측: `timed out ... real 0m4.013s` — 기존 2개는 멀쩡히 살아있는 채로!

**③ nat 쪽 증거 — insert_failed 카운터**
```sh
docker exec clab-09-conntrack-nat conntrack -S | grep insert_failed
```
✅ 실측: `insert_failed=1`, `insert_failed=3` (CPU별) — **0이 아니면 포트/엔트리 할당 실패가 있었다는 물증**.

**④ 한 줄 수정**
```sh
docker exec clab-09-conntrack-nat iptables -t nat -R POSTROUTING 1 \
  -o eth2 -p tcp -j SNAT --to-source 10.9.2.1:30000-30999
```
✅ 실측: 즉시 `succeeded! real 0m0.001s`

---

## 7. 정리 / 교훈
- 상태형 장비를 지나는 순간, 연결의 생사는 양 끝이 아니라 **중간의 기억**에도 달려 있다.
- **"오래 조용하던 연결이 죽었다"** → idle timeout을 의심 (증상: 에러 없는 무응답 + 재전송).
  대책: keepalive(앱) 또는 timeout 상향(장비) — **양쪽 다 아는 사람이 협상하라.**
- **"기존은 되는데 새 연결만 안 됨"** → 포트/상태 테이블 고갈. `conntrack -S`의
  insert_failed가 물증이다.
- 이 장의 지식은 11장의 재료다: 상태형 장비는 **왕복을 같은 곳에서 봐야** 기억이 성립한다.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| 상태 테이블 보기 | `conntrack -L` (둘째 숫자 = 남은 수명) |
| 실시간 이벤트 | `conntrack -E` |
| 통계(실패 포함) | `conntrack -S` → insert_failed |
| established timeout | `sysctl net.netfilter.nf_conntrack_tcp_timeout_established` |
| SNAT 포트 범위 | `iptables -t nat -v -L POSTROUTING` |

## 9. 랩 정리
```sh
./clab.sh destroy 09-conntrack/09-conntrack.clab.yml
```

---
### 다음 장 예고
conntrack이 "번역표"라는 걸 봤다. 그럼 그 번역(NAT) 자체는 왜 필요하고 무엇을 바꾸나 —
**소스 재작성의 본질** → **10장**, 그리고 그것이 경로 비대칭과 만나면 → **11장**.
