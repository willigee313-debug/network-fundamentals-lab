# 17장 모범 답안 — 전체 명령 실행 기록

> 17a(OSPF area 불일치) · 17b(BGP 미광고) 두 토포의 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)
> ※ FRR은 amd64 에뮬레이션 — 수렴이 느릴 수 있어 **수십 초 대기 후 재확인**이 기본 동작.

---

# 17a. OSPF — 인접이 안 맺어진다

## 0. 배포
```sh
./clab.sh deploy 17-dynamic-routing/ospf.clab.yml   # → h1, r1(FRR), r2(FRR), h2 running (area 불일치 장전)
```

## 단계 A — 증상: 이웃 0
**의도**: 동적 라우팅 추적 사다리의 1칸 — **이웃 관계**부터.
```sh
docker exec clab-17-ospf-r1 vtysh -c "show ip ospf neighbor"
docker exec clab-17-ospf-h1 ping -c1 10.17.2.10
```
```
(이웃 테이블 비어 있음 — 0개)
ping → Net Unreachable
```
**해석**: 이웃이 없으면 라우트 교환도 없다 — r1은 h2 대역을 배우지 못해 즉시 "길 없음".
증상의 뿌리가 **관계 형성 단계**임이 확정. hello가 오가는데도 안 맺어진다면 조건 불일치를 의심.

## 단계 B — 원인: 양쪽 area 대조
**의도**: 인접 성립 조건(area/타이머/인증) 중 area를 양단에서 나란히 확인 — 03장의 "양단 대조"
습관이 프로토콜 설정에서 반복된다.
```sh
docker exec clab-17-ospf-r1 vtysh -c "show ip ospf interface eth2" | grep Area
docker exec clab-17-ospf-r2 vtysh -c "show ip ospf interface eth1" | grep Area
```
```
r1 eth2: Area 0.0.0.0
r2 eth1: Area 0.0.0.1      ← 같은 링크의 양 끝이 다른 구역!
```
**해석**: OSPF hello에는 area가 실려 있고, 다르면 서로를 **조용히 무시**한다(에러 없음).
"설정은 다 넣었는데 이웃이 안 떠요"의 단골 원인.

## 단계 C — 수정 + 판정
```sh
docker exec clab-17-ospf-r2 vtysh -c "conf t" -c "router ospf" \
  -c "no network 10.17.0.0/30 area 1" -c "no network 10.17.2.0/24 area 1" \
  -c "network 10.17.0.0/30 area 0"    -c "network 10.17.2.0/24 area 0"
# (수십 초 대기)
```
```
show ip ospf neighbor → 10.99.99.3  1  Full/Backup ...       ← 인접 완성 (Full)
show ip route ospf    → O>* 10.17.2.0/24 via 10.17.0.2       ← 라우트가 "걸어 들어왔다"
ping h1→h2            → 0% packet loss
```
**해석**: `O>*`의 의미 — O(OSPF가 배움), >(선택됨), *(커널 설치됨). 04장까지 손으로 넣던
라우트가 프로토콜을 타고 스스로 도착한 순간. **인접(Full) → 학습(O>*) → 통신**의 3단 확인이
OSPF 검증의 정석 순서다.

> **심화**: 타이머가 긴 환경에선 area를 고쳐도 `2-Way/DROther`에서 고착될 수 있다
> (양쪽 다 자기 구역의 DR이었고, DR은 선점이 없으므로). 그땐
> `vtysh -c "clear ip ospf interface <if>"`로 재선거를 강제 — 이 랩은 타이머를 짧게 잡아
> 대개 자가 회복된다.

```sh
./clab.sh destroy 17-dynamic-routing/ospf.clab.yml
```

---

# 17b. BGP — 세션은 사는데 라우트가 없다

## 0. 배포
```sh
./clab.sh deploy 17-dynamic-routing/bgp.clab.yml    # → h1, r1(AS65001), r2(AS65002), h2 running (network 문 누락 장전)
```

## 단계 A — 증상: Established인데 PfxRcd 0
**의도**: 사다리 1칸(세션)과 2칸(교환량)을 한 명령으로 — summary의 **PfxRcd 열**이 핵심.
```sh
docker exec clab-17-bgp-r2 vtysh -c "show ip bgp summary"
```
```
10.17.0.1  4  65001  6  6  0 0 0  00:00:29  0  1  N/A
                                  └Up 29초  └PfxRcd=0! └PfxSnt=1
ping h1→h2 → 100% packet loss
```
**해석**: 세션은 29초째 정상(Up)인데 **받은 프리픽스가 0** — "Established = 전화 연결"일 뿐
"할 말을 했다"가 아니다. r2는 자기 대역을 광고했고(PfxSnt 1 → r1은 h2로 가는 길을 앎),
r1은 아무것도 광고하지 않았다 → **리턴 라우트 부재 = 04장의 편도 장애가 동적 라우팅 옷을
입고 재림.** 모니터링이 세션 상태만 보면 초록불인 채로 장애가 나는 형태.

## 단계 B — 사다리 2칸: 광고 단계 조사
**의도**: "내(r1)가 뭘 내보내고 있나"를 직접 확인 — 문제가 광고/수신/필터 중 어디인지 가른다.
```sh
docker exec clab-17-bgp-r1 vtysh -c "show ip bgp neighbors 10.17.0.2 advertised-routes" | grep 10.17.1.0
```
```
(출력 없음 — 자기 대역 10.17.1.0/24를 광고 목록에 올린 적이 없다)
```
**해석**: 수신측 필터도, 경로 선택도 아니고 **발신측이 광고 자체를 안 하는** 경우로 확정.
BGP는 명시한 것만 광고한다 — `network` 문(또는 redistribute) 누락이 범인.

## 단계 C — 수정(한 줄) + 판정
```sh
docker exec clab-17-bgp-r1 vtysh -c "conf t" -c "router bgp 65001" \
  -c "address-family ipv4 unicast" -c "network 10.17.1.0/24"
```
```
advertised-routes → *> 10.17.1.0/24  0.0.0.0 ... 32768 i     ← 광고 시작
r2 summary        → PfxRcd = 1                                ← 수신 확인
r2 라우트          → B>* 10.17.1.0/24 [20/0] via 10.17.0.1    ← 설치 확인
ping h1→h2        → 0% packet loss                            ← 통신 확인
```
**해석**: 수정 검증도 사다리를 그대로 내려온다 — **광고 → 수신 → 설치 → 통신** 4단이 전부
초록으로 바뀌는 것을 확인. 어느 칸에서 다시 끊기면 그 칸이 다음 수색 지점이다.
(실무에선 `no bgp ebgp-requires-policy`가 없는 기본 상태의 **정책 필터**가 "광고했는데 안 감"의
또 다른 단골 — 이 랩에선 단순화를 위해 해제되어 있다.)

```sh
./clab.sh destroy 17-dynamic-routing/bgp.clab.yml
```

---

## 이 장의 판정 요약
**추적 사다리**: ① 이웃/세션(`show ip ospf neighbor` / `show ip bgp summary`의 상태) →
② 광고(`advertised-routes`) → ③ 수신(PfxRcd / `received-routes`) → ④ 설치(`show ip route ospf|bgp`)
→ ⑤ 통신(ping). **어느 칸에서 끊기는지가 곧 원인의 주소다.**
