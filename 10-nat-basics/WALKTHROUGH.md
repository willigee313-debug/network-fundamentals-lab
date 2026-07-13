# 10장 모범 답안 — 전체 명령 실행 기록

> SNAT 부재의 증상 → 서버측 관찰 → 수정 → DNAT 확인까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 10-nat-basics/10-nat-basics.clab.yml   # → cli, nat, srv, ext running (MASQUERADE 없음 장전)
```

## 단계 A-① — 증상
```sh
docker exec clab-10-nat-basics-cli bash -c "time nc -zv -w 4 10.10.2.10 80"
```
```
timed out ... real 0m4.005s
```
**해석**: 08장 분류로 "조용한 실패" 부류. 다음 질문은 "SYN이 어디까지 갔나".

## 단계 A-② — 서버 쪽에서 캡처: 도달 여부 확인
**의도**: 04장에서 배운 "반대편 끝 캡처"를 그대로 적용.
```sh
docker exec clab-10-nat-basics-srv tcpdump -nli eth1 tcp port 80    # 켜두고 cli에서 nc
```
```
10.10.1.10.40424 > 10.10.2.10.80: Flags [S], seq 2551184735   ← 사설 소스 그대로 도착!
10.10.1.10.40424 > 10.10.2.10.80: Flags [S], seq 2551184735   ← 같은 seq 재전송만 반복
(srv가 내보내는 패킷: 0개)
```
**해석**: 두 가지가 이상하다 — ① SYN이 "인터넷"(srv측)에 **사설 소스(10.10.1.10) 그대로**
도착했다(라우팅 자체는 됨), ② srv가 받고도 **아무것도 내보내지 않는다**. 04장의 지식으론
"응답이 반송되는" 것까진 봤는데, 이번엔 응답이 아예 안 나온다 — 왜?

## 단계 A-③ — 서버의 사정을 직접 묻기
```sh
docker exec clab-10-nat-basics-srv ip route get 10.10.1.10
```
```
RTNETLINK answers: Host is unreachable
```
**해석**: srv는 SYN-ACK를 만들었지만 **10.10.1.10으로 돌아가는 길이 세상에 없어서** 보내지
못한다(이 랩에선 unreachable 라우트로 인터넷의 현실 — 사설 대역은 라우팅되지 않는다 — 을 모사).
04장 고장과 결정적 차이: 그땐 라우터 한 대의 실수였지만, 이번엔 **구조적으로 리턴 경로가
존재할 수 없는** 상황. 그래서 라우트 추가가 아니라 **소스를 바꾸는** 해법이 필요하다.

## 단계 A-④ — 한 줄 수정: 소스를 빌린다
```sh
./10-nat-basics/fix.sh     # iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE
docker exec clab-10-nat-basics-cli bash -c "echo hi | nc 10.10.2.10 80"
```
```
pong-from-srv                                        ← 응답 수신!

srv 캡처:
10.10.2.1.40426 > 10.10.2.10.80: Flags [S]           ← 소스가 nat IP(10.10.2.1)로 바뀌었다
10.10.2.10.80 > 10.10.2.1.40426: Flags [S.]          ← srv는 "옆집 nat"에게 응답 → 성공
```
**해석**: MASQUERADE 한 줄로 cli의 패킷이 **nat의 IP를 빌려** 나간다. srv 입장에선 발신자가
직접 연결된 이웃(10.10.2.1)이니 응답에 아무 문제가 없고, nat은 번역표(09장)로 원 주인에게
돌려준다. 대가: **srv가 본 클라이언트는 nat이다** — 접속 로그·IP 기반 ACL이 전부 nat IP 기준이
된다(X-Forwarded-For가 필요한 이유).

## 단계 B — DNAT: 반대 방향의 재작성 (포트 공개)
**의도**: 외부(ext)가 nat의 :8080으로 접속하면 사설망 cli:80으로 넘어가는지 + 무엇이 재작성되는지.
```sh
docker exec clab-10-nat-basics-ext bash -c "echo hi | nc 10.10.3.1 8080"
```
```
pong-from-cli                                        ← 성공

cli 캡처:
10.10.3.20.38684 > 10.10.1.10.80: Flags [S]
└ 소스는 ext 그대로   └ 목적지가 nat:8080 → cli:80으로 재작성되어 도착
```
**해석**: DNAT는 **목적지만** 바꾼다(소스 보존 — SNAT와 대칭). 응답은 cli의 default(nat)를
타고 돌아가며 역번역되므로 ext에겐 `10.10.3.1:8080`이 답한 것처럼 보인다. "cli의 default가
nat이 아니었다면?"이 16장(헤어핀)의 시나리오다.

## 정리
```sh
./clab.sh destroy 10-nat-basics/10-nat-basics.clab.yml
```
**이 장의 판정 요약**: 사설 소스가 그대로 도달 + 응답 0 + srv의 "Host is unreachable" =
SNAT 부재 → MASQUERADE 후 srv가 보는 소스가 nat IP로 바뀌면 완치. DNAT는 목적지만 재작성.
