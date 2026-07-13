# 14장 모범 답안 — 전체 명령 실행 기록

> 해석 기초 → 캐시 스테일("고쳤는데도 안 됨") → 다중 A 간헐 지연까지 전체 실행 기록.
> **의도 → 실측 결과 → 해석** 3단. 실측: 2026-07-12 · macOS + Docker Desktop (`clab.sh`)

## 0. 배포
```sh
./clab.sh deploy 14-dns/14-dns.clab.yml   # → cli, cache, auth, srv1, srv2, sw running (srv1 사망 + TTL 3600 장전)
```

## 단계 A — 해석 경로와 TTL 카운트다운
**의도**: ① 내 리졸버가 누구인지 ② 같은 질의를 연속으로 던져 **누가 답하는지**(캐시 여부) 판별.
```sh
docker exec clab-14-dns-cli cat /etc/resolv.conf        # → nameserver 10.14.0.53 (cache)
docker exec clab-14-dns-cli dig app.lab                  # 2초 간격 2회
```
```
app.lab.   3600  IN  A  10.14.0.101      ← 첫 질의
app.lab.   3598  IN  A  10.14.0.101      ← 2초 뒤: TTL이 깎여 있다
```
**해석**: **TTL이 깎여 내려온다 = 캐시가 답하는 중**이라는 지문. 3600에서 깎이는 이 숫자가
"권한 서버를 고쳐도 반영되지 않는 잔여 시간"이다 — 이 장 전체의 복선.

## 단계 B-① — 증상: 이름은 풀리는데 서비스가 죽어 있다
```sh
docker exec clab-14-dns-cli bash -c "time curl -s -m 3 http://app.lab/"
```
```
(실패) real 0m3.009s
```
**해석**: 해석(.101)은 정상, 접속이 타임아웃 — .101(srv1)이 죽어 있다. 여기까지는 서버 장애.

## 단계 B-② — "장애 조치"를 했는데도 안 됨
**의도**: 운영자가 할 법한 조치(권한 서버의 레코드를 살아있는 .102로 변경) 후,
**계층 분리 질의**(@권한서버 vs @리졸버)로 전파 상태를 확인.
```sh
# auth의 app.lab 레코드를 10.14.0.102로 변경 (dnsmasq 재기동)
docker exec clab-14-dns-cli dig +short @10.14.0.54 app.lab   # 권한 서버에 직접
docker exec clab-14-dns-cli dig app.lab                       # 평소 경로(cache)로
docker exec clab-14-dns-cli curl -s -m 3 http://app.lab/
```
```
@auth(직접):  10.14.0.102                    ← 권한 서버는 이미 새 답을 안다
@cache(평소): 10.14.0.101 (TTL 3594)          ← 세상은 아직 옛 답을 듣는다
curl → (여전히 실패)
```
**해석**: 조치는 완벽했는데 장애는 계속 — 이 장의 핵심 기술이 여기 있다.
**`dig @권한서버` vs `dig @리졸버`의 답이 갈리면 범인은 캐시로 확정.** TTL 3594 = 앞으로
약 1시간 동안 이 상태가 지속된다는 뜻. "DNS 바꿨는데 왜 안 바뀌죠" 티켓의 정체.

## 단계 B-③ — 진짜 수정: 캐시 비우기
```sh
docker exec clab-14-dns-cache pkill -HUP dnsmasq     # dnsmasq는 SIGHUP으로 캐시 클리어
```
```
dig +short app.lab → 10.14.0.102
curl → pong-from-srv2 (real 0m0.004s)
```
**해석**: 플러시 즉시 새 답 + 서비스 회복. 단, 플러시는 사후약방문(세상의 모든 리졸버를 비울
수는 없다) — **근본 설계는 TTL**: 페일오버가 5분 안에 먹혀야 한다면 TTL이 5분을 넘으면 안 된다.

## 단계 C — 다중 A + 죽은 타깃 = "절반만 느림"
**의도**: A 레코드 2개(.101 죽음, .102 정상)일 때 접속 시간이 어떻게 분포하는지 반복 측정.
```sh
docker exec clab-14-dns-cli dig +short multi.lab     # → 10.14.0.101, 10.14.0.102
for i in 1 2 3 4; do time curl -s -m 5 http://multi.lab/ >/dev/null; done
```
```
시도1: 0.208s   ← 죽은 .101 먼저 → 포기 → .102 폴백
시도2: 0.003s   ← .102 먼저 → 즉시
시도3: 0.207s
시도4: 0.003s   ← 정확히 교대 (리졸버의 라운드로빈)
```
**해석**: 실패는 없다(curl이 다음 주소로 폴백) — 대신 **요청 절반이 70배 느리다.**
모니터링에는 "간헐 지연"으로만 보이는 고약한 형태. 교훈: **DNS 라운드로빈은 로드 분산이지
헬스체크가 아니다** — 죽은 타깃을 스스로 빼주지 않는다.

## 정리
```sh
./clab.sh destroy 14-dns/14-dns.clab.yml
```
**이 장의 판정 요약**: TTL 깎임 = 캐시가 답하는 중 → `dig @권한 vs @리졸버` 분리 질의로
스테일 확정 → 플러시(응급) + TTL 설계(근본). 응답 시간의 교대 패턴 = 다중 A 속 죽은 타깃.
