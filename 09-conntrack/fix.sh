#!/usr/bin/env bash
# 09장 한 줄 수정 모음
set -euo pipefail
P=clab-09-conntrack

# [고장1] established idle timeout 30초 → 1시간
docker exec $P-nat sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600

# [고장2] SNAT 포트 범위 2개 → 1000개
docker exec $P-nat iptables -t nat -R POSTROUTING 1 \
  -o eth2 -p tcp -j SNAT --to-source 10.9.2.1:30000-30999

echo "fixed: timeout=3600s, SNAT 포트 30000-30999"
