# 03장 모범 답안 — 전체 명령 실행 기록

> 증상 → 태그 캡처 → 설정 대조 → 수정 → 격리 확인까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 03-vlan-trunk/03-vlan-trunk.clab.yml   # → sw1, sw2, h1, h2, h3 running (고장 장전됨)
```

## 단계 A — 증상 확인
**의도**: 같은 VLAN 10의 h1↔h2가 스위치를 넘는 경로에서 되는지 보기.
```sh
docker exec clab-03-vlan-trunk-h1 ping -c2 10.3.10.2
```
```
2 packets transmitted, 0 received, 100% packet loss
```
**해석**: 같은 서브넷·같은 VLAN인데 죽는다. 01장 지식이라면 "ARP가 안 되나?"까지는 좁혀진다 —
어디서 막히는지는 와이어를 봐야 한다.

## 단계 B — 트렁크 와이어에서 태그 확인
**의도**: h1의 ARP가 트렁크를 **건너오기는 하는지**, 온다면 어떤 모습(태그)인지.
```sh
docker exec clab-03-vlan-trunk-sw2 tcpdump -e -nli eth2 vlan     # sw2의 트렁크 포트에서
```
```
aa:c1:ab:8e:f7:47 > ff:ff:ff:ff:ff:ff, ethertype 802.1Q, vlan 10, ... ARP Request who-has 10.3.10.2
```
**해석**: 두 가지를 한 번에 확인 — ① 프레임에 **802.1Q 태그(`vlan 10`)** 가 실제로 붙어 있다
(트렁크의 실체), ② 그 프레임이 **sw2 문 앞까지 도착해 있다**. 도착했는데 h2가 응답하지 않는다
= sw2가 **받고서 버리고 있다**(ingress 필터). 07장 VNI 불일치와 같은 부류의 "도착 후 조용한 소실".

## 단계 C — 설정 대조: 범인 찾기
**의도**: 양단 트렁크의 VLAN 허용 목록을 나란히 놓고 비대칭 찾기.
```sh
docker exec clab-03-vlan-trunk-sw1 bridge vlan show dev eth2
docker exec clab-03-vlan-trunk-sw2 bridge vlan show dev eth2
```
```
sw1 eth2:  10, 20
sw2 eth2:  20          ← vid 10이 없다!
```
**해석**: sw1은 10·20을 다 허용하는데 sw2는 20만 허용 — **한쪽에만 있는 VLAN은 그 방향으로
편도 폐기**된다. "VLAN 추가는 트렁크 양단 세트로"가 격언인 이유.

## 단계 D — 한 줄 수정 + 판정
```sh
docker exec clab-03-vlan-trunk-sw2 bridge vlan add dev eth2 vid 10
```
```
ping h1→h2: 3 received, 0% packet loss
```
**해석**: 허용 목록에 10을 추가하는 순간 통신 회복. (첫 ping은 ARP 재학습으로 유실될 수 있음 —
그건 고장이 아니다.)

## 단계 E — 격리는 유지되는가 (수정의 부작용 점검)
**의도**: 수정이 과했는지 확인 — V20의 h3가 **여전히 격리**되어 있어야 정상.
```sh
docker exec clab-03-vlan-trunk-h1 ping -c2 10.3.10.3      # h3는 같은 서브넷이지만 VLAN 20
docker exec clab-03-vlan-trunk-h1 ip neigh | grep 10.3.10.3
```
```
2 packets transmitted, 0 received, 100% packet loss
10.3.10.3 dev eth1 FAILED          ← ARP 자체가 실패
```
**해석**: h3는 **같은 서브넷(10.3.10.0/24), 같은 스위치**에 있지만 VLAN 20 — 브로드캐스트(ARP)가
VLAN 경계를 못 넘으니 L2가 성립하지 않는다(`FAILED`). **이건 고장이 아니라 VLAN의 존재 이유**다.
수정 후 확인 항목에 "격리가 깨지지 않았는가"를 넣는 습관 — 변경 작업의 절반은 부작용 점검이다.

## 정리
```sh
./clab.sh destroy 03-vlan-trunk/03-vlan-trunk.clab.yml
```
**이 장의 판정 요약**: 태그 프레임이 도착하고도 무응답 = 수신측 허용 목록 의심 →
`bridge vlan show` 양단 대조 → 비대칭 발견 → 한 줄 수정 → 통신 회복 **그리고 격리 유지** 확인.
