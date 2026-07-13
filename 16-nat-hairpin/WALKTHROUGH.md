# 16장 모범 답안 — 전체 명령 실행 기록

> 헤어핀 증상 → 이중 불일치 지문 → 교차 검증 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 16-nat-hairpin/16-nat-hairpin.clab.yml   # → sw, cli, srv, nat running (헤어핀 SNAT 없음 장전)
```

## 단계 A — 증상: 내부에서 공인 IP로 접속
```sh
docker exec clab-16-nat-hairpin-cli bash -c "time curl -s -m 4 http://10.16.99.1:8080/"
```
```
(타임아웃) real 0m4.009s
```
**해석**: 티켓의 전형: "외부에서는 잘 되는데(딴 데서 확인됨), **사내에서 우리 공인 주소로만**
안 열려요." 조용한 실패 계열 — 캡처로 간다.

## 단계 B — 결정적 지문: 주소도 포트도 다른 SYN-ACK
```sh
docker exec clab-16-nat-hairpin-cli tcpdump -nli eth1 'tcp port 8080 or tcp port 80'
```
```
10.16.1.10.50852 > 10.16.99.1.8080: Flags [S]     ← 공인 IP:8080으로 접속 시도
10.16.1.20.80   > 10.16.1.10.50852: Flags [S.]    ← 응답이 srv 실주소:80에서?!
10.16.1.10.50852 > 10.16.1.20.80:  Flags [R]      ← 커널: "모르는 상대" → RST
```
**해석**: 11장에선 SYN-ACK의 **주소**가 달랐는데, 여기선 **주소와 포트가 둘 다** 다르다
(8080→80, DNAT의 흔적까지 노출). ack 번호는 분명 내 SYN에 대한 응답 — 즉 서버는 받았고
응답도 했는데, **그 응답이 번역기(nat)를 거치지 않고 직접 왔다.** 11장의 대구(對句):
그땐 리턴이 NAT를 *불필요하게 경유*해서, 이번엔 *필요한데 건너뛰어서* 문제.

## 단계 C — 교차 검증: srv는 무엇을 봤나
**의도**: srv에 도착한 SYN의 소스를 확인 — 왜 srv가 직접 응답했는지 원인 규명.
```sh
docker exec clab-16-nat-hairpin-srv tcpdump -nli eth1 'tcp[tcpflags] & tcp-syn != 0'
```
```
10.16.1.10.52804 > 10.16.1.20.80: Flags [S]
```
**해석**: 두 가지가 보인다 — ① 목적지가 10.16.1.20:80 = **DNAT는 정상 동작**했다,
② 소스가 10.16.1.10 = **cli의 사설 주소 그대로**(DNAT는 목적지만 바꾸니까, 10장).
srv 입장에서 발신자는 같은 서브넷 이웃 → 게이트웨이 거칠 이유가 없어 L2로 직행(04장 원리)
→ 번역 미완성. 각 장비는 전부 "제 할 일"을 했는데 조합이 고장 — 이 장애의 얄미운 점.

## 단계 D — 한 줄 수정: 헤어핀 구간만 소스를 빌린다
```sh
./16-nat-hairpin/fix.sh
# = iptables -t nat -A POSTROUTING -o eth1 -s 10.16.1.0/24 -d 10.16.1.20 -p tcp --dport 80 -j MASQUERADE
```
```
curl → pong-hairpin (real 0m0.004s)
srv가 보는 소스: IP 10.16.1.1.52824 >      ← cli가 아니라 nat!
```
**해석**: 헤어핀 트래픽에 한해 소스를 nat(10.16.1.1)으로 바꿔 **srv의 응답이 반드시 nat을
지나게 강제** — 돌아온 응답은 un-DNAT+un-SNAT되어 cli에겐 `10.16.99.1:8080`의 답으로 보인다.
대가는 10장의 그것: srv 로그의 클라이언트가 전부 nat IP가 된다. 그래서 `-s/-d/--dport`로
**대가를 치르는 범위를 최소화**한 것. (대안: 스플릿 DNS — 내부에선 이름이 사설 IP로 풀리게)

## 정리
```sh
./clab.sh destroy 16-nat-hairpin/16-nat-hairpin.clab.yml
```
**이 장의 판정 요약**: "밖에선 되는데 안에서 공인 IP로만 안 됨" → cli 캡처에서 SYN-ACK의
**주소·포트 이중 불일치** 확인 → srv 캡처로 "DNAT은 됐고 소스가 사설 그대로" 교차 검증 →
헤어핀 SNAT(범위 최소화) 또는 스플릿 DNS.
