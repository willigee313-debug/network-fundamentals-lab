#!/usr/bin/env bash
# 02장 한 줄 수정 모음
set -euo pipefail
P=clab-02-bcast-loop

# [실습 B 수정] 루프가 있어도 스톰이 없도록: 양쪽 스위치 STP 활성화 (~30초 수렴)
docker exec $P-sw1 ip link set br0 type bridge stp_state 1
docker exec $P-sw2 ip link set br0 type bridge stp_state 1
echo "STP enabled on sw1/sw2 — ~30s 후 'bridge -d link show'에서 blocking 포트 확인"

# [비상 탈출] 스톰이 감당 안 될 때 루프 물리 절단:
#   docker exec $P-sw1 ip link set eth3 down
