# 07장 모범 답안 — 전체 명령 실행 기록

> underlay/overlay 분리 진단 → outer 도착 확인 → VNI 대조 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 07-vxlan-overlay/07-vxlan-overlay.clab.yml   # → vtep1, r1, vtep2 running (VNI 불일치 장전)
```

## 단계 A — 층을 나눠 두드린다: underlay 먼저
**의도**: 터널 장애 진단의 제1원칙 — **아래층(underlay)부터**. 터널 끝점끼리(10.7.x)의 도달성과
터널 위(192.168.100.x)를 분리해서 확인.
```sh
docker exec clab-07-vxlan-overlay-vtep1 ping -c1 10.7.2.1        # underlay
docker exec clab-07-vxlan-overlay-vtep1 ping -c2 192.168.100.2   # overlay
```
```
underlay → time=0.066ms (성공)
overlay  → 100% packet loss
```
**해석**: 아래층은 멀쩡한데 위층만 죽는다 = **문제는 터널 자체의 설정/동작**으로 좁혀졌다.
(underlay가 죽었다면 04·05장의 라우팅 진단으로 내려갔을 것.)

## 단계 B — outer는 도착하는가
**의도**: 캡슐(UDP 4789)이 상대 VTEP 문 앞까지 **가긴 하는지** — 경로 문제와 디캡 문제를 가른다.
```sh
docker exec clab-07-vxlan-overlay-vtep2 tcpdump -nli eth1 'udp port 4789 and src host 10.7.1.1'
```
```
IP 10.7.1.1.49159 > 10.7.2.1.4789: VXLAN, flags [I], vni 100
ARP, Request who-has 192.168.100.2 tell 192.168.100.1
```
**해석**: 놀라운 두 가지 — ① outer가 **도착해 있다**(경로 무죄), ② tcpdump가 캡슐을 열어
**안의 ARP까지** 보여준다("vni 100의 캡슐 속에 ARP"). 도착했는데 응답이 없다 =
**디캡 쪽이 받고서 버린다.** 03장(태그 불일치)과 같은 부류의 지문이 오버레이에서 반복.

## 단계 C — VNI 대조: 범인 확정
**의도**: 양쪽 터널 설정을 나란히 놓기 — 03장에서 `bridge vlan show` 양단 대조를 했듯,
여기선 `ip -d link show`로.
```sh
docker exec clab-07-vxlan-overlay-vtep1 ip -d link show vxlan100 | grep "vxlan id"
docker exec clab-07-vxlan-overlay-vtep2 ip -d link show vxlan100 | grep "vxlan id"
```
```
vtep1: vxlan id 100
vtep2: vxlan id 200      ← 불일치!
```
**해석**: vtep2 커널은 "vni 200만 내 것"이라 여기므로, 단계 B에서 도착한 vni 100 캡슐을
**에러도 ICMP도 없이** 버린다. VNI = 24bit짜리 "대형 VLAN 태그"이고, 태그가 다르면 남남.

## 단계 D — 수정 + 판정
**의도**: VNI는 변경 불가라 재생성(fix.sh) 후, ping과 **중간 라우터의 캡처**로 이중 검증.
```sh
./07-vxlan-overlay/fix.sh      # vtep2의 vxlan을 id 100으로 재생성
```
```
overlay ping → 0% packet loss

r1(중간 라우터)에서 본 왕복:
IP 10.7.1.1.49159 > 10.7.2.1.4789: VXLAN vni 100 / ARP Request who-has 192.168.100.2
IP 10.7.2.1.49159 > 10.7.1.1.4789: VXLAN vni 100 / ARP Reply 192.168.100.2 is-at de:a7:...
```
**해석**: 이 캡처가 이 장의 존재 이유다 — **ARP(브로드캐스트, 원래 같은 세그먼트 전용)가
라우터 r1을 건너다닌다.** 01장의 "같은 네트워크는 설정이 정한다"가 최종 형태에 도달:
캡슐화는 "같은 L2 세그먼트"라는 개념 자체를 L3 위에 그려낼 수 있다.

## 단계 E — 보너스: 오버레이의 세금 확인
```sh
docker exec clab-07-vxlan-overlay-vtep1 ip link show vxlan100 | grep -o "mtu [0-9]*"
```
```
mtu 1450          ← underlay는 1500인데?
```
**해석**: 커널이 스스로 50을 뺐다 — outer Eth(14)+IP(20)+UDP(8)+VXLAN(8) = 캡슐 비용 50바이트.
이 자동 계산의 한계(자기 링크만 안다)가 13장의 주제다.

## 정리
```sh
./clab.sh destroy 07-vxlan-overlay/07-vxlan-overlay.clab.yml
```
**이 장의 판정 요약**: ① underlay/overlay 분리 진단 → ② outer 도착 여부(`udp port 4789`) →
③ 양쪽 VNI/포트/remote 대조 → 재생성 → 중간 라우터에서 캡슐 속 왕복 확인.
