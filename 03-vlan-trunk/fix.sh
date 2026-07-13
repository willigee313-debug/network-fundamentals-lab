#!/usr/bin/env bash
# 03장 한 줄 수정: sw2 트렁크에 VLAN 10 허용 추가
set -euo pipefail
P=clab-03-vlan-trunk

docker exec $P-sw2 bridge vlan add dev eth2 vid 10
echo "fixed: sw2 트렁크(eth2)에 vid 10 허용 — h1(V10)↔h2(V10) 통신 회복, h3(V20) 격리는 유지"
