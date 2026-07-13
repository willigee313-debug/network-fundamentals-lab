# 04장 모범 답안 — 전체 명령 실행 기록

> 증상 → 편도 관찰 → 원인 → 수정 → 변형 2종까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 04-l3-routing/04-l3-routing.clab.yml   # → h1, r1, r2, h2 running (r2 리턴 라우트 누락 장전)
```

## 단계 A-① — 발신자의 판단부터
**의도**: 진단의 시작은 항상 "내(h1) 커널은 이 목적지를 어떻게 보내려 하나".
```sh
docker exec clab-04-l3-routing-h1 ip route get 10.4.2.10
```
```
10.4.2.10 via 10.4.1.1 dev eth1 src 10.4.1.10
```
**해석**: `via 10.4.1.1` — 다른 서브넷이므로 게이트웨이(r1)로 넘긴다. h1 쪽 판단엔 문제가 없다.
(01장의 즉시-에러와 달리 **일단 보내긴 한다**는 뜻.)

## 단계 A-② — 증상
```sh
docker exec clab-04-l3-routing-h1 ping -c2 10.4.2.10
```
```
2 packets transmitted, 0 received, 100% packet loss
```
**해석**: 즉시 에러가 아닌 **타임아웃** — 패킷은 나갔는데 소식이 없다. 원인 후보가 넓은 부류.

## 단계 A-③ — traceroute로 좁히기
```sh
docker exec clab-04-l3-routing-h1 traceroute -n -w1 -q1 -m4 10.4.2.10
```
```
 1  10.4.1.1  0.006 ms     ← r1은 응답
 2  *
 3  *                      ← r2부터 어둠
```
**해석**: "r1 다음에서 뭔가 잘못된다"까지 좁혀졌다. 단, `*`의 의미는 중의적이다 —
**그 홉이 죽었거나, 그 홉의 응답이 돌아올 길이 없거나.** 이걸 가르는 게 다음 단계.

## 단계 B-① — 결정적 관찰: 반대편 끝에서 캡처
**의도**: 요청이 목적지까지 **가긴 하는지**를 h2에서 직접 본다. `*`의 중의성을 해소하는 열쇠.
```sh
docker exec clab-04-l3-routing-h2 tcpdump -nli eth1 icmp     # 켜두고 h1에서 ping
```
```
10.4.1.10 > 10.4.2.10: ICMP echo request                    ← ① 요청은 도달했다!
10.4.2.10 > 10.4.1.10: ICMP echo reply                       ← ② h2는 응답했다!
10.4.2.1  > 10.4.2.10: ICMP net 10.4.1.10 unreachable        ← ③ r2가 그 응답을 반송했다!
```
**해석**: 세 줄이 사건 전체를 진술한다 — 포워드 경로는 완벽, h2도 무죄. 죽은 것은 **리턴**이고,
심지어 r2(10.4.2.1)가 h2에게 "10.4.1.10으로 가는 길이 없다"고 ICMP로 자백까지 했다.
h1에서는 이 자백이 안 보인다(자백도 h2에게 갔으므로) — **한쪽 끝의 침묵이 사건의 전부가 아니다.**

## 단계 B-② — 원인을 r2에게 직접 묻기
```sh
docker exec clab-04-l3-routing-r2 ip route get 10.4.1.10
docker exec clab-04-l3-routing-r2 ip route show
```
```
RTNETLINK answers: Network unreachable      ← r2는 클라 대역으로 가는 길을 모른다
10.4.0.0/30 dev eth1 ...
10.4.2.0/24 dev eth2 ...                    ← 테이블에 10.4.1.0/24가 없다
```
**해석**: 확정. r2의 테이블엔 직접 연결된 두 대역뿐 — 누군가 리턴 라우트를 안 넣었다(또는 지웠다).

## 단계 C — 한 줄 수정 + 판정
```sh
docker exec clab-04-l3-routing-r2 ip route replace 10.4.1.0/24 via 10.4.0.1
```
```
ping → 2 received, 0% packet loss
traceroute → 1 10.4.1.1 / 2 10.4.0.2 / 3 10.4.2.10     ← 모든 홉이 보인다
```
**해석**: 라우트 한 줄로 왕복 성립. traceroute의 `*`였던 홉들이 나타난 이유 — 그 홉들의
time-exceeded 응답도 **이 리턴 라우트를 타고** 돌아오기 때문. `*`가 "홉이 죽음"이 아니라
"응답의 귀로가 없음"이었음이 사후적으로 증명됐다.

## 변형 C-1 — `ip_forward=0`: 같은 타임아웃, 다른 지문
**의도**: 라우터가 포워딩을 멈춘 경우와 리턴 누락을 **캡처 위치로** 구분해 보기.
```sh
docker exec clab-04-l3-routing-r1 sysctl -w net.ipv4.ip_forward=0
```
```
ping → 100% packet loss                    (증상은 동일한 타임아웃)
h2 캡처: 0 패킷                            ← 이번엔 요청이 도달조차 안 한다!
```
**해석**: 기본 고장(리턴 누락)은 h2에 요청이 **왔었고**, 이 고장은 **오지도 않는다** —
tcpdump를 어디에 꽂느냐가 두 고장을 가른다. (r1 유입 인터페이스에서는 요청이 보이므로,
"r1이 받고 조용히 삼킨다"까지 특정 가능.) 복구: `sysctl -w net.ipv4.ip_forward=1`.

## 변형 C-2 — 기본 게이트웨이 누락: 01장의 콜백
```sh
docker exec clab-04-l3-routing-h1 ip route del default
docker exec clab-04-l3-routing-h1 ping -c1 10.4.2.10
```
```
ping: connect: Network unreachable          ← 타임아웃이 아니라 즉시 에러!
```
**해석**: 커널이 **보내기 전에** 실패를 안다(테이블에 길 없음) — 01장 실습 B와 같은 지문.
"즉시 에러 vs 타임아웃"만으로 고장 위치가 **내 쪽이냐 저 너머냐**로 갈린다.
복구: `ip route add default via 10.4.1.1`.

## 정리
```sh
./clab.sh destroy 04-l3-routing/04-l3-routing.clab.yml
```
**이 장의 판정 요약**: 즉시 에러=내 테이블 문제 · 타임아웃+h2 미도달=중간 소멸(포워딩) ·
타임아웃+h2 도달+응답 반송=리턴 누락. **tcpdump 꽂는 위치가 곧 진단이다.**
