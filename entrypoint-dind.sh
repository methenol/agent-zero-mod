#!/usr/bin/env bash
set -e

info()  { echo -e "\033[1;34m[DinD]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[DinD]\033[0m $*"; }
error() { echo -e "\033[1;31m[DinD]\033[0m $*"; }

if [ ! -d /sys/fs/cgroup ]; then
    warn "cgroup filesystem not mounted — attempting mount"
    mkdir -p /sys/fs/cgroup
    mount -t tmpfs cgroup_root /sys/fs/cgroup 2>/dev/null || true
fi

for ctrl in cpuset cpu cpuacct blkio memory devices freezer net_cls perf_event net_prio hugetlb pids rdma misc; do
    if [ -d "/sys/fs/cgroup/${ctrl}" ]; then
        continue
    fi
    mkdir -p "/sys/fs/cgroup/${ctrl}" 2>/dev/null || true
    mount -t cgroup -o "${ctrl}" "cgroup_${ctrl}" "/sys/fs/cgroup/${ctrl}" 2>/dev/null || true
done

mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "iptables": true
}
EOF
fi

info "Starting Docker daemon ..."

nohup dockerd \
    --host=unix:///var/run/docker.sock \
    --host=tcp://0.0.0.0:2375 \
    > /var/log/dockerd.log 2>&1 &

DOCKERD_PID=$!
info "dockerd PID: ${DOCKERD_PID}"

MAX_WAIT=30
WAITED=0

info "Waiting for Docker daemon to become ready (up to ${MAX_WAIT}s) ..."

while ! docker info > /dev/null 2>&1; do
    if ! kill -0 "${DOCKERD_PID}" 2>/dev/null; then
        error "dockerd exited unexpectedly. Attempting restart with vfs driver ..."
        cat > /etc/docker/daemon.json <<'EOF'
{
    "storage-driver": "vfs",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "iptables": true
}
EOF
        nohup dockerd \
            --host=unix:///var/run/docker.sock \
            --host=tcp://0.0.0.0:2375 \
            > /var/log/dockerd.log 2>&1 &
        DOCKERD_PID=$!
    fi

    sleep 1
    WAITED=$((WAITED + 1))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        error "Docker daemon did not start within ${MAX_WAIT}s"
        error "Last 30 lines of /var/log/dockerd.log:"
        tail -30 /var/log/dockerd.log || true
        error "Continuing anyway — Agent Zero will start but Docker commands may fail."
        break
    fi
done

if docker info > /dev/null 2>&1; then
    info "Docker daemon is ready"
    docker info --format '  Storage Driver: {{.Driver}}'
    docker info --format '  Cgroup Driver:  {{.CgroupDriver}}'
    docker info --format '  Kernel:         {{.KernelVersion}}'
else
    warn "Docker daemon is NOT responding — check /var/log/dockerd.log"
fi

info "Launching Agent Zero ..."

if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /exe/initialize.sh "local"
fi
