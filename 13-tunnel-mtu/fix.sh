#!/usr/bin/env bash
# 13장 한 줄 수정: vtep1의 오버레이 MTU를 "경로 최솟값(1400) − 50"으로
set -euo pipefail
P=clab-13-tunnel-mtu

docker exec $P-vtep1 ip link set vxlan100 mtu 1350
echo "fixed: vtep1 vxlan100 mtu 1350 — ping -M dont -s 1400 192.168.100.2 가 0% loss여야 함"
