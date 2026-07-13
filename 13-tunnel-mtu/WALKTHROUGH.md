# 13장 모범 답안 — 전체 명령 실행 기록

> 자동 MTU 관찰 → 크기별 증상 → 조각 물증 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 13-tunnel-mtu/13-tunnel-mtu.clab.yml   # → vtep1, r1, vtep2 running (경로 협곡 1400 + 조각 거부 장전)
```

## 단계 A — 커널의 자기방어 관찰
**의도**: 양쪽 vxlan의 MTU가 어떻게 정해져 있는지 + 초과 설정이 가능한지.
```sh
docker exec clab-13-tunnel-mtu-vtep1 ip link show vxlan100 | grep -o "mtu [0-9]*"
docker exec clab-13-tunnel-mtu-vtep2 ip link show vxlan100 | grep -o "mtu [0-9]*"
docker exec clab-13-tunnel-mtu-vtep1 ip link set vxlan100 mtu 1500
```
```
vtep1: mtu 1450                              ← 1500(자기 링크) − 50 자동
vtep2: mtu 1350                              ← 1400(자기 링크가 협곡!) − 50 자동
mtu 1500 → RTNETLINK answers: Invalid argument   ← 커널이 초과 설정을 거부까지 한다
```
**해석**: 커널은 성실하다 — **자기가 아는 범위(자기 링크)에서는.** 그런데 이 성실함이 낳은
**비대칭(1450 vs 1350)이 이미 최대의 힌트**다: vtep1의 1450은 "경로"가 아니라 "자기 링크"
기준의 숫자일 뿐, 경로 중간의 협곡(1400)을 반영하지 못한다.

## 단계 B — 크기가 운명을 가른다 (12장의 오버레이판)
```sh
docker exec clab-13-tunnel-mtu-vtep1 ping -M dont -c2 -s 1300 192.168.100.2
docker exec clab-13-tunnel-mtu-vtep1 ping -M dont -c2 -s 1400 192.168.100.2
```
```
-s 1300 (outer 1378 ≤ 1400) → 0% packet loss
-s 1400 (outer 1478 > 1400) → 100% packet loss
```
**해석**: 오버레이 위에서 12장의 지문("작은 건 되고 큰 것만 죽음")이 재현된다.
경계값이 정보다: outer로 환산해 1400 근처 = 협곡의 크기.

## 단계 C — 협곡 와이어의 물증: 정체불명의 파편
**의도**: r1이 협곡(eth2)으로 내보내는 프레임을 직접 본다 — 큰 outer가 어떤 모습으로 나가는지.
```sh
docker exec clab-13-tunnel-mtu-r1 tcpdump -nli eth2 src host 10.13.1.1    # 켜두고 -s 1400 ping
```
```
IP 10.13.1.1.46483 > 10.13.2.1.4789: VXLAN, vni 100
IP [total length 1428 > length 1346] (invalid) ... ICMP echo request     ← 선두 조각 (잘려 있다!)
IP 10.13.1.1 > 10.13.2.1: ip-proto-17                                     ← 비선두 조각
```
**해석**: r1이 outer 1478을 협곡에 맞춰 **두 조각**으로 쪼갰다. 특히 두 번째 줄 —
포트도, VXLAN 표식도 없는 **`ip-proto-17` 파편**을 보라. L4 헤더가 첫 조각에만 있기 때문인데,
바로 이 "검사 불가능한 모습" 때문에 실무의 방화벽/일부 경로가 비선두 조각을 버린다.
이 랩의 vtep2가 정확히 그렇게 하고 있고(장전된 고장), 조각 하나가 사라지면 재조립은 영원히
미완성 — **에러는 어디에도 없다.**

## 단계 D — 한 줄 수정 + 판정
**의도**: 오버레이 MTU를 "자기 링크"가 아닌 **경로 최솟값** 기준으로 내려 조각화 자체를 없앤다.
```sh
./13-tunnel-mtu/fix.sh      # vtep1: ip link set vxlan100 mtu 1350 (= 협곡 1400 − 50)
```
```
ping -M dont -s 1400 → 0% packet loss     (3회 연속 재현)
```
**해석**: 이제 큰 inner는 **오버레이 층에서** 나뉘어 outer가 조각 없이 협곡을 통과한다.
TCP라면 MSS가 1310으로 협상되어 아예 조각날 일이 없다(MSS clamp도 같은 효과).

> **관찰의 함정**(README §8): 이 가상(veth) 랩에서 iperf3 TCP는 GSO가 MTU 검사를 우회해
> 고장 상태에서도 살아남을 수 있다 — 물리 NIC에선 그렇지 않다. 그래서 이 장의 판정은
> 단일 패킷(ping)을 쓴다. "랩에서 재현 안 됨 ≠ 무죄"의 실례.

## 정리
```sh
./clab.sh destroy 13-tunnel-mtu/13-tunnel-mtu.clab.yml
```
**이 장의 판정 요약**: 양쪽 vxlan MTU 대조(비대칭=힌트) → 크기 이등분 ping으로 경계 확인 →
협곡 와이어에서 `ip-proto-17` 파편 확인 → 오버레이 MTU = **경로 최솟값 − 50**으로 수정.
