# 09장 모범 답안 — 전체 명령 실행 기록

> 번역표 읽기 → idle 사망 타임라인 → 포트 고갈 → 수정까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 09-conntrack/09-conntrack.clab.yml   # → cli, nat, srv running (timeout 30s + 포트 2개 장전)
```

## 단계 A — 번역표(conntrack) 읽는 법
**의도**: 연결 하나를 열어두고, NAT 장비가 그것을 어떻게 "기억"하는지 원문으로 읽기.
```sh
docker exec -d clab-09-conntrack-cli bash -c "sleep 120 | nc 10.9.2.10 7777"
docker exec clab-09-conntrack-nat conntrack -L | grep 7777
```
```
tcp  6  27 ESTABLISHED  src=10.9.1.10 dst=10.9.2.10 sport=59052 dport=7777
                        src=10.9.2.10 dst=10.9.2.1  sport=7777  dport=30000  [ASSURED]
```
**해석**: 한 줄을 네 토막으로 읽는다 — ① `tcp 6` 프로토콜, ② **`27` = 남은 수명(초)**:
설정된 30에서 깎이는 중(고장 ①이 이미 카운트다운 중), ③ 앞 튜플 = 원방향(cli:59052→srv:7777),
④ 뒤 튜플 = 응답방향(srv→**10.9.2.1:30000**) — cli의 59052가 NAT의 30000으로 재작성됐음이
표에 그대로 보인다. `[ASSURED]` = 양방향 트래픽 확인됨.

## 단계 B — 장수 연결의 조용한 죽음 (타임라인 실측)
**의도**: "hello → 40초 방치(>30초 timeout) → world"로 idle 만료의 전 과정을 시간축으로 관찰.
```sh
( echo hello; sleep 40; echo world; sleep 8 ) | nc 10.9.2.10 7777
```
```
t=8s   수신함="hello"                        ← 연결 정상, 에코 즉시 도착
       conntrack: tcp 6 19 ESTABLISHED       ← 수명 19초 남음 (30에서 깎이는 중)
t=38s  conntrack 엔트리 수: 0                 ← 기억 소멸. 양끝 소켓은 아직 "연결됨" 상태!
t=53s  수신함="hello" (world의 에코는 영원히 없음)
```
world 패킷의 운명 (cli 캡처):
```
11:03:26.888  Flags [P.], seq ...:...+6      ← world\n(6바이트) 발신
11:03:27.093  Flags [P.], seq 0:6            ← 0.2초 뒤 재전송
11:03:27.303  Flags [P.], seq 0:6            ← 또... (지수 백오프, ACK는 영원히 없음)
```
**해석**: 이 장애의 지문은 **"완벽한 침묵"** — 에러도 RST도 ICMP도 없다. 앱 관점에선
write()는 성공(로컬 버퍼)했는데 응답만 없는 상태로 매달린다. nat이 INVALID(기억에 없는 패킷)를
조용히 버리기 때문. 실무의 "커넥션 풀이 새벽마다 죽어요"가 정확히 이 모양이다.

## 단계 C — SNAT 포트 고갈: "기존은 되는데 신규만 안 됨"
**의도**: 포트 2개를 동시 연결 2개로 채운 뒤, 3번째 연결의 운명과 **장비 쪽 물증**을 확보.
```sh
# 홀딩 연결 2개 생성 후:
docker exec clab-09-conntrack-nat bash -c "conntrack -L | grep -oE 'dport=3000[01]' | sort | uniq -c"
docker exec clab-09-conntrack-cli bash -c "time nc -zv -w 4 10.9.2.10 7777"
docker exec clab-09-conntrack-nat conntrack -S | grep insert_failed
```
```
1 dport=30000 / 1 dport=30001        ← 할당 가능한 포트 2개 전부 점유
3번째: timed out, real 0m4.009s       ← 기존 2개는 멀쩡한 채 신규만 실패
insert_failed=1  insert_failed=3      ← 0이 아니다 = 할당 실패의 물증
```
**해석**: 증상의 비대칭("기존 OK, 신규만 타임아웃")이 이 부류 고장의 최대 힌트다.
클라 쪽에선 그냥 타임아웃(08장 지문)이라 원인을 못 가리지만, **장비의 `insert_failed`
카운터**가 결정적 물증 — 티켓에 붙일 수 있는 숫자다.

## 단계 D — 수정 + 판정 (fix.sh)
```sh
./09-conntrack/fix.sh    # timeout 30→3600s + SNAT 포트 30000-30999
```
```
3번째 연결 재시도 → succeeded! real 0m0.001s
```
**해석**: 포트 범위 확대 즉시 신규 연결 성공. idle 쪽 근본 대책은 양자택일이 아니라 협상 —
장비 timeout 상향(운영)과 TCP keepalive(앱) 중 **양쪽 사정을 아는 사람이 정할 것.**

## 정리
```sh
./clab.sh destroy 09-conntrack/09-conntrack.clab.yml
```
**이 장의 판정 요약**: conntrack 한 줄에서 수명·번역을 읽는다 → idle 사망 = 완벽한 침묵 +
재전송만 → 포트 고갈 = "신규만 실패" + `insert_failed` 물증.
