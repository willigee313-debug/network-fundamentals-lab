#!/usr/bin/env bash
# 05장 한 줄 수정 모음
set -euo pipefail
P=clab-05-lpm-blackhole

# [기본 고장] r1의 blackhole /32 제거 → /24 연결 경로가 다시 이긴다
docker exec $P-r1 ip route del blackhole 10.5.2.10/32 2>/dev/null \
  || docker exec $P-r1 ip route del unreachable 10.5.2.10/32   # 실습 C를 거친 경우
echo "fixed: r1의 10.5.2.10/32 특수 라우트 제거"
