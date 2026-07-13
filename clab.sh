#!/usr/bin/env bash
# containerlab-in-docker 래퍼 (macOS/containerlab 미설치 환경용)
#
# macOS는 containerlab이 호스트 netns/veth를 직접 다루지 못하므로,
# containerlab을 컨테이너로 띄워 Docker Desktop VM의 네임스페이스 위에서 실행한다.
#   --privileged --pid=host --network=host + docker.sock 마운트 가 핵심.
#
# 사용법 (저장소 루트 network-lab/ 에서 실행, 토폴로지는 repo 기준 상대경로):
#   ./clab.sh deploy   01-l2-arp/01-l2-arp.clab.yml
#   ./clab.sh inspect  01-l2-arp/01-l2-arp.clab.yml
#   ./clab.sh destroy  01-l2-arp/01-l2-arp.clab.yml
#   ./clab.sh <임의 containerlab 서브커맨드> <topo> [추가옵션...]
#
# 이미지 오버라이드: CLAB_IMAGE=ghcr.io/srl-labs/clab:0.77.0 ./clab.sh ...
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <deploy|destroy|inspect|...> <topo.clab.yml (repo-relative)> [extra args]" >&2
  exit 1
fi

CMD="$1"; TOPO="$2"; shift 2

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO_DIR="$(dirname "$TOPO")"
TOPO_FILE="$(basename "$TOPO")"
IMAGE="${CLAB_IMAGE:-ghcr.io/srl-labs/clab:latest}"

if [[ ! -f "$REPO/$TOPO" ]]; then
  echo "error: topology not found: $REPO/$TOPO" >&2
  exit 1
fi

exec docker run --rm --privileged --network host --pid host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$REPO":/lab -w "/lab/$TOPO_DIR" \
  --entrypoint containerlab "$IMAGE" "$CMD" -t "$TOPO_FILE" "$@"
