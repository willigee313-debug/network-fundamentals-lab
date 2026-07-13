# 05장 모범 답안 — 전체 명령 실행 기록

> 킬러 증상 → 범인 추적 → 변형 비교 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 05-lpm-blackhole/05-lpm-blackhole.clab.yml   # → h1, r1, h2 running (blackhole /32 장전)
```

## 단계 A — 킬러 증상: 대조군을 만들어 두드린다
**의도**: 문제 IP(.10)만 치지 말고 **옆 IP(.11)를 대조군으로** 함께 — 고장의 "반경"을 재기 위해.
```sh
docker exec clab-05-lpm-blackhole-h1 ping -c2 10.5.2.11
docker exec clab-05-lpm-blackhole-h1 ping -c2 10.5.2.10
```
```
10.5.2.11 → 2 received, 0% packet loss      ← 옆 IP는 멀쩡
10.5.2.10 → 0 received, 100% packet loss    ← 이 IP만 조용히 죽음
```
**해석**: 반경이 "딱 한 IP"다. 호스트째 죽으면 L2(01장), 서브넷째 죽으면 라우트 누락(04장),
**한 IP만 죽으면 /32 구체 경로**를 의심 — 반경이 곧 용의자 목록이다.

## 단계 B-① — `ip route get` 대조: 기묘한 에러가 힌트
**의도**: r1(경로상의 라우터)이 두 IP를 각각 어떻게 판단하는지 나란히 묻기.
```sh
docker exec clab-05-lpm-blackhole-r1 ip route get 10.5.2.11
docker exec clab-05-lpm-blackhole-r1 ip route get 10.5.2.10
```
```
10.5.2.11 dev eth2 src 10.5.2.1              ← 정상: 연결된 /24로 직행
RTNETLINK answers: Invalid argument           ← .10만 에러?!
```
**해석**: "Invalid argument"는 언뜻 명령 오타처럼 보이지만, **blackhole 라우트에 매칭될 때
커널이 내는 특유의 지문**이다. 낯선 에러 = 특수 라우트(blackhole/prohibit) 의심.

## 단계 B-② — 테이블에서 범인 확인
```sh
docker exec clab-05-lpm-blackhole-r1 ip route show
```
```
10.5.1.0/24 dev eth1 ...
10.5.2.0/24 dev eth2 ...     ← 정상 경로는 멀쩡히 존재한다!
blackhole 10.5.2.10          ← 그러나 /32가 더 구체적이라 LPM으로 이긴다
```
**해석**: 핵심 교훈이 이 세 줄에 있다 — "경로가 있느냐"는 질문은 틀렸고, **"이 목적지에 누가
이기느냐"** 가 맞는 질문이다. /24가 버젓이 있어도 /32가 낚아채면 무용지물.

## 단계 B-③ — traceroute: 첫 홉부터 전멸
```sh
docker exec clab-05-lpm-blackhole-h1 traceroute -n -w1 -q1 -m3 10.5.2.10
```
```
 1  *
 2  *
 3  *
```
**해석**: 04장(리턴 누락)에서는 1번 홉(r1)이 응답했지만 여기선 **그마저 없다.** 블랙홀 드랍은
라우팅 단계에서 일어나 TTL 처리(time-exceeded 생성)에 도달하기도 전에 패킷이 사라지기 때문.
"첫 홉부터 전부 `*`" = 강한 블랙홀 신호로 기억.

## 단계 C — 변형: unreachable로 바꾸면 증상이 바뀐다
**의도**: 같은 /32 차단이라도 라우트 타입에 따라 발신자가 보는 증상이 어떻게 다른지.
```sh
docker exec clab-05-lpm-blackhole-r1 ip route replace unreachable 10.5.2.10/32
docker exec clab-05-lpm-blackhole-h1 ping -c1 10.5.2.10
```
```
From 10.5.1.1 icmp_seq=1 Destination Host Unreachable    ← 즉시, r1이 발신자에게 통보
```
**해석**: blackhole=침묵(타임아웃) vs unreachable=**즉시 통보**. 차단 결과는 같아도 지문이 다르다
— 발신자가 보는 증상만으로 중간 장비의 처리 방식을 역추론할 수 있다(08장에서 TCP로 확장).

## 단계 D — 한 줄 수정 + 판정
```sh
docker exec clab-05-lpm-blackhole-r1 ip route del unreachable 10.5.2.10/32   # (기본 상태면 del blackhole)
```
```
ping 10.5.2.10 → 2 received, 0% packet loss
ip route get 10.5.2.10 → 10.5.2.10 dev eth2 src 10.5.2.1     ← 이제 /24가 답한다
```
**해석**: /32를 지우는 순간 그 목적지의 심판권이 /24로 돌아온다. 수정 확인도
`ip route get`으로 — "누가 이기는지"가 바뀌었음을 눈으로 확정.

## 정리
```sh
./clab.sh destroy 05-lpm-blackhole/05-lpm-blackhole.clab.yml
```
**이 장의 판정 요약**: 반경이 "딱 한 IP" → /32 의심 → `route get`의 기묘한 에러 + 테이블의
특수 라우트로 확정 → 삭제 → `route get`이 /24를 가리키면 완치.
