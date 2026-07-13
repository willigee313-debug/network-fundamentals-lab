#!/bin/bash
# network-lab EC2 부트스트랩 (Amazon Linux 2023 전용) — EC2 user-data로 사용
#
# 검증: 2026-07-12, AL2023(커널 6.1) + t3.medium(x86) + docker 25.x 에서 전 구성요소 실측.
#       프라이빗 서브넷 + NAT(아웃바운드 인터넷) 전제.
#
# ── 사용 전 아래 둘 중 하나를 채울 것 ─────────────────────────────
REPO_URL=""        # 사내 git 원격이 있으면: https://<git>/network-lab.git
TARBALL_URL=""     # 원격이 없으면: 저장소 tar.gz의 URL (예: S3 presigned)
                   #   로컬에서 생성: git archive --format=tar.gz -o network-lab.tar.gz HEAD
RUN_SMOKE="true"   # 부팅 시 M0 PoC 스모크 테스트 실행 (약 2~3분 추가)
# ────────────────────────────────────────────────────────────────

exec > /var/log/network-lab-bootstrap.log 2>&1
set -x

# 1) Docker + git (AL2023은 get.docker.com 미지원 → dnf)
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user

# 2) 저장소 가져오기
cd /opt
if [ -n "$REPO_URL" ]; then
  git clone "$REPO_URL" network-lab
elif [ -n "$TARBALL_URL" ]; then
  curl -sf -o network-lab.tar.gz "$TARBALL_URL"
  mkdir -p network-lab && tar xzf network-lab.tar.gz -C network-lab
else
  echo "FATAL: REPO_URL 또는 TARBALL_URL을 설정하세요" ; exit 1
fi
chmod +x /opt/network-lab/clab.sh
chown -R ec2-user:ec2-user /opt/network-lab

# 3) 이미지 프리풀 — 학습자의 첫 deploy 대기 제거
docker pull ghcr.io/srl-labs/clab:latest
docker pull nicolaka/netshoot:latest
docker pull frrouting/frr:latest        # 17장용 (x86 인스턴스면 네이티브 실행)

# 4) 스모크 테스트 — 이 호스트에서 전 장이 돌아가는지 M0 PoC로 판정
if [ "$RUN_SMOKE" = "true" ]; then
  cd /opt/network-lab
  if ./clab.sh deploy poc/m0-poc.clab.yml > /tmp/smoke-deploy.log 2>&1; then
    P=clab-m0-poc
    VXLAN=$(docker exec $P-vtep1 ping -c2 -W2 192.168.100.2 | grep -o '[0-9]*% packet loss')
    VLANF=$(docker exec $P-swa ip -d link show br0 | grep -o 'vlan_filtering 1')
    CTRK=$(docker exec $P-nat sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=30 \
           >/dev/null 2>&1 && echo ok || echo FAIL)
    ./clab.sh destroy poc/m0-poc.clab.yml >/dev/null 2>&1
    echo "SMOKE_OK vxlan=[$VXLAN] ${VLANF:-vlan_filtering_FAIL} conntrack=$CTRK $(date -Is)" \
      > /opt/network-lab/SMOKE_TEST_RESULT
  else
    echo "SMOKE_FAIL $(date -Is) — /tmp/smoke-deploy.log 확인" > /opt/network-lab/SMOKE_TEST_RESULT
  fi
  chown ec2-user:ec2-user /opt/network-lab/SMOKE_TEST_RESULT
fi

echo BOOTSTRAP_DONE
