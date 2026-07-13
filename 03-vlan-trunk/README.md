# 03장. VLAN / 트렁크 — 하나의 스위치를 여러 세계로 쪼개기

> 01·02장의 "브로드캐스트 도메인"은 스위치 단위였다. VLAN은 그걸 **포트 단위로 재편**한다:
> 같은 스위치 안에서도 VLAN이 다르면 남남, 스위치가 달라도 **트렁크의 태그**만 맞으면 한 식구.
> 이 장의 고장은 실무 단골 — **트렁크 태그 허용 목록에서 VLAN 하나 빠뜨리기.**

## 0. 학습 목표
- **VLAN** = 논리적 브로드캐스트 도메인, **액세스 포트**(untagged) vs **트렁크**(tagged) 구분
- **802.1Q 태그**를 tcpdump로 직접 보기
- 대표 고장: 트렁크 VID 허용 누락 — "같은 VLAN인데 스위치를 넘으면 단절"
- VLAN **격리 자체는 기능**임을 확인 (같은 서브넷이어도 못 넘는다)

---

## 1. 개념

### 1-1. 태그가 세계를 정한다
- 프레임이 트렁크를 지날 때 **802.1Q 태그(12bit VLAN ID)** 가 붙는다: "이 프레임은 VLAN 10 소속".
- 액세스 포트: 호스트는 태그를 모른다 — 스위치가 **포트 설정(PVID)** 으로 소속을 정해준다.
- 트렁크 포트: 여러 VLAN을 **태그로 구분해 다중화**. 단, **허용 목록에 있는 VID만** 통과.

### 1-2. 01장 명제의 확장
- 01장: "같은 네트워크는 케이블이 아니라 IP+마스크가 정한다."
- 03장: **"같은 L2조차 케이블이 아니라 태그(설정)가 정한다."** (07장에서 VNI로 한 번 더 확장)

## 2. 토폴로지
```
  h1(V10) ── sw1 ══trunk══ sw2 ── h2(V10)
 10.3.10.1                   └─── h3(V20) 10.3.10.3
                                  ↑ 셋 다 "같은 서브넷" 10.3.10.0/24!
```
**장전된 고장**: sw2 트렁크 포트의 허용 목록에 **vid 10 누락** (vid 20만 허용).

## 3. 실습 준비
```sh
./clab.sh deploy 03-vlan-trunk/03-vlan-trunk.clab.yml
```
> 노드: `clab-03-vlan-trunk-<sw1|sw2|h1|h2|h3>`

---

## 4. 실습 A — 증상: 같은 VLAN인데 스위치를 넘으면 끊긴다

```sh
docker exec clab-03-vlan-trunk-h1 ping -c2 10.3.10.2     # h1(V10) → h2(V10), sw 넘어감
# → 100% packet loss     (실측)
```

## 5. 실습 B — 와이어의 진실: 태그는 도착했다

```sh
docker exec clab-03-vlan-trunk-sw2 tcpdump -e -nli eth2 vlan    # sw2 트렁크에서
# (다른 터미널에서 h1 → h2 ping)
```
✅ 실측:
```
aa:c1:ab:75:40:6d > ff:ff:ff:ff:ff:ff, ethertype 802.1Q, vlan 10, ... ARP Request who-has 10.3.10.2
aa:c1:ab:75:40:6d > ff:ff:ff:ff:ff:ff, ethertype 802.1Q, vlan 10, ... ARP Request who-has 10.3.10.2
```
**해설**: `vlan 10` 태그를 단 ARP가 sw2의 문 앞까지 와서 **반복되고 있다**(응답 없음).
07장 VNI 불일치와 같은 부류의 지문 — **프레임은 도달하는데, 수신측이 "그 소속은 우리 문 못
지나감"이라며 조용히 버린다.** (sw2의 ingress 필터가 허용 목록에 없는 vid 10을 폐기)

## 6. 실습 C — 범인 찾기: 설정 대조

```sh
docker exec clab-03-vlan-trunk-sw1 bridge vlan show dev eth2
docker exec clab-03-vlan-trunk-sw2 bridge vlan show dev eth2
```
✅ 실측:
```
sw1 eth2:  10        sw2 eth2:  20
           20                       ← vid 10이 없다!
```
**해설**: 트렁크는 **양쪽 끝의 허용 목록이 대칭**이어야 한다. 한쪽에만 있는 VLAN은
그 방향의 프레임이 편도로 버려진다. "VLAN 추가 작업 시 트렁크 양단을 함께" — 변경 관리의 고전.

## 7. 한 줄 수정 + 판정

```sh
docker exec clab-03-vlan-trunk-sw2 bridge vlan add dev eth2 vid 10
```
✅ 실측: h1 → h2 ping `0% packet loss`

**그리고 격리는 여전해야 정상이다:**
```sh
docker exec clab-03-vlan-trunk-h1 ping -c2 10.3.10.3    # h1(V10) → h3(V20)
```
✅ 실측:
```
100% packet loss  ·  ip neigh: 10.3.10.3 ... FAILED    ← ARP조차 못 넘는다
```
**해설**: h3는 **같은 서브넷(10.3.10.0/24), 같은 스위치**에 있지만 VLAN 20이다.
브로드캐스트(ARP)가 VLAN 경계를 못 넘으므로 L2가 성립하지 않는다(01장의 원리).
이건 고장이 아니라 **VLAN의 존재 이유** — 격리가 곧 기능이다. (VLAN 간 통신이 필요하면
라우터가 필요하다 → 04장의 원리로 되돌아간다)

---

## 8. 정리 / 교훈
- **"같은 L2"의 정의는 계층마다 갱신된다**: 케이블(01) → 태그(03) → 캡슐(07).
- 트렁크 장애의 지문: **태그 프레임이 도착하고도 무응답** + 양단 `bridge vlan show` 비대칭.
- VLAN 작업 체크리스트: 액세스 PVID / 트렁크 허용 목록 **양단** / (심화) native VLAN 일치.
- 같은 서브넷 ≠ 통신 가능. **L2 소속(VLAN)이 먼저다.**

## 9. 치트시트
| 목적 | 명령 |
|---|---|
| VLAN 테이블 | `bridge vlan show` |
| 태그 프레임 캡처 | `tcpdump -e -nli <if> vlan` |
| 액세스 포트 지정 | `bridge vlan add dev <if> vid <N> pvid untagged` |
| 트렁크 허용 추가 | `bridge vlan add dev <if> vid <N>` |

## 10. 랩 정리
```sh
./clab.sh destroy 03-vlan-trunk/03-vlan-trunk.clab.yml
```

---
### 다음 장 예고
태그(12bit)의 한계를 넘는 대형판 — UDP 캡슐에 24bit VNI를 실어 L3 위에 L2를 그리는
**VXLAN → 07장**. (코어 트랙은 04장으로)
