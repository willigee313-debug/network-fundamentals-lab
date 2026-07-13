#!/usr/bin/env bash
# 14장 수정 모음
set -euo pipefail
P=clab-14-dns

# [실습 B ②] "장애 조치": auth의 app.lab 레코드를 살아있는 .102로
docker exec $P-auth bash -c "pkill dnsmasq; dnsmasq --no-resolv --no-hosts \
  --local-ttl=3600 --host-record=app.lab,10.14.0.102 \
  --host-record=multi.lab,10.14.0.101 --host-record=multi.lab,10.14.0.102 \
  --listen-address=10.14.0.54 --bind-interfaces"

# [실습 B ④] 진짜 수정: cache의 캐시 비우기 (이게 없으면 TTL 만료까지 옛 답)
docker exec $P-cache pkill -HUP dnsmasq
echo "fixed: auth 레코드 .102 + cache 캐시 클리어 — curl http://app.lab/ → pong-from-srv2"
