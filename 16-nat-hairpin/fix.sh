#!/usr/bin/env bash
# 16장 한 줄 수정: 헤어핀 구간 한정 MASQUERADE
set -euo pipefail
P=clab-16-nat-hairpin

docker exec $P-nat iptables -t nat -A POSTROUTING \
  -o eth1 -s 10.16.1.0/24 -d 10.16.1.20 -p tcp --dport 80 -j MASQUERADE
echo "fixed: 헤어핀 SNAT — curl http://10.16.99.1:8080/ → pong-hairpin"
