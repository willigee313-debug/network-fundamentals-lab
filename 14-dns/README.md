# 14장. DNS 기본 — 이름의 계층에서 나는 장애

> IP의 세계(01~12장)가 멀쩡해도 서비스는 죽을 수 있다 — **이름이 엉뚱한 곳을 가리키면.**
> 이 장의 핵심 경험 두 가지: **"서버를 고쳤는데도 안 됨"(캐시/TTL)** 과
> **"요청 절반만 느림"(다중 A + 죽은 타깃)**. 그리고 진단의 제1원칙:
> **이름의 문제인지 IP의 문제인지부터 갈라라.**

## 0. 학습 목표
- 해석 경로 읽기: `/etc/resolv.conf` → 리졸버(캐시) → 권한 서버
- **TTL = 캐시의 수명 = 사실상 페일오버 소요 시간**임을 실측으로
- `dig`로 **계층을 분리해 질의**하는 법 (`@리졸버` vs `@권한서버`)
- 다중 A 레코드에 죽은 주소가 섞이면 생기는 간헐 지연

---

## 1. 개념

### 1-1. 이름이 IP가 되기까지
```
앱 → (/etc/hosts?) → /etc/resolv.conf의 리졸버(cache) → 권한 서버(auth)
                        └─ 응답을 TTL 동안 캐시 ←──────────┘
```
- 앱이 보는 답은 대부분 **리졸버의 캐시**다. 권한 서버를 고쳐도 캐시가 살아있으면 세상은 옛날 답을 듣는다.

### 1-2. TTL의 양면
- 길면: 질의 부하↓, 그러나 **레코드 변경이 최악 TTL초 동안 전파 안 됨**.
- **TTL은 곧 "장애 조치가 먹히기까지의 시간"** — 페일오버를 설계한다면 TTL부터 설계하라.

## 2. 토폴로지
```
  cli(.10)  cache(.53)  auth(.54)  srv1(.101,죽음)  srv2(.102,정상)
     └─────────┴──────────┴────────────┴───────────────┘
                     sw (전부 10.14.0.0/24)

  app.lab   A .101 (TTL 3600)   ← 죽은 서버를 가리키는 중 (장전된 고장)
  multi.lab A .101 + .102       ← 다중 A, 절반이 죽음
```

## 3. 실습 준비
```sh
./clab.sh deploy 14-dns/14-dns.clab.yml
```
> 노드: `clab-14-dns-<cli|cache|auth|srv1|srv2|sw>` · cache/auth는 배포 중 `apk add dnsmasq`
> (인터넷 필요). srv1의 80 포트는 nft drop = "죽은 서버".

---

## 4. 실습 A — 해석 기초와 TTL 카운트다운

```sh
docker exec clab-14-dns-cli cat /etc/resolv.conf     # nameserver 10.14.0.53 (cache)
docker exec clab-14-dns-cli dig +short app.lab       # → 10.14.0.101
docker exec clab-14-dns-cli dig app.lab | grep -A1 "ANSWER"   # 두 번 연속 실행해 보라
```
✅ 실측:
```
app.lab.   3600  IN  A  10.14.0.101     ← 첫 질의: TTL 3600 (auth의 답)
app.lab.   3598  IN  A  10.14.0.101     ← 2초 뒤: 3598 — cache가 답하며 수명을 깎는 중
```
**해설**: TTL이 깎여서 내려온다 = **캐시가 답하고 있다**는 지문. 이 숫자가 곧
"권한 서버를 고쳐도 반영 안 되는 잔여 시간"이다.

## 5. 실습 B — "서버를 고쳤는데도 안 됨" (캐시 스테일)

**① 현재 증상**: app.lab(.101)이 죽어 있다
```sh
docker exec clab-14-dns-cli bash -c "time curl -s -m 3 http://app.lab/"
# → 실패, real 0m3.008s   (실측 — .101은 침묵하는 죽은 서버)
```

**② "장애 조치" — 권한 서버의 레코드를 살아있는 .102로 변경**
```sh
docker exec clab-14-dns-auth bash -c "pkill dnsmasq; dnsmasq --no-resolv --no-hosts \
  --local-ttl=3600 --host-record=app.lab,10.14.0.102 \
  --host-record=multi.lab,10.14.0.101 --host-record=multi.lab,10.14.0.102 \
  --listen-address=10.14.0.54 --bind-interfaces"
```

**③ 그런데... (계층 분리 질의 — 이 장의 핵심 기술)**
```sh
docker exec clab-14-dns-cli dig +short @10.14.0.54 app.lab   # 권한 서버에 직접
docker exec clab-14-dns-cli dig app.lab                       # 평소 경로(cache)로
```
✅ 실측:
```
@auth(직접):  10.14.0.102          ← 권한 서버는 이미 새 답을 안다
@cache(평소): 10.14.0.101 (TTL 3577) ← 그러나 세상은 아직 옛 답을 듣는다
curl http://app.lab/ → 여전히 실패!
```
**해설**: 조치는 완벽했는데 장애는 계속된다. `dig @권한서버` vs `dig @리졸버` 답이 갈리면
**범인은 캐시**로 확정 — 최대 TTL(여기선 1시간)을 기다리거나 캐시를 비워야 한다.

**④ 진짜 수정 — 캐시 비우기**
```sh
docker exec clab-14-dns-cache pkill -HUP dnsmasq      # dnsmasq는 SIGHUP으로 캐시 클리어
```
✅ 실측: `dig +short app.lab → 10.14.0.102` · `curl → pong-from-srv2 (0.003s)`

**교훈**: 캐시 플러시는 사후약방문이다(모든 클라이언트/중간 리졸버를 다 비울 수는 없다).
**근본 설계는 TTL** — 페일오버가 5분 안에 먹혀야 한다면 TTL이 5분을 넘으면 안 된다.

## 6. 실습 C — 다중 A + 죽은 타깃 = "절반만 느림"

```sh
docker exec clab-14-dns-cli dig +short multi.lab      # .101(죽음) + .102(정상) 두 개
for i in 1 2 3 4 5; do docker exec clab-14-dns-cli bash -c \
  "time curl -s -m 5 http://multi.lab/ >/dev/null"; done
```
✅ 실측 (5회 연속):
```
시도1: 0.212s   ← 죽은 .101 먼저 시도 → 포기 → .102로 폴백
시도2: 0.004s   ← .102 먼저 → 즉시
시도3: 0.214s
시도4: 0.005s
시도5: 0.211s   ← 정확히 교대: 리졸버가 라운드로빈으로 순서를 바꿔주기 때문
```
**해설**: 실패는 안 한다(curl이 다음 주소로 폴백하므로) — 대신 **요청 절반이 50배 느리다.**
모니터링엔 "간헐 지연"으로만 보이는 고약한 증상. DNS 라운드로빈은 로드밸런싱이지
**헬스체크가 아니다** — 죽은 타깃을 스스로 빼주지 않는다.

---

## 7. 정리 / 교훈
- 진단 제1원칙: **`dig`(이름)와 `ping/nc`(IP)를 분리하라.** "이름으론 안 되는데 IP론 되면" DNS 계층 확정.
- 제2원칙: **`dig @권한서버` vs `dig @리졸버`** — 답이 갈리면 캐시가 범인.
- **TTL 깎임 = 캐시가 답하는 중**이라는 지문. TTL은 페일오버 시간의 설계 변수다.
- 다중 A + 죽은 타깃 = 간헐 지연. 라운드로빈에 헬스체크를 기대하지 마라.

## 8. 치트시트
| 목적 | 명령 |
|---|---|
| 평소 경로로 질의 | `dig <이름>` (TTL 깎임 확인) |
| 특정 서버에 직접 | `dig @<서버IP> <이름>` |
| 짧은 답만 | `dig +short <이름>` |
| 내 리졸버 확인 | `cat /etc/resolv.conf` |
| dnsmasq 캐시 클리어 | `pkill -HUP dnsmasq` |

## 9. 랩 정리
```sh
./clab.sh destroy 14-dns/14-dns.clab.yml
```

---
### 다음 장 예고
코어 트랙 완주! 이제 **블라인드 체크포인트**(checkpoints/)에서 README 없이 스스로
진단해 보라. 확장 트랙은 06(TTL 루프)·07(VXLAN)·13(터널 MTU)·15(ICMP 차단)·16(헤어핀)·17(동적 라우팅).
