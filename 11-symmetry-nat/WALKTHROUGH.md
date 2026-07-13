# 11장 모범 답안 — 전체 명령 실행 기록

> 증상 → 결정적 캡처 → 여정 재구성 → 수정 → 심화 비교(3종)까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 11-symmetry-nat/11-symmetry-nat.clab.yml   # → cli, edge, srtr, nat, srv running (비대칭 라우트 장전)
```

## 단계 A — 증상
```sh
docker exec clab-11-symmetry-nat-cli bash -c "time nc -zv -w 5 10.11.2.10 443"
```
```
timed out ... real 0m5.011s
```
**해석**: 08장 분류상 "조용한 실패"로 보인다. 그런데 정말 조용한지는 캡처가 판단한다.

## 단계 B — 결정적 장면: SYN-ACK의 소스를 보라
**의도**: 이 장애 전체를 판가름하는 단 하나의 관찰 — 클라이언트에서 응답의 **소스 IP** 확인.
```sh
docker exec clab-11-symmetry-nat-cli tcpdump -nli eth1 tcp port 443    # 켜두고 nc
```
```
10.11.1.10.34722 > 10.11.2.10.443: Flags [S]     ← ① 서버(10.11.2.10)로 SYN
10.11.4.1.443   > 10.11.1.10.34722: Flags [S.]   ← ② 응답이 왔다... 10.11.4.1?!
10.11.1.10.34722 > 10.11.4.1.443:  Flags [R]     ← ③ 커널: "모르는 상대" → RST
```
**해석**: **무응답이 아니었다!** SYN-ACK는 오고 있는데(ack 번호를 보면 분명 내 SYN에 대한 응답),
소스가 접속한 적 없는 10.11.4.1이라 커널이 소켓 매칭에 실패해 버린다. 08장 지문표의 어디에도
없는 제4의 지문: **"타임아웃 + 엉뚱한 소스의 SYN-ACK" = 비대칭 + 재작성.** 여기서 사실상 종결 —
남은 건 10.11.4.1이 누구고 왜 끼어들었는지의 역추적이다.

## 단계 C-① — 라우팅 결정: 범인은 srtr의 한 줄
```sh
docker exec clab-11-symmetry-nat-srtr ip route get 10.11.1.10
```
```
10.11.1.10 via 10.11.3.2 dev eth3     ← 클라 대역 리턴을 nat(10.11.3.2)로 보내는 중
```
**해석**: 서버의 응답이 클라로 돌아가는 길목(srtr)에서 nat 쪽으로 꺾이고 있다.
포워드(cli→srv)는 nat를 안 거치므로 **리턴만** 비대칭.

## 단계 C-② — 재작성의 현장: nat 통과 전/후
**의도**: 같은 패킷을 nat의 유입(eth1)/유출(eth2) 인터페이스에서 동시에 캡처 — 변조 순간 포착.
```
[eth1 유입] IP 10.11.2.10.443 ...     ← 소스 = srv (원본)
[eth2 유출] IP 10.11.4.1.443  ...     ← 소스 = nat (재작성됨!)
```
**해석**: 장비 하나를 사이에 두고 소스가 바뀌는 현장. 다지점 캡처의 힘 — 한 지점에서는
"이상한 패킷"일 뿐이지만, 전/후를 겹치면 **누가 바꿨는지**가 확정된다.

## 단계 D — 한 줄 수정 + 판정
```sh
./11-symmetry-nat/fix.sh    # srtr: ip route replace 10.11.1.0/24 via 10.11.0.1 (edge로)
```
```
echo hi | nc → pong (real 0m0.002s)
cli 캡처의 SYN-ACK: IP 10.11.2.10.443 >     ← 소스가 서버 본인!
```
**해석**: 리턴이 대칭 경로(edge)로 돌아오자 소스가 보존되고 즉시 성공. 수정 확인도
같은 관찰(SYN-ACK 소스)로 — 진단과 검증이 같은 도구를 쓴다.

## 단계 E — 심화: 같은 비대칭, 세 가지 운명 (비교 실측)

**E-1. 재작성 제거 (nat = 순수 라우터)** — 비대칭 라우트는 그대로 두고:
```sh
docker exec clab-11-symmetry-nat-nat nft flush table ip rewrite
```
```
echo hi | nc → pong    ← 비대칭인데 멀쩡하다!
```
**해석**: 소스가 보존되면 클라는 경로 따위 신경 쓰지 않는다.
**문제는 비대칭 자체가 아니라, 비대칭 + 재작성(또는 상태 검사)의 조합**이다.

**E-2. conntrack masquerade로 교체 (전형적 리눅스 NAT)**:
```sh
docker exec clab-11-symmetry-nat-nat iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE
```
```
nc -zv (connect만)   → succeeded          ← 포트 체크·헬스체크는 통과!
echo hi | nc (데이터) → 데이터 수신: []     ← pong이 영원히 안 옴
```
**해석**: 가장 교묘한 변종. conntrack은 midstream SYN-ACK를 INVALID로 보고 **NAT 없이 통과**
(→ 핸드셰이크 성공), 그 다음 패킷부터 픽업해 재작성(→ 데이터만 사망). 모니터링은 초록불인데
실 서비스만 죽는 형태 — 상태형 장비의 상태 판정이 증상을 조각낸다.

| nat의 동작 | 실측 증상 |
|---|---|
| 없음 (순수 라우터) | 정상 (pong) |
| stateless 재작성 (기본 장전) | connect부터 타임아웃 + 엉뚱한 소스의 SYN-ACK |
| stateful masquerade | connect 성공, **데이터만 사망** (`수신: []`) |

## 정리
```sh
./clab.sh destroy 11-symmetry-nat/11-symmetry-nat.clab.yml
```
**이 장의 판정 요약**: 타임아웃이라고 다 침묵이 아니다 — **클라에서 SYN-ACK의 소스**를 보라.
접속한 IP와 다르면 "비대칭 + 재작성" 확정 → 각 라우터의 `ip route get <클라IP>` 연쇄로 꺾인
지점을 찾고 → 대칭 경로로 한 줄 수정.
