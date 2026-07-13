# 02장. 브로드캐스트 도메인 & L2 루프 — 스위치는 어떻게 프레임을 옮기고, 왜 루프에 무너지는가

> 01장에서 "같은 네트워크 안에서 ARP로 서로를 찾는 것"을 배웠다. 이 장은 그 사이에 있는
> **스위치의 내부 동작(MAC 학습)** 을 들여다보고, 그 메커니즘이 **루프 앞에서 왜 무너지는지**
> (브로드캐스트 스톰)를 직접 점화해 관찰한다.

## 0. 학습 목표
- 스위치가 **MAC 학습(FDB/CAM 테이블)** 으로 프레임을 포워딩하는 과정
- 모르는 목적지 프레임은 **전 포트로 플러딩**된다는 것 (unknown unicast)
- 루프가 있으면 브로드캐스트 1발이 **무한 증폭(스톰)** 되고 FDB가 오염되는 과정
- **STP**가 루프를 어떻게 끊는지 (blocking 포트)

⚠️ **안전 수칙**: 이 랩의 스톰은 Docker VM 내부에 갇히지만 CPU를 폭식한다.
**관찰은 수 초 안에 끝내고**, 탈출 명령을 미리 띄워 놓고 시작하라:
```sh
docker exec clab-02-bcast-loop-sw1 ip link set eth3 down   # ← 비상 탈출(루프 절단)
```

---

## 1. 개념

### 1-1. 스위치의 실체 = MAC 학습 테이블(FDB/CAM)
- 스위치는 프레임이 **들어온 포트와 소스 MAC**을 기록한다(학습).
- 목적지 MAC이 테이블에 있으면 **그 포트로만** 전달, 없으면 **전 포트로 플러딩**.
- 브로드캐스트(`ff:ff:...`)는 항상 전 포트로. → 01장의 ARP가 모두에게 도달했던 이유.

### 1-2. 루프 = 증폭기
- 스위치 사이에 경로가 2개면(이중화 시도 등) 브로드캐스트가 **양쪽으로 복제되어 서로에게 돌아온다**.
- 이더넷 프레임엔 **TTL이 없다** → 한 번 돈 프레임을 끊을 방법이 없음 → 무한 증폭 = **브로드캐스트 스톰**.
- 부작용: 돌고 있는 프레임의 소스 MAC이 엉뚱한 포트에서 재학습됨 → **FDB 오염** → 유니캐스트도 길을 잃음.

### 1-3. STP (Spanning Tree Protocol)
- 스위치끼리 BPDU를 교환해 루프 구간의 **한 포트를 blocking**으로 잠근다 → 논리적으로 트리.
- 링크 장애 시 blocking 포트가 살아나 이중화 목적도 달성.

---

## 2. 토폴로지
```
  10.2.0.1                              10.2.0.2
     h1 ──── sw1 ═════════════ sw2 ──── h2
              │   eth2 ── eth2  │
              │   eth3 ── eth3  │        ← 두 번째 링크(배포 시 sw1쪽 down)
```
- 배포 직후에는 eth3 링크가 꺼져 있어 **정상 동작**한다. 실습 B에서 한 줄로 루프를 완성한다.
- 전 노드 IPv6 비활성: 켜두면 커널 IPv6 노이즈(MLD/RS)가 루프를 올리는 순간 **사용자 행동 없이도** 스톰을 점화한다.

## 3. 실습 준비
```sh
./clab.sh deploy 02-bcast-loop/02-bcast-loop.clab.yml
```
> 노드 이름: `clab-02-bcast-loop-<h1|h2|sw1|sw2>`

---

## 4. 실습 A — 스위치의 MAC 학습 눈으로 보기

**① 트래픽 전 FDB 확인 (학습된 것이 거의 없음)**
```sh
docker exec clab-02-bcast-loop-sw1 bash -c "bridge fdb show br0 | grep -v permanent"
```

**② h1→h2 ping 1회 후 다시 FDB**
```sh
docker exec clab-02-bcast-loop-h1 ping -c1 10.2.0.2
docker exec clab-02-bcast-loop-sw1 bash -c "bridge fdb show br0 | grep -v permanent"
```
실측 출력:
```
aa:c1:ab:01:bd:d0 dev eth1 master br0     ← h1의 MAC이 eth1(h1쪽 포트)에서 학습됨
aa:c1:ab:94:3f:f6 dev eth2 master br0     ← h2의 MAC이 eth2(sw2 방향)에서 학습됨
```
**해설**: 스위치는 "이 MAC은 이 포트 너머에 있다"를 기억하고, 이후 그 포트로만 보낸다.

**③ 모르는 목적지 = 플러딩 (h2가 남의 프레임을 받는다)**
```sh
# (터미널1) h2에서 엿듣기
docker exec clab-02-bcast-loop-h2 tcpdump -e -nli eth1 icmp
# (터미널2) h1에서 존재하지 않는 MAC으로 강제 전송
docker exec clab-02-bcast-loop-h1 ip neigh replace 10.2.0.99 lladdr 02:de:ad:be:ef:99 dev eth1
docker exec clab-02-bcast-loop-h1 ping -c2 -W1 10.2.0.99
```
✅ **성공 판정** — h2 tcpdump에 **자기 것이 아닌** 프레임이 뜬다 (실측):
```
aa:c1:ab:01:bd:d0 > 02:de:ad:be:ef:99, ethertype IPv4: 10.2.0.1 > 10.2.0.99: ICMP echo request
```
**해설**: FDB에 없는 MAC은 전 포트로 플러딩된다. "스위치는 몰라도 일단 뿌린다" — 이 성질이 루프와 만나면 재앙이 된다.

---

## 5. 실습 B — 루프 점화: 브로드캐스트 스톰

**① 관찰 준비 (점화 전 카운터 기록 + 캡처 대기)**
```sh
docker exec clab-02-bcast-loop-h2 cat /sys/class/net/eth1/statistics/rx_packets   # 기준값
docker exec clab-02-bcast-loop-h2 bash -c "timeout 6 tcpdump -e -nli eth1 -c 20 arp > /tmp/storm.txt 2>/dev/null" &
```

**② 고장 주입(한 줄) + 점화**
```sh
docker exec clab-02-bcast-loop-sw1 ip link set eth3 up          # 루프 완성
docker exec clab-02-bcast-loop-h1 bash -c "ip neigh flush all; ping -c2 -W1 10.2.0.2"
```
실측 출력 — **스톰 속에서 ping은 오히려 죽는다**:
```
2 packets transmitted, 0 received, 100% packet loss
```

**③ 정량 관찰 — 카운터 폭증**
```sh
docker exec clab-02-bcast-loop-h2 cat /sys/class/net/eth1/statistics/rx_packets  # 2초 간격 2회
```
실측: 점화 전 누적 **9 pkt** → 점화 후 **2초에 +9,974 pkt** (계속 증가).

**④ 캡처 읽기 — 같은 ARP의 무한 복제** (실측, µs 간격으로 동일 프레임 반복):
```
21:55:02.338388 ... ARP Request who-has 10.2.0.2 tell 10.2.0.1
21:55:02.338390 ... ARP Request who-has 10.2.0.2 tell 10.2.0.1   ← 2µs 뒤 같은 프레임
21:55:02.338402 ... ARP Request who-has 10.2.0.2 tell 10.2.0.1   ← 또
```

**⑤ FDB 오염 확인 — ping이 죽은 이유**
```sh
docker exec clab-02-bcast-loop-sw1 bash -c "bridge fdb show br0 | grep <h2의 MAC>"
```
실측: `... dev eth3` — **h2의 MAC이 eth3(루프 링크)에서 학습**돼 있다. 돌고 있는 복제 프레임이
h2의 소스 MAC을 달고 eth3으로 들어오기 때문. 유니캐스트가 엉뚱한 포트로 보내져 통신 자체가 무너진다.

**⑥ 원인 정리**: 브로드캐스트 1발 → 두 링크로 복제 → 이더넷엔 TTL이 없어 끊을 수 없음 → 무한 증폭 + FDB 오염.

---

## 6. 한 줄 수정 — STP

```sh
docker exec clab-02-bcast-loop-sw1 ip link set br0 type bridge stp_state 1
docker exec clab-02-bcast-loop-sw2 ip link set br0 type bridge stp_state 1
```
✅ **성공 판정 1 — 스톰 즉사** (실측): STP 켠 직후 h2 rx 증가율 **9,974pkt/2s → 1pkt/2s**.
(STP가 포트를 일단 non-forwarding으로 되돌리므로 돌던 프레임이 그 자리에서 끊긴다.)

✅ **성공 판정 2 — 수렴(~30초) 후 blocking 포트 + 통신 정상** (실측):
```sh
docker exec clab-02-bcast-loop-sw1 bash -c "bridge -d link show | grep -o 'eth[123].*state [a-z]*'"
```
```
eth1 ... state forwarding
eth2 ... state forwarding
eth3 ... state blocking      ← 루프의 한 포트만 논리적으로 잠김
```
```sh
docker exec clab-02-bcast-loop-h1 ping -c3 10.2.0.2
# 3 packets transmitted, 3 received, 0% packet loss   ← 루프 링크가 살아있는 채로 정상!
```

---

## 7. 정리 / 교훈
- 스위치의 본질 = **소스 MAC 학습 + 모르면 플러딩**. 이 단순함이 성능의 비결이자 약점.
- **이더넷 프레임에는 TTL이 없다** → L2 루프는 스스로 끝나지 않는다. (L3 루프는 TTL로 끊긴다 → 06장)
- 스톰의 증상: 트래픽/CPU 폭증 + **FDB 오염으로 유니캐스트까지 사망** ("가끔 되는 게 아니라 다 죽는다").
- 이중화 링크를 원하면 **STP(또는 LACP 등)** 가 반드시 필요 — "선 두 개 꽂으면 두 배"가 아니다.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| FDB(CAM) 보기 | `bridge fdb show br0` |
| 포트 STP 상태 | `bridge -d link show` |
| 인터페이스 카운터 | `cat /sys/class/net/eth1/statistics/rx_packets` |
| STP 켜기/끄기 | `ip link set br0 type bridge stp_state 1` / `0` |
| 비상 루프 절단 | `ip link set eth3 down` |

## 9. 랩 정리
```sh
./clab.sh destroy 02-bcast-loop/02-bcast-loop.clab.yml
```

---
### 다음 장 예고
"같은 네트워크" 안은 여기까지. 이제 **다른 서브넷으로 넘어가는 라우터와 라우팅 테이블**로 → **04장**.
(03장 VLAN은 확장편: 하나의 스위치를 논리적으로 쪼개는 법)
