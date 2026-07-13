#!/usr/bin/env bash
# 08장 수정 모음 (이 장의 목적은 분류 — 수정은 부록)
# 각 증상은 "자기 계층의 수정"이 필요하다:
#   :8080/:7070 → 방화벽 규칙 해제 (fw 계층)   ← 해제만 하면 이번엔 "진짜 refused"가 된다!
#   :9090/:8080/:7070 → 리스너 기동 (서버 계층)
set -euo pipefail
P=clab-08-tcp-3way

docker exec $P-fw nft flush chain ip fw forward          # fw 계층 수정
for port in 9090 8080 7070; do                            # 서버 계층 수정
  docker exec -d $P-srv socat TCP-LISTEN:$port,fork,reuseaddr SYSTEM:'echo pong'
done
echo "fixed: 4개 포트 모두 succeeded 가 되어야 함"
