# 00장 모범 답안 — 전체 명령 실행 기록

> README의 도구 투어를 처음부터 끝까지 실행한 기록. 각 단계마다
> **의도**(무엇을 확인하려는가) → **실측 결과** → **해석**(이 출력이 말하는 것).
> 실측: 2026-07-12 · macOS/Apple Silicon + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 00-onramp/playground.clab.yml     # → h1, h2 2노드 running
```

## 단계 ① — 내 주소 확인
**의도**: 인터페이스의 상태(UP/DOWN)와 IP/마스크를 한 줄로 읽는 습관 만들기.
```sh
docker exec clab-00-onramp-h1 ip -br addr show eth1
```
```
eth1@if465       UP             10.0.0.1/24 fe80::...::/64
```
**해석**: `eth1`은 살아 있고(UP), `10.0.0.1/24`를 갖고 있다. `-br`(brief)는 진단의 첫 30초에
가장 많이 치는 형태다. 뒤의 `fe80::`은 IPv6 링크로컬 — 이 시리즈에선 무시한다.

## 단계 ② — 라우팅 테이블
**의도**: "이 호스트가 아는 길"의 전체 목록 보기.
```sh
docker exec clab-00-onramp-h1 ip route
```
```
10.0.0.0/24 dev eth1 proto kernel scope link src 10.0.0.1
10.99.99.0/24 dev eth0 proto kernel scope link src 10.99.99.3
```
**해석**: 두 줄 다 `proto kernel scope link` = **직접 연결된** 대역(내가 그 서브넷의 일원).
`10.99.99.0/24`는 랩 관리망(eth0)이니 실습에선 무시. **default(기본 게이트웨이)가 없다**는 점에
주목 — 이 호스트는 이 두 대역 밖으로는 아무 데도 못 간다(04장에서 다룬다).

## 단계 ③ — 특정 목적지에 대한 판단
**의도**: 테이블 전체가 아니라 "**이 목적지**로는 어떻게 가나"를 커널에게 직접 묻기.
```sh
docker exec clab-00-onramp-h1 ip route get 10.0.0.2
```
```
10.0.0.2 dev eth1 src 10.0.0.1 uid 0
```
**해석**: "eth1로 **직접** 보낸다(via 없음), 소스는 10.0.0.1을 쓴다." — 같은 서브넷이므로
게이트웨이 없이 직행. `ip route get`은 이 시리즈 전체에서 가장 자주 쓰는 진단 명령이다.

## 단계 ④ — 왕복 확인
**의도**: 두 호스트 간 기본 연결성. 그리고 출력의 각 필드 읽는 법.
```sh
docker exec clab-00-onramp-h1 ping -c1 10.0.0.2
```
```
64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.052 ms
1 packets transmitted, 1 received, 0% packet loss
```
**해석**: `ttl=64` = 상대가 리눅스 기본값 64로 응답했고 중간에 라우터를 **하나도 안 지났다**
(홉마다 1씩 깎인다 — 06장). `0% packet loss`가 판정 기준. `time 0.052ms`는 같은 호스트 위
가상 링크라 매우 빠른 것.

## 단계 ⑤ — 패킷을 눈으로
**의도**: "상대 쪽에서 실제로 무엇이 오가는지"를 캡처로 확인하는 기본 동작 —
이 시리즈 진단의 최종 심급.
```sh
# (터미널1) docker exec clab-00-onramp-h2 tcpdump -nli eth1 icmp
# (터미널2) docker exec clab-00-onramp-h1 ping -c1 10.0.0.2
```
```
10.0.0.1 > 10.0.0.2: ICMP echo request, id 82, seq 1, length 64
10.0.0.2 > 10.0.0.1: ICMP echo reply,   id 82, seq 1, length 64
```
**해석**: 요청과 응답이 **쌍**으로 보인다 — 정상 왕복의 기준 형태. 이후 장들에서는 이 쌍이
"어디까지 가서 어느 방향이 끊겼는지"를 읽는 것이 진단의 핵심이 된다.

## 정리
```sh
./clab.sh destroy 00-onramp/playground.clab.yml
```
**이 장에서 확립된 것**: ① 상태 확인(`ip -br addr`) ② 길 확인(`ip route`, `ip route get`)
③ 왕복 확인(`ping`) ④ 실체 확인(`tcpdump`) — 이 4단 콤보가 모든 장의 뼈대다.
