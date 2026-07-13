#!/usr/bin/env bash
# 15장 수정: ICMP 전면 차단 → 필수 타입 선별 허용
set -euo pipefail
P=clab-15-icmp-blocked

docker exec $P-fw nft flush chain ip fw forward
docker exec $P-fw nft 'add rule ip fw forward icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept'
docker exec $P-fw nft 'add rule ip fw forward ip protocol icmp drop'
echo "fixed: 필수 ICMP(에코/unreachable/time-exceeded)만 허용, 나머지는 계속 차단"
