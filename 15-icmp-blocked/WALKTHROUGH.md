# 15장 모범 답안 — 전체 명령 실행 기록

> 오판 체험 → 진단 도구 붕괴 → 선별 허용 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 15-icmp-blocked/15-icmp-blocked.clab.yml   # → h1, fw, srv running (ICMP 전면 차단 장전)
```

## 단계 A — 오판 체험: "서버 죽은 것 같은데요?"
**의도**: 관측 채널(ICMP)과 서비스 채널(TCP/80)을 **따로** 두드려 결과를 대조.
```sh
docker exec clab-15-icmp-blocked-h1 ping -c2 10.15.2.10
docker exec clab-15-icmp-blocked-h1 bash -c "time curl -s -m 3 http://10.15.2.10/"
```
```
ping → 100% packet loss           ← 모니터링/직감: "죽었다!"
curl → alive (real 0m0.008s)      ← 서비스: "저 멀쩡한데요"
```
**해석**: 같은 서버에 대한 두 판정이 정반대다. ping과 서비스는 **다른 프로토콜 채널**이고,
중간 장비(fw)가 채널별로 다르게 취급하면 관측과 실재가 갈라진다. 실무 규칙 두 개가 도출된다 —
① **"ping 안 됨"만으로 장애 선언 금지**(반대로 "ping 되는데 서비스 죽음"도 성립, 08장),
② 최종 판정은 항상 **서비스 채널**(`curl`/`nc`)로.

## 단계 B — 진단 도구의 연쇄 붕괴
**의도**: ICMP 전면 차단이 ping 외에 무엇을 더 부수는지 확인.
```sh
docker exec clab-15-icmp-blocked-h1 traceroute -n -w1 -q1 -m4 10.15.2.10
```
```
 1  10.15.1.1    ← fw 자신 (여기까진 fw가 직접 응답)
 2  *
 3  *
 4  *            ← 그 너머는 암흑
```
**해석**: traceroute = TTL + **ICMP time-exceeded**(06장) — 그 응답이 차단되니 경로 전체가
진단 불가 영역이 된다. 여기에 12장의 조합(경로에 좁은 MTU)이 겹치면 frag-needed도 차단되어
**PMTUD 블랙홀까지 덤**. "보안상 ICMP 전부 차단"의 실제 청구서.

## 단계 C — 수정: 전면 차단 대신 선별 허용
**의도**: 보안 요구(redirect 등 차단)와 운영 요구(진단·PMTUD)가 양립함을 증명.
```sh
./15-icmp-blocked/fix.sh
# = echo-request/reply, destination-unreachable, time-exceeded 만 accept, 나머지 icmp drop
```
```
ping       → 0% packet loss
traceroute → 1  10.15.1.1 / 2  10.15.2.10     ← 경로가 다시 보인다
curl       → alive                             ← 서비스는 그대로
```
**해석**: 필수 4타입만 열어도 ping·traceroute·PMTUD가 전부 복원되고, 나머지 ICMP는 계속
차단된다. 전면 차단은 게으른 선택이었을 뿐 — 방화벽 정책 리뷰 때의 질문은
*"echo / dest-unreachable(특히 frag-needed) / time-exceeded 가 살아 있는가?"*.

## 정리
```sh
./clab.sh destroy 15-icmp-blocked/15-icmp-blocked.clab.yml
```
**이 장의 판정 요약**: ping과 서비스 채널의 판정이 갈리면 중간 장비의 프로토콜별 정책을 의심 →
traceroute 실명 여부로 ICMP 차단 확정 → 선별 허용으로 보안과 진단 양립.
