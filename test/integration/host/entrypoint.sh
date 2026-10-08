#!/bin/sh
# Starts sshd, forwards the host-side registry to 127.0.0.1:55000 inside this "server" (so the
# registry address is the same everywhere, and loopback registries are insecure by default), then
# hands over to the Docker-in-Docker entrypoint.
set -eu
printf '%s\n' "${AUTHORIZED_KEY:?}" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
/usr/sbin/sshd
socat TCP-LISTEN:55000,fork,reuseaddr,bind=127.0.0.1 "TCP:${REGISTRY_UPSTREAM:?}" &
exec dockerd-entrypoint.sh dockerd --host=unix:///var/run/docker.sock
