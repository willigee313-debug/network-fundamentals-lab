# CP-1 해설 — ⚠️ 스포일러! 스스로 풀기 전엔 열지 말 것

## 심어진 고장 (2개)
1. **r1: `blackhole 10.91.2.10/32`** — 05장의 LPM 블랙홀
2. **r2: `10.91.1.0/24` 리턴 라우트 누락** — 04장의 편도 성립

핵심 설계: **하나를 고치면 증상이 "바뀌며" 다음 고장이 드러난다.**

## 모범 진단 경로 (실측 출력)

### 1단계 — 증상 지문 채집
```
curl → 타임아웃 (즉시 에러가 아님 = 조용한 소실 계열)
traceroute → 1 * / 2 * / 3 *        ← 첫 홉부터 전멸!
```
05장의 지문: **첫 홉(r1)조차 침묵 = 라우팅 단계 드랍 = blackhole류**를 의심.
(04장식 리턴 누락이면 1번 홉은 응답했을 것)

### 2단계 — r1 조사
```
r1$ ip route get 10.91.2.10
RTNETLINK answers: Invalid argument     ← 05장의 기묘한 지문 = blackhole 확정
r1$ ip route show | grep black
blackhole 10.91.2.10
```
**수정 ①**: `docker exec clab-cp1-r1 ip route del blackhole 10.91.2.10/32`

### 3단계 — 증상이 "진화"했다 (전진!)
```
curl → 여전히 타임아웃. 그러나:
traceroute → 1 10.91.1.1 / 2 * / 3 *   ← 이제 r1은 보인다. r2부터 침묵
```
08장의 교훈 그대로: 에러가 바뀌면 한 꺼풀 벗겨진 것. 04장의 지문으로 전환 —
**"r2 너머가 침묵" = r2의 포워딩 또는 리턴을 의심.**

### 4단계 — r2 조사
```
r2$ ip route get 10.91.1.10
RTNETLINK answers: Network unreachable   ← 리턴 라우트가 없다 (04장)
```
**수정 ②**: `docker exec clab-cp1-r2 ip route replace 10.91.1.0/24 via 10.91.0.1`

### 완치 확인
```
h1$ curl http://10.91.2.10/  →  cp1-ok
```

## 채점 기준
| 항목 | 통과 |
|---|---|
| traceroute "전부 *" vs "r1까지" 차이를 읽었나 | 05 vs 04 지문 구분 |
| 각 수정 전에 **증거**(route get/show 출력)를 댔나 | 추측 수리 금지 |
| 1차 수정 후 "여전히 안 됨"에서 후퇴하지 않았나 | 증상 진화 = 전진 |

## 정리
```sh
./clab.sh destroy checkpoints/cp1/scenario.clab.yml
```
