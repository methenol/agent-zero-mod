FROM agent0ai/agent-zero-base:latest

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        iptables \
        supervisor \
        kmod \
        procps \
        e2fsprogs \
        xfsprogs \
        pigz \
    && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mkdir -p /var/lib/docker

ARG BRANCH=local
ENV BRANCH=$BRANCH

COPY ./docker/run/fs/ /

COPY ./ /git/agent-zero

RUN bash /ins/pre_install.sh $BRANCH

RUN bash /ins/install_A0.sh $BRANCH

RUN bash /ins/install_additional.sh $BRANCH

ARG CACHE_DATE=none
RUN echo "cache buster $CACHE_DATE" && bash /ins/install_A02.sh $BRANCH

RUN bash /ins/post_install.sh $BRANCH

COPY entrypoint-dind.sh /entrypoint-dind.sh
RUN chmod +x /entrypoint-dind.sh \
             /exe/initialize.sh \
             /exe/run_A0.sh \
             /exe/run_searxng.sh \
             /exe/run_tunnel_api.sh \
             /exe/trigger_self_update.sh

EXPOSE 22 80 9000-9009

ENTRYPOINT ["/entrypoint-dind.sh"]
CMD ["/exe/initialize.sh", "local"]
