# 17장. 동적 라우팅 — OSPF/BGP: 라우트는 어떻게 "걸어 들어오고", 왜 안 오는가

> 지금까지 라우트는 전부 손으로 넣었다(04·05장). 실제 네트워크에선 라우트가 **프로토콜을
> 타고 스스로 걸어온다** — 그리고 그만큼 "왜 안 걸어오지?"라는 새 부류의 장애가 생긴다.
> 이 장은 FRR로 두 가지 대표 고장을 다룬다:
> **17a) OSPF — 인접(adjacency)이 안 맺어짐** / **17b) BGP — 세션은 사는데 라우트가 없음.**

## 0. 학습 목표
- 동적 라우팅의 고장 추적 사다리: **이웃 관계 → 광고 → 수신 → 설치** 단계 분리
- OSPF: hello/area — 인접의 성립 조건, `show ip ospf neighbor/interface`
- BGP: **"Established ≠ 라우트 교환"** — PfxRcd 읽기, advertised-routes로 광고 단계 확인
- vtysh 진단 기본기

> ⚠️ **환경 노트**: FRR 공식 이미지는 amd64 전용 → Apple Silicon에선 qemu 에뮬레이션으로
> 돌며 **수렴이 느릴 수 있다**(수십 초 대기 후 재확인 습관). 또한 이 랩 환경에선 OSPF
> 멀티캐스트가 전달되지 않아 **NBMA(유니캐스트 hello) + neighbor 지정**으로 구성했다 —
> 프로토콜 원리는 동일하다.

---

## 17a. OSPF — 인접이 안 맺어진다

### 개념 요약
- OSPF 라우터는 **hello 패킷**으로 서로를 발견하고, 조건이 맞아야 **인접**을 맺어 LSDB를 동기화한다.
- hello의 성립 조건 중 하나라도 다르면 인접 자체가 안 됨: **area**, hello/dead 타이머, 인증, 서브넷...
- **area 불일치**가 이 랩의 고장: hello는 오가지만 서로 "다른 구역 사람"이라며 무시한다.

### 토폴로지 & 배포
```
h1 ── r1(FRR, area 0) ──── r2(FRR, ★area 1) ── h2
     10.17.1.0/24   10.17.0.0/30   10.17.2.0/24
```
```sh
./clab.sh deploy 17-dynamic-routing/ospf.clab.yml    # 노드: clab-17-ospf-<h1|r1|r2|h2>
```

### 증상 (✅ 실측)
```sh
docker exec clab-17-ospf-r1 vtysh -c "show ip ospf neighbor"
# → (빈 테이블 — 이웃이 하나도 없다)
docker exec clab-17-ospf-h1 ping -c2 10.17.2.10       # → 실패 (라우트 교환 0)
```

### 원인 — 양쪽 설정 대조 (✅ 실측)
```sh
docker exec clab-17-ospf-r1 vtysh -c "show ip ospf interface eth2" | grep Area
docker exec clab-17-ospf-r2 vtysh -c "show ip ospf interface eth1" | grep Area
```
```
r1 eth2: Area 0.0.0.0
r2 eth1: Area 0.0.0.1      ← 불일치! 같은 링크의 양 끝이 다른 구역
```

### 수정 (vtysh)
```sh
docker exec clab-17-ospf-r2 vtysh -c "conf t" -c "router ospf" \
  -c "no network 10.17.0.0/30 area 1" -c "no network 10.17.2.0/24 area 1" \
  -c "network 10.17.0.0/30 area 0"    -c "network 10.17.2.0/24 area 0"
```
✅ **판정** (실측, 수십 초 대기 후):
```
show ip ospf neighbor → 10.99.99.x  Full/DR ...        ← 인접 완성
show ip route ospf    → O>* 10.17.2.0/24 via 10.17.0.2 ← 라우트가 "걸어 들어왔다"
h1 ping h2            → 0% packet loss
```

### 심화 관찰 — 고쳤는데 2-Way에서 멈춘다면?
타이머가 긴 환경에선 area를 고쳐도 인접이 `2-Way/DROther`에서 고착될 수 있다(실측 재현됨).
**양쪽 다 "자기 구역의 DR"이던 상태로 만났고, OSPF DR은 선점(preemption)이 없기 때문.**
```sh
docker exec clab-17-ospf-r1 vtysh -c "clear ip ospf interface eth2"   # 상태머신 리셋 → 재선거
docker exec clab-17-ospf-r2 vtysh -c "clear ip ospf interface eth1"
```
실무 번역: 파티션 힐링/설정 정정 후에도 인접이 이상하면 **재선거를 강제**해 볼 것.

```sh
./clab.sh destroy 17-dynamic-routing/ospf.clab.yml
```

---

## 17b. BGP — 세션은 Established인데 라우트가 없다

### 개념 요약
- BGP는 TCP(179) 세션 위에서 프리픽스를 광고한다. **세션 수립과 라우트 광고는 별개 단계** —
  "Established"는 전화가 연결됐다는 뜻이지, 할 말을 했다는 뜻이 아니다.
- 광고할 프리픽스는 명시해야 한다(`network` 문 등). 빠뜨리면? 세션 지표는 전부 정상인데
  트래픽만 죽는, 모니터링을 속이는 장애가 된다.

### 토폴로지 & 배포
```
h1 ── r1(AS 65001, ★network 문 누락) ──eBGP── r2(AS 65002) ── h2
```
```sh
./clab.sh deploy 17-dynamic-routing/bgp.clab.yml     # 노드: clab-17-bgp-<h1|r1|r2|h2>
```

### 증상 (✅ 실측)
```sh
docker exec clab-17-bgp-r2 vtysh -c "show ip bgp summary"
```
```
10.17.0.1  4  65001 ... Up 00:00:29  PfxRcd=0  PfxSnt=1
                        └ 세션은 살아있고(Up)   └ 그런데 받은 프리픽스가 0!
```
```
h1 ping h2 → 100% packet loss
```
**해설**: r2는 자기 대역을 광고했고(PfxSnt 1 → r1은 h2 가는 길을 안다), r1은 아무것도
광고하지 않았다(PfxRcd 0) → **리턴 라우트 없음 = 04장의 편도 장애가 동적 라우팅 옷을 입고 재림.**

### 진단 — 사다리를 한 칸씩
```sh
# ① 광고 단계: r1이 뭘 내보내고 있나
docker exec clab-17-bgp-r1 vtysh -c "show ip bgp neighbors 10.17.0.2 advertised-routes" | grep 10.17.1.0
# → (없음 — 자기 대역을 광고 목록에 올린 적이 없다)
```

### 수정 (vtysh 한 줄)
```sh
docker exec clab-17-bgp-r1 vtysh -c "conf t" -c "router bgp 65001" \
  -c "address-family ipv4 unicast" -c "network 10.17.1.0/24"
```
✅ **판정** (실측):
```
advertised-routes | grep 10.17.1.0 → *> 10.17.1.0/24  0.0.0.0 ... 32768 i   ← 광고 시작
r2 summary                         → PfxRcd = 1
r2 show ip route bgp               → B>* 10.17.1.0/24 [20/0] via 10.17.0.1
h1 ping h2                         → 0% packet loss
```

> 구성 노트: FRR eBGP는 기본이 RFC 8212(정책 없으면 광고/수신 거부)라 이 랩은
> `no bgp ebgp-requires-policy`로 단순화했다 — 실무에선 **정책 필터가 또 하나의
> "라우트가 안 오는 이유"** 가 된다는 것도 기억해 두라.

```sh
./clab.sh destroy 17-dynamic-routing/bgp.clab.yml
```

---

## 정리 / 교훈
- 동적 라우팅 장애의 추적 사다리: **① 이웃/세션 상태 → ② 내가 광고하나(advertised-routes)
  → ③ 상대가 받나(PfxRcd/received-routes) → ④ 라우팅 테이블에 설치됐나(show ip route)** —
  어느 칸에서 끊기는지 찾으면 원인 부위가 나온다.
- OSPF: 인접은 조건부다 — **area/타이머/인증 불일치**면 hello 단계에서 조용히 무시된다.
- BGP: **Established는 성공 지표가 아니다.** PfxRcd 0을 놓치면 "모니터링은 초록불인데 장애".
- 04장의 원리는 죽지 않는다: 동적 라우팅에서도 결국 **왕복 각 방향의 라우트**가 성립해야 한다.

## 치트시트
| 목적 | 명령 (vtysh) |
|---|---|
| OSPF 이웃 | `show ip ospf neighbor` |
| OSPF 인터페이스/area | `show ip ospf interface <if>` |
| BGP 세션+PfxRcd | `show ip bgp summary` |
| 광고 중인 것 | `show ip bgp neighbors <peer> advertised-routes` |
| 프로토콜별 배운 라우트 | `show ip route ospf` / `show ip route bgp` |
| 인터페이스 상태머신 리셋 | `clear ip ospf interface <if>` |

---
### 시리즈의 끝
여기까지 왔다면 코어 10편 + 확장 7편을 완주했다. 이제 `checkpoints/`의 블라인드 미션을
README 없이 풀어보라 — **증상에서 계층을 좁히는 감각**이 몸에 붙었는지 확인할 시간이다.
