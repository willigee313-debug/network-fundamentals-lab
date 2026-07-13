#!/usr/bin/env bash
# 04장 한 줄 수정 모음
set -euo pipefail
P=clab-04-l3-routing

# [기본 고장] r2에 클라이언트 대역 리턴 라우트 추가
docker exec $P-r2 ip route replace 10.4.1.0/24 via 10.4.0.1
echo "fixed: r2에 10.4.1.0/24 via 10.4.0.1 설치"

# [변형 C-1 복구] r1 포워딩 재활성화:
#   docker exec $P-r1 sysctl -w net.ipv4.ip_forward=1
# [변형 C-2 복구] h1 기본 게이트웨이 재설정:
#   docker exec $P-h1 ip route add default via 10.4.1.1
