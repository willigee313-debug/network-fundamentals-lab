# 01장 모범 답안 — 전체 명령 실행 기록

> README 실습 A(정상)·B(서브넷 불일치)·C(중복 IP)를 처음부터 끝까지 실행한 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 01-l2-arp/01-l2-arp.clab.yml     # → h1, h2, h3, sw 4노드 running (전부 정상 상태)
```

---

## 실습 A — 정상 통신과 ARP

### A-① 주소/경로 확인
**의도**: 출발 전 기준선 — h1의 주소와 "10.10.10.0/24는 직접 연결"임을 확인.
```
inet 10.10.10.1/24 scope global eth1
10.10.10.0/24 dev eth1 proto kernel scope link
```
**해석**: `scope link` = 라우터 없이 직접 닿는 대역. 이 랩엔 default가 없다(순수 L2).

### A-②~④ ARP를 엿들으며 첫 ping
**의도**: "IP 통신 전에 반드시 ARP가 선행한다"를 패킷으로 증명. 캐시를 지워야(`ip neigh flush all`)
ARP가 새로 발생한다.
```sh
# h2: tcpdump -e -ni eth1 arp  /  h1: ip neigh flush all && ping -c1 10.10.10.2
```
```
aa:c1:ab:30:ac:d9 > ff:ff:ff:ff:ff:ff  ARP Request who-has 10.10.10.2 tell 10.10.10.1
aa:c1:ab:21:22:8d > aa:c1:ab:30:ac:d9  ARP Reply 10.10.10.2 is-at aa:c1:ab:21:22:8d
(그 뒤 ping: 1 received, 0% loss, ttl=64)
```
**해석**: 첫 프레임의 목적지가 `ff:ff:ff:ff:ff:ff`(**브로드캐스트**) — "10.10.10.2 누구야?"를
전원에게 방송. 응답은 h1의 MAC으로 **유니캐스트** — "나야, 내 MAC은 이거." 이 왕복이 끝나야
ICMP가 출발할 수 있다.

### A-⑤ 학습된 캐시
```
10.10.10.2 dev eth1 lladdr aa:c1:ab:21:22:8d REACHABLE
```
**해석**: IP↔MAC 매핑이 캐시됨(`REACHABLE`). 다음 ping부터는 ARP 없이 바로 나간다 —
그래서 "간헐 장애"를 볼 땐 캐시 상태(`ip neigh`)부터 의심하게 된다(실습 C의 복선).

---

## 실습 B — 서브넷 불일치: "같은 선에 꽂혀 있는데 왜 안 돼?"

### B-① 고장 주입
**의도**: 물리적으론 같은 스위치에 있으면서 IP만 다른 서브넷(10.10.**20**.2/24)인 상황 재현.
```sh
docker exec clab-01-l2-arp-h2 bash -c "ip addr flush dev eth1 && ip addr add 10.10.20.2/24 dev eth1"
```

### B-② h1에서 시도
**의도**: h1이 이 목적지를 어떻게 판단하는지, 그리고 어떤 증상이 나는지.
```
ip route get 10.10.20.2 → RTNETLINK answers: Network unreachable
ping 10.10.20.2         → ping: connect: Network unreachable
```
**해석**: **타임아웃이 아니라 즉시 에러**라는 점이 핵심. h1의 커널은 자기 테이블(10.10.10.0/24뿐)에
10.10.20.x로 가는 길이 없음을 **보내기도 전에** 안다 → ARP 시도조차 없음(h2에서 tcpdump를 켜도
아무것도 안 온다). 같은 케이블이어도 **IP+마스크가 "다른 네트워크"라고 판정하면 L2 직행은 없다.**
라우터가 있어야 하는 상황(04장).

### B-④ 되돌리기
```sh
docker exec clab-01-l2-arp-h2 bash -c "ip addr flush dev eth1 && ip addr add 10.10.10.2/24 dev eth1"
```

---

## 실습 C — 중복 IP: "가끔 되고 가끔 안 돼요"

### C-① 고장 주입
**의도**: h3에 h2와 같은 10.10.10.2를 부여 — 실무에서 수동 IP 할당이 겹칠 때 그대로.
```sh
docker exec clab-01-l2-arp-h3 ip addr add 10.10.10.2/24 dev eth1
```

### C-② arping으로 중복 검출
**의도**: 같은 IP에 **몇 개의 MAC이 응답하는지** 세기. ping은 이 상황을 못 가려낸다(먼저 온
응답만 쓰므로) — arping이 정답 도구인 이유.
```
h2 MAC: aa:c1:ab:21:22:8d / h3 MAC: aa:c1:ab:de:b5:19

Unicast reply from 10.10.10.2 [AA:C1:AB:DE:B5:19]   ← h3가 응답!
Unicast reply from 10.10.10.2 [AA:C1:AB:21:22:8D]   ← h2도 응답!
Unicast reply from 10.10.10.2 [AA:C1:AB:21:22:8D]
Unicast reply from 10.10.10.2 [AA:C1:AB:21:22:8D]
Sent 3 probes ... Received 4 response(s)             ← 질문 3에 답 4 = 범인 2명
```
**해석**: 판정 기준 두 가지가 다 보인다 — ① **서로 다른 MAC 두 개**가 같은 IP를 주장,
② **probe 수(3) < 응답 수(4)**. h1의 ARP 캐시는 먼저/나중에 도착한 응답에 따라 h2와 h3
사이를 오가고(플랩), 트래픽이 절반쯤 엉뚱한 호스트로 간다 → "가끔 되고 가끔 안 됨"의 실체.

### C-③ 되돌리기
```sh
docker exec clab-01-l2-arp-h3 bash -c "ip addr flush dev eth1 && ip addr add 10.10.10.3/24 dev eth1"
```

## 정리
```sh
./clab.sh destroy 01-l2-arp/01-l2-arp.clab.yml
```
**이 장의 판정 요약**: 정상 = ARP 왕복 후 ping 성공 · 서브넷 불일치 = **즉시** Network
unreachable(ARP 시도 없음) · 중복 IP = arping에 **MAC 2종 + probe<응답**.
