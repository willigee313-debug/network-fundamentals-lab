# 12장 모범 답안 — 전체 명령 실행 기록

> 크기별 증상 → 블랙홀 관찰 → 두 처방 비교까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 12-mtu-pmtud/12-mtu-pmtud.clab.yml   # → h1, r1, r2, h2 running (중간 1400 + frag-needed 차단 장전)
```

## 단계 A — 크기가 운명을 가른다
**의도**: 같은 목적지에 **크기만 바꿔** 두드리기 — MTU 계열 고장의 시그니처 채집.
```sh
docker exec clab-12-mtu-pmtud-h1 ping -c2 -s 100 10.12.2.10          # 작은 것
docker exec clab-12-mtu-pmtud-h1 ping -M do -c2 -s 1472 10.12.2.10   # 1500B 프레임, DF
```
```
-s 100        → 0% packet loss
-s 1472 (DF)  → 100% packet loss   (에러 메시지 없음 — 침묵)
```
**해석**: "크기 의존 실패"는 강력한 지문이다 — 경로·포트·상태 문제라면 크기와 무관했을 것.
그리고 큰 쪽이 **에러 없이** 죽는다는 점이 이 장의 병명(블랙홀)을 예고한다.

## 단계 B — TCP 대량 전송
```sh
docker exec clab-12-mtu-pmtud-h1 iperf3 -c 10.12.2.10 -t 3
```
```
0.00 Bytes  0.00 bits/sec   receiver
```
**해석**: **연결은 성립했는데**(제어 패킷 = 작은 크기) 데이터가 0이다. 실무 번역:
"TLS 핸드셰이크는 되는데 응답에서 멎어요", "작은 API는 되는데 파일 업로드만 죽어요".

## 단계 C — tracepath: 발견의 실패
**의도**: 경로 MTU 발견(PMTUD)이 동작하는지 확인.
```sh
docker exec clab-12-mtu-pmtud-h1 tracepath -n 10.12.2.10
```
```
 1?: [LOCALHOST]   pmtu 1500        ← 여기서 멈춤. 1400의 존재를 끝내 못 배운다
```
**해석**: r1이 1500B DF 패킷을 버리며 만든 frag-needed(mtu=1400 통보)가 **차단**되고 있어서,
h1의 세계에는 1400이라는 정보 자체가 도착하지 않는다 = **PMTUD 블랙홀**.

## 단계 D — 처방① MSS clamp (응급처치, ICMP 차단 유지한 채)
**의도**: ICMP를 못 여는 상황(정책 협상 실패 등)의 응급처치가 실제로 듣는지 + 그 한계 확인.
```sh
docker exec clab-12-mtu-pmtud-r1 iptables -t mangle -A FORWARD \
  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```
```
iperf3            → 8.65 Gbits/sec        ← 0에서 부활!
ping -M do 1472   → 100% loss (여전히 침묵)
```
**해석**: clamp는 지나가는 **SYN의 MSS 값을 몰래 고쳐 써서** 양 끝이 처음부터 작게 보내게
만든다 — TCP엔 특효. 그러나 ping(ICMP)은 여전히 죽는다 = **TCP 외의 프로토콜엔 무력**.
증상을 가리는 처방임을 알고 쓸 것.

## 단계 E — 처방② ICMP 허용 (근본 수정)
```sh
./12-mtu-pmtud/fix.sh        # r1의 frag-needed 차단 해제
docker exec clab-12-mtu-pmtud-h1 ping -M do -c2 -s 1472 10.12.2.10
docker exec clab-12-mtu-pmtud-h1 ip route get 10.12.2.10
```
```
ping 응답:  ... Frag needed and DF set (mtu = 1400)     ← 침묵이 아니라 "정보"를 받는다!
route get:  ... mtu 1400                                 ← h1의 경로 캐시에 PMTU가 학습됨
iperf3:     8.65 Gbits/sec
tracepath:  2: 10.12.1.1 pmtu 1400 / Resume: pmtu 1400   ← 발견 성공
```
**해석**: 이 장의 백미 — ICMP를 허용하자 h1이 "이 경로는 1400까지"라는 사실을 **통보받고
캐시에 학습**한다(`ip route get`의 `mtu 1400`). 이후 모든 프로토콜이 자동으로 맞춰 보낸다.
처방①과의 차이: clamp는 TCP만 구제하는 가림막, ICMP 허용은 메커니즘 자체의 복원.

## 정리
```sh
./clab.sh destroy 12-mtu-pmtud/12-mtu-pmtud.clab.yml
```
**이 장의 판정 요약**: 크기 의존 실패 + 큰 쪽이 침묵 = MTU 블랙홀 → `ping -M do -s`로 경계
탐색, `tracepath`로 발견 여부 확인 → 근본은 frag-needed 허용(+`route get`에 mtu 캐시 확인),
응급은 MSS clamp(TCP 한정임을 명심).
