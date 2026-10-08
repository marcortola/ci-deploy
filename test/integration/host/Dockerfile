# A disposable deploy target: Docker-in-Docker with sshd. Kamal reaches it over SSH like a server.
FROM docker:29-dind
RUN apk add --no-cache openssh-server socat \
    && ssh-keygen -A \
    && sed -i 's/^root:!/root:*/' /etc/shadow \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' >> /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/it-entrypoint
ENV DOCKER_TLS_CERTDIR=""
ENTRYPOINT ["it-entrypoint"]
