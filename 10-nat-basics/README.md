# 10장. NAT 기본 — SNAT/DNAT, 헤더를 고쳐 쓰는 장비

> 09장에서 상태 테이블(번역표)을 읽었다. 이 장은 그 번역이 **왜 필요하고, 무엇을 바꾸는지**다.
> NAT는 지나가는 패킷의 **소스(또는 목적지) IP:포트를 고쳐 쓴다.** 이 단순한 조작이
> 사설망과 인터넷을 잇는 마법이자 — 11장에서 보게 될 — 수많은 장애의 씨앗이다.

## 0. 학습 목표
- **왜 SNAT가 필요한가**: "인터넷은 사설 대역으로 돌아오는 길을 모른다"를 실측으로
- **SNAT**(소스 재작성, egress)와 **DNAT**(목적지 재작성, 포트 공개)의 방향 감각
- conntrack 번역표로 **왕복 역번역** 확인
- 부작용의 예고: **서버는 클라이언트의 진짜 IP를 모르게 된다**

---

## 1. 개념

### 1-1. 왜 소스를 바꿔야 하나
- 사설 대역(10/8, 172.16/12, 192.168/16)은 **인터넷에서 라우팅되지 않는다** — 전 세계 수억 개의
  10.0.0.x가 있는데 어디로 돌려보내겠는가. 인터넷 라우터는 이 대역을 모르거나 버린다(BCP38).
- 그래서 사설망의 패킷이 밖으로 나갈 때, NAT 장비가 **자신의(공인) IP로 소스를 바꿔치기**한다
  = **SNAT/MASQUERADE**. 응답은 NAT에게 돌아오고, NAT는 번역표(09장!)를 보고 원 주인에게 돌려준다.

### 1-2. 방향 감각
| | 언제 | 무엇을 바꾸나 | 용도 |
|---|---|---|---|
| **SNAT** | 나갈 때(egress, POSTROUTING) | **소스** IP:포트 | 사설→공인 (인터넷 접속) |
| **DNAT** | 들어올 때(ingress, PREROUTING) | **목적지** IP:포트 | 포트 공개 (서비스 노출) |

### 1-3. 대칭성의 씨앗 (11장 예고)
- 번역표가 성립하려면 **왕복이 같은 NAT를 지나야** 한다. 이 전제가 깨지면? → 11장.

## 2. 토폴로지
```
          (사설망)               ("인터넷")
   cli ──────────── nat ──────────── srv(:80)
 10.10.1.10          │ eth2         10.10.2.10  ← unreachable 10.10.1.0/24 보유
                     │ eth3                        (인터넷의 현실 모사)
                    ext(10.10.3.20)              ← DNAT 실습용 외부 클라이언트
```
**장전 상태**: nat에 **MASQUERADE 없음**(고장) / DNAT 규칙(`:8080→cli:80`)은 장전됨 /
srv에는 `unreachable 10.10.1.0/24` — "인터넷은 사설 대역으로 돌아오는 길이 없다"의 모사 장치.

## 3. 실습 준비
```sh
./clab.sh deploy 10-nat-basics/10-nat-basics.clab.yml
```
> 노드 이름: `clab-10-nat-basics-<cli|nat|srv|ext>`

---

## 4. 실습 A — SNAT가 없으면: 도달하지만 돌아오지 못한다

**① 증상**
```sh
docker exec clab-10-nat-basics-cli bash -c "time nc -zv -w 4 10.10.2.10 80"
# → timed out ... real 0m4.010s     (실측)
```

**② srv에서 캡처 — 놀랍게도 SYN은 도달해 있다**
```sh
docker exec clab-10-nat-basics-srv tcpdump -nli eth1 tcp port 80
```
✅ 실측:
```
10.10.1.10.58406 > 10.10.2.10.80: Flags [S] ...   ← 사설 소스가 그대로 "인터넷"에 도착!
10.10.1.10.58406 > 10.10.2.10.80: Flags [S] ...   ← 재전송만 반복
(srv가 내보내는 패킷: 0개)
```
**③ srv는 왜 침묵하나**
```sh
docker exec clab-10-nat-basics-srv ip route get 10.10.1.10
# RTNETLINK answers: Host is unreachable            (실측)
```
**해설**: 라우팅(포워드)은 됐다 — 04장의 지식만으론 설명이 안 되는 상황. srv는 SYN을 받고
SYN-ACK를 만들었지만 **10.10.1.10으로 돌아가는 길이 세상에 없어서** 보내지 못한다.
사설 IP로 인터넷에 나간 패킷의 운명이 정확히 이렇다.

**④ 한 줄 수정 — 소스를 빌린다**
```sh
docker exec clab-10-nat-basics-nat iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE
```
✅ **성공 판정** (실측):
```sh
docker exec clab-10-nat-basics-cli bash -c "echo hi | nc 10.10.2.10 80"
# pong-from-srv                                      ← 응답 수신!
```
srv 캡처 (실측):
```
10.10.2.1.53526 > 10.10.2.10.80: Flags [S]          ← 소스가 nat IP(10.10.2.1)로 바뀌었다
10.10.2.10.80 > 10.10.2.1.53526: Flags [S.]         ← srv는 "인접한 nat"에게 응답 → 성공
```
nat의 번역표 (실측):
```
src=10.10.1.10 sport=53526 dport=80  ↔  응답방향 dst=10.10.2.1 dport=53526
```
**교훈**: 성공했지만 대가가 있다 — **srv가 본 클라이언트는 10.10.2.1(nat)이다.**
접속 로그, IP 기반 ACL, rate-limit이 전부 NAT IP 기준이 된다. (X-Forwarded-For가 필요한 이유)

## 5. 실습 B — DNAT: 포트 공개 (반대 방향 재작성)

외부(ext)가 nat의 `:8080`으로 접속하면 사설망의 cli`:80`으로 넘겨준다 (규칙 장전됨):
```sh
docker exec clab-10-nat-basics-ext bash -c "echo hi | nc 10.10.3.1 8080"
# pong-from-cli                                      (실측 — 성공)
```
cli에서 캡처 (실측):
```
10.10.3.20.51944 > 10.10.1.10.80: Flags [S]
   └─ 소스는 ext 그대로,  └─ 목적지가 nat:8080 → cli:80으로 재작성되어 도착
```
nat의 번역표 (실측):
```
src=10.10.3.20 dst=10.10.3.1 dport=8080  ↔  응답방향 src=10.10.1.10 sport=80
```
**해설**: DNAT는 **목적지만** 바꾼다(소스 보존). 응답은 cli→(default)→nat에서 번역표로
**역번역**되어 ext에게는 `10.10.3.1:8080`이 응답한 것처럼 보인다. 왕복이 nat를 지나므로 성립 —
만약 cli의 default가 nat가 아니라면? 그 이야기가 16장(헤어핀)과 11장(대칭성)이다.

---

## 6. 정리 / 교훈
- **SNAT 없는 사설→공인 = 편도 티켓.** 도달하고도 응답을 받을 수 없다. (증상은 타임아웃 —
  04장 리턴 라우트 누락과 같은 지문이지만, 이번엔 "세상 어디에도 리턴 경로가 없는" 경우)
- NAT는 **헤더를 고쳐 쓰고 그 기억(conntrack)으로 역번역**한다. 왕복이 NAT를 지나야 성립.
- **소스 재작성의 대가**: 상대는 나의 진짜 IP를 모른다. 로그/ACL/보안 정책 설계에 직결.
- SNAT=나갈 때 소스, DNAT=들어올 때 목적지 — 방향 감각이 절반이다.

## 7. 치트시트
| 목적 | 명령 |
|---|---|
| SNAT(동적) | `iptables -t nat -A POSTROUTING -o <if> -j MASQUERADE` |
| DNAT(포트 공개) | `iptables -t nat -A PREROUTING -i <if> -p tcp --dport <p> -j DNAT --to-destination <ip:p>` |
| NAT 규칙 보기 | `iptables -t nat -vnL` |
| 번역표 | `conntrack -L` |

## 8. 랩 정리
```sh
./clab.sh destroy 10-nat-basics/10-nat-basics.clab.yml
```

---
### 다음 장 예고
08(증상 읽기) + 09(상태) + 10(소스 재작성)이 합성된다 — 리턴 경로가
NAT를 "스치기만" 해도 연결이 통째로 죽는, 실무에서 가장 교묘한 장애 → **11장**.
