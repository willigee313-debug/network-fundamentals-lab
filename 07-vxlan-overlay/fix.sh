#!/usr/bin/env bash
# 07장 수정: vtep2의 VNI를 100으로 (VNI는 변경 불가 → 삭제 후 재생성)
set -euo pipefail
P=clab-07-vxlan-overlay

docker exec $P-vtep2 bash -c "ip link del vxlan100 && \
  ip link add vxlan100 type vxlan id 100 local 10.7.2.1 remote 10.7.1.1 dstport 4789 dev eth1 && \
  ip addr add 192.168.100.2/24 dev vxlan100 && ip link set vxlan100 up"
echo "fixed: vtep2 VNI 200→100 — overlay ping 192.168.100.2 가 돼야 함"
