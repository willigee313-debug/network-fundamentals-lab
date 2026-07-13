# 06장 모범 답안 — 전체 명령 실행 기록

> 루프 증상 → 시각화 → TTL 물증 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 06-ttl-loop/06-ttl-loop.clab.yml   # → h1, r1, r2 running (상호 디폴트 장전)
```

## 단계 A — 증상: 루프는 자백한다
**의도**: 존재하지 않는 목적지(198.51.100.1, 문서용 대역)로 보내 "모르는 트래픽"의 운명 관찰.
```sh
docker exec clab-06-ttl-loop-h1 ping -c2 198.51.100.1
```
```
From 10.6.0.2 icmp_seq=1 Time to live exceeded
From 10.6.0.2 icmp_seq=2 Time to live exceeded
2 packets transmitted, 0 received, +2 errors, 100% packet loss
```
**해석**: 지금까지 본 실패들과 또 다른 **제3의 지문** — 침묵(05)도, "길 없음"(04)도 아닌
"**Time to live exceeded**". 번역하면 "당신 패킷이 어딘가를 뱅뱅 돌다 수명이 다해 죽었다".
발신지 10.6.0.2(r2) = 수명이 다한 지점.

## 단계 B — traceroute: 루프의 시각화
**의도**: "뱅뱅 돈다"를 홉 목록으로 직접 확인.
```sh
docker exec clab-06-ttl-loop-h1 traceroute -n -w1 -q1 -m8 198.51.100.1
```
```
 1  10.6.1.1     ← r1
 2  10.6.0.2     ← r2
 3  10.6.1.1     ← 다시 r1?!
 4  10.6.0.2
 5  10.6.1.1
 6  10.6.0.2
 7  10.6.1.1
 8  10.6.0.2     ← 같은 두 홉의 무한 교대 = 루프 확정
```
**해석**: TTL을 1씩 늘려 보내는 traceroute의 원리 덕에, 루프가 **홉 목록의 반복**으로 그대로
그려진다. r1과 r2가 서로 "모르는 건 쟤한테"를 반복하는 상호 디폴트 구조.

## 단계 C — 물증: 같은 패킷의 TTL이 깎이며 왕복한다
**의도**: 전송 링크의 프레임들에서 TTL 필드만 뽑아 "동일 패킷의 노화"를 관찰.
```sh
docker exec clab-06-ttl-loop-r1 tcpdump -vnli eth2 icmp     # 켜두고 ping 1발
```
```
ttl 63  ttl 62  ttl 61  ttl 60  ttl 59  ttl 58 ...
```
**해석**: 새 패킷들이 아니라 **한 개의 echo request가 홉을 돌 때마다 1씩 늙는** 모습이다.
64에서 출발해 0이 되는 순간 그 자리의 라우터가 폐기 + time-exceeded 발신(단계 A의 메시지).
02장과의 대비가 완성된다: L2 프레임엔 이 카운터가 없어 스톰이 무한했고, **L3는 TTL 덕에
루프조차 유한하다.**

## 단계 D — 한 줄 수정 + 판정
**의도**: 루프의 근본 원인(모르는 걸 서로 미루기)을 끊는다 — 모르는 목적지는 명시적으로 거절.
```sh
docker exec clab-06-ttl-loop-r2 ip route replace unreachable default
```
```
ping       → From 10.6.0.2: Destination Host Unreachable   ← 즉시, 명시적 거절
traceroute → 1  10.6.1.1 / 2  10.6.0.2 !H                   ← r2에서 딱 끊긴다 (!H = host unreachable)
```
**해석**: 목적지는 여전히 없으니 통신이 "되는" 건 아니다. 그러나 **수십 홉을 태우며 돌다 죽는 것**
과 **두 홉 만에 명시적으로 거절되는 것**은 대역폭·지연·진단 가능성에서 전혀 다르다.
traceroute의 `!H` 표기가 "여기가 끝, 이유는 host unreachable"이라고 정확히 말해준다.

## 정리
```sh
./clab.sh destroy 06-ttl-loop/06-ttl-loop.clab.yml
```
**이 장의 판정 요약**: "Time to live exceeded" 반복 = 루프 자백 → traceroute 홉 교대로 확정 →
tcpdump TTL 감소 행렬로 물증 → default 정리(명시적 거절)로 종결.
