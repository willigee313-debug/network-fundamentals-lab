#!/usr/bin/env bash
# 12장 한 줄 수정 모음
set -euo pipefail
P=clab-12-mtu-pmtud

# [근본 수정] r1의 frag-needed 차단 해제 → PMTUD 부활
docker exec $P-r1 nft flush chain ip fw output
echo "fixed: ICMP frag-needed 허용 — h1이 'mtu = 1400'을 통보받고 학습한다"

# [응급처치 변형] TCP만 살리는 MSS clamp (ICMP 차단 상태에서도 동작):
#   docker exec $P-r1 iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
