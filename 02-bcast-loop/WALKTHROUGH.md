# 02장 모범 답안 — 전체 명령 실행 기록

> 실습 A(MAC 학습/플러딩)·B(스톰 점화)·수정(STP)을 처음부터 끝까지 실행한 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 02-bcast-loop/02-bcast-loop.clab.yml   # → h1, h2, sw1, sw2 running (루프 링크는 down)
```

---

## 실습 A — 스위치의 MAC 학습

### A-① 트래픽 전 FDB
**의도**: 스위치가 아직 아무것도 "배우지 않은" 기준선 확인.
```sh
docker exec clab-02-bcast-loop-sw1 bash -c "bridge fdb show br0 | grep -v permanent"
```
```
(출력 없음 — 학습된 엔트리 0)
```
**해석**: permanent(자기 자신)를 빼면 비어 있다. 스위치의 지식은 트래픽에서만 생긴다.

### A-② ping 1회 후 FDB
**의도**: 프레임 한 왕복만으로 스위치가 무엇을 배우는지.
```
ping → 1 received, 0% loss
aa:c1:ab:d9:f4:26 dev eth1    ← h1의 MAC이 eth1(h1쪽 포트)에
aa:c1:ab:82:cd:df dev eth2    ← h2의 MAC이 eth2(sw2 방향 트렁크)에
```
**해석**: "이 MAC은 이 포트 너머에 산다"가 정확히 기록됐다. 이후 h2행 프레임은 eth2로만 나간다
— 플러딩이 아닌 **선택적 전달**, 스위치 성능의 비밀.

### A-③ 모르는 목적지 = 플러딩
**의도**: FDB에 없는 MAC으로 보내면 어떻게 되는지 — h2가 "남의 프레임"을 받는지 확인.
```sh
# h1: ip neigh replace 10.2.0.99 lladdr 02:de:ad:be:ef:99 dev eth1 && ping 10.2.0.99
# h2에서 캡처:
aa:c1:ab:d9:f4:26 > 02:de:ad:be:ef:99 ... 10.2.0.1 > 10.2.0.99: ICMP echo request
```
**해석**: h2는 자기 것이 아닌(목적지 MAC이 다른) 프레임을 받았다 = **unknown unicast 플러딩**.
"모르면 전 포트로 뿌린다"는 이 성질이, 다음 실습에서 루프와 만나 재앙이 된다.

---

## 실습 B — 루프 점화: 브로드캐스트 스톰

### B-①② 기준 카운터 기록 → 루프 완성 → 점화
**의도**: 스톰을 **정량**으로 잡기 위해 점화 전 수신 카운터를 기록해 두고, 고장(두 번째 링크 up)을
주입한 뒤 ping의 ARP 브로드캐스트 1발로 점화.
```sh
docker exec clab-02-bcast-loop-h2 cat /sys/class/net/eth1/statistics/rx_packets   # → 7
docker exec clab-02-bcast-loop-sw1 ip link set eth3 up                            # 고장 주입(한 줄)
docker exec clab-02-bcast-loop-h1 bash -c "ip neigh flush all; ping -c2 -W1 10.2.0.2"
```
```
2 packets transmitted, 0 received, 100% packet loss     ← 스톰 속에서 ping이 오히려 죽는다
```
**해석**: 점화 직전까지 멀쩡히 되던 ping(실습 A)이 **루프가 생기는 순간 실패**한다. 이유는 B-④에서.

### B-③ 정량 관찰 — 카운터 폭증
```
rx: 10,742 → 20,750  (증가 10,008 pkt / 2초)     ← 점화 전 누적은 겨우 7이었다
```
**해석**: 아무도 트래픽을 만들지 않는데 초당 5천 프레임이 돈다. ARP 1발이 두 링크로 복제되며
무한 순환 — **이더넷엔 TTL이 없어서 스스로 멈추지 않는다.**

### B-④ FDB 오염 — ping이 죽은 이유
```sh
docker exec clab-02-bcast-loop-sw1 bash -c "bridge fdb show br0 | grep <h2 MAC>"
```
```
aa:c1:ab:82:cd:df dev eth3    ← h2의 MAC이 eth3(루프 링크!)에서 학습돼 있다
```
**해석**: 실습 A에서 eth2였던 h2의 위치가 **eth3으로 바뀌어** 있다. 돌고 있는 복제 프레임이
h2의 소스 MAC을 달고 eth3으로 들어오기 때문 — 학습이 오염되면 유니캐스트도 길을 잃는다.
스톰이 "브로드캐스트만의 문제"가 아닌 이유.

### B-⑤ 캡처 — 같은 프레임의 무한 복제
```
10:52:32.788055  ARP Request who-has 10.2.0.2 ...
10:52:32.788063  ARP Reply 10.2.0.2 is-at ...
10:52:32.788056  ARP Request who-has 10.2.0.2 ...   ← 1µs 뒤 같은 요청이 또
```
**해석**: 타임스탬프가 µs 단위로 붙은 **동일 내용의 프레임들** — 새 트래픽이 아니라 복제다.
Reply(유니캐스트)까지 돌고 있다 = FDB 오염과 맞물려 유니캐스트도 순환 중.

---

## 수정 — STP

### 스톰 즉사
```sh
docker exec clab-02-bcast-loop-sw1 ip link set br0 type bridge stp_state 1
docker exec clab-02-bcast-loop-sw2 ip link set br0 type bridge stp_state 1
```
```
STP on 직후 rx: 31,660 → 31,660  (증가 0 pkt / 2초)     ← 10,008 → 0
```
**해석**: STP를 켜면 포트들이 일단 non-forwarding으로 되돌아가므로, 돌던 프레임이 그 자리에서
끊긴다. **증가율 0**이 즉사의 증거.

### 수렴(~35초) 후 판정
```
eth1: forwarding / eth2: forwarding / eth3: blocking   ← 루프의 한 포트만 논리적으로 잠김
ping → 3 received, 0% packet loss                       ← 루프 링크가 살아있는 채로 정상!
```
**해석**: 물리 링크는 두 개 다 살아 있지만(장애 시 예비), 논리적으로는 트리 — 이것이 STP의 목적.
"이중화하려고 선을 두 개 꽂는" 요구와 "루프는 안 된다"는 물리학의 타협점.

## 정리
```sh
./clab.sh destroy 02-bcast-loop/02-bcast-loop.clab.yml
```
**이 장의 판정 요약**: 스톰 = 트래픽 없는데 카운터 폭증 + 같은 프레임 복제 + FDB 플랩 ·
수정 = STP on 즉시 증가율 0 → 수렴 후 blocking 1포트 + ping 정상.
