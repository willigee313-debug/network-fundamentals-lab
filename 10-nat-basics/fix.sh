#!/usr/bin/env bash
# 10장 한 줄 수정
set -euo pipefail
P=clab-10-nat-basics

# [실습 A] 사설→"인터넷" 방향 소스 재작성 활성화
docker exec $P-nat iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE
echo "fixed: nat에 MASQUERADE 추가 — cli→srv 통신은 nat IP를 빌려 왕복한다"
