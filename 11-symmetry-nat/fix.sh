#!/usr/bin/env bash
# ★ 11장 한 줄 수정: 리턴 경로를 대칭(edge)으로
set -euo pipefail
P=clab-11-symmetry-nat

docker exec $P-srtr ip route replace 10.11.1.0/24 via 10.11.0.1
echo "fixed: srtr의 클라 대역 리턴이 edge(대칭 경로)로 — SYN-ACK 소스가 서버 본인이 된다"

# [실습 D를 거친 경우 원상 복구]
#   docker exec $P-nat iptables -t nat -F                       # D-2의 masquerade 제거
#   (D-1에서 지운 stateless 재작성은 재배포로만 복원 — 고장 재현이 필요하면 destroy 후 deploy)
