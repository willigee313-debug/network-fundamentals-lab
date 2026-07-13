#!/usr/bin/env bash
# 17장 수정 모음 (토포별)
set -euo pipefail

# [17a OSPF] r2의 area 1 → 0 (+ 필요시 재선거)
if docker ps --format '{{.Names}}' | grep -q clab-17-ospf; then
  P=clab-17-ospf
  docker exec $P-r2 vtysh -c "conf t" -c "router ospf" \
    -c "no network 10.17.0.0/30 area 1" -c "no network 10.17.2.0/24 area 1" \
    -c "network 10.17.0.0/30 area 0" -c "network 10.17.2.0/24 area 0"
  docker exec $P-r1 vtysh -c "clear ip ospf interface eth2"
  docker exec $P-r2 vtysh -c "clear ip ospf interface eth1"
  echo "fixed(17a): r2 area 0 + 재선거 — 수십 초 후 'show ip ospf neighbor'에 Full"
fi

# [17b BGP] r1에 network 문 추가
if docker ps --format '{{.Names}}' | grep -q clab-17-bgp; then
  P=clab-17-bgp
  docker exec $P-r1 vtysh -c "conf t" -c "router bgp 65001" \
    -c "address-family ipv4 unicast" -c "network 10.17.1.0/24"
  echo "fixed(17b): r1이 10.17.1.0/24 광고 시작 — r2 PfxRcd 1"
fi
