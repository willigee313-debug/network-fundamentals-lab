# CP-1 미션 — L3 종합 자가 진단 테스트 (04·05장 범위)

## 상황
운영팀에 티켓이 들어왔다:

> **"h1에서 `curl http://10.91.2.10/` 이 타임아웃입니다. 어제까진 됐어요."**

## 배포
```sh
./clab.sh deploy checkpoints/cp1/scenario.clab.yml
```
노드: `clab-cp1-<h1|r1|r2|h2>` · 구성: `h1 — r1 — r2 — h2(웹서버 :80)`

## 규칙
- **`scenario.clab.yml`과 `SOLUTION.md`를 먼저 보지 말 것.** (배포 명령만 복사해 쓸 것)
- 04·05장에서 배운 도구만으로: `ip route get` / `ip route show` / `traceroute` / `ping` / `tcpdump`
- 추측 수리 금지 — **"어느 장비의 무엇" 때문인지 증거를 대고**, 한 줄 수정으로 고칠 것.

## 목표
1. 원인을 **증거(명령 출력)** 와 함께 특정한다.
2. 한 줄 수정으로 복구한다: `curl http://10.91.2.10/` → `cp1-ok`
3. ⚠️ 힌트: 고장은 **하나가 아닐 수 있다.** 고쳤는데 증상이 *바뀌기만* 했다면, 그건 전진이다 (08장 교훈).

## 다 풀었으면
`SOLUTION.md`와 대조 → `./clab.sh destroy checkpoints/cp1/scenario.clab.yml`
