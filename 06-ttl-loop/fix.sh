#!/usr/bin/env bash
# 06장 한 줄 수정: 상호 디폴트 루프 제거 — 모르는 목적지는 명시적으로 거절
set -euo pipefail
P=clab-06-ttl-loop

docker exec $P-r2 ip route replace unreachable default
echo "fixed: r2의 default가 unreachable — 루프 대신 즉시 Destination Unreachable"
