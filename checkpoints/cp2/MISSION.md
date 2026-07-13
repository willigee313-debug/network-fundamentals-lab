# CP-2 미션 — 상태/NAT 종합 자가 진단 테스트 (08~11장 범위)

## 상황
새벽 릴리스 후 티켓:

> **"cli에서 서비스(10.92.2.10:443)가 타임아웃입니다. 서버팀은 '요청 받고 응답도 보냈다'고
> 합니다. 네트워크팀은 어제 라우팅을 좀 만졌다고 하고요."**

## 배포
```sh
./clab.sh deploy checkpoints/cp2/scenario.clab.yml
```
노드: `clab-cp2-<cli|edge|srtr|nat|srv>`
구성: `cli — edge — srtr — srv(:443)`, nat은 edge/srtr 양쪽에 연결된 부가 장비.

## 규칙
- **`scenario.clab.yml`과 `SOLUTION.md`를 먼저 보지 말 것.**
- 도구 자유: tcpdump / ip route get / nft list ruleset / conntrack ...
- **함정 주의**: 눈에 띄는 것이 다 원인은 아니다. 증거 없이 고치지 말 것.

## 목표
1. "서버는 응답했다는데 클라는 타임아웃"의 원인을 **패킷 증거**로 특정
2. 한 줄 수정으로 복구: `echo hi | nc 10.92.2.10 443` → `cp2-ok`
3. 조사 중 발견한 "수상해 보이지만 무관한 것"이 있다면 그것도 보고서에 (실무의 절반은 무죄 증명이다)

## 다 풀었으면
`SOLUTION.md` 대조 → `./clab.sh destroy checkpoints/cp2/scenario.clab.yml`
