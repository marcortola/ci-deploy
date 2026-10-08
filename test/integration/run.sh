#!/usr/bin/env bash
# Integration suite: real Kamal against disposable servers.
#
#   nix develop --command test/integration/run.sh
#
# Stands up a registry and two Docker-in-Docker "servers" reachable over SSH (127.0.0.2 and
# 127.0.0.3, port 2222), then:
#
#   1. deploys app A (both servers) and app B (first server only) with Kamal 2.2.2, which boots
#      kamal-proxy v0.8.1, so the first server is shared by two apps behind one old proxy;
#   2. shows a Kamal 2.10 deploy refusing the old proxy, and the proxy reboot refusing to run without
#      an explicit target;
#   3. reboots the proxy to v0.9.0 through the operations catalog, checking both apps before and after;
#   4. deploys through bin/ci-deploy: a prebuilt image, a Kamal build, a failed build (no host
#      touched), a failed health check rolled back, with the hooks reaching the same kamal;
#   5. runs commands, boots and reboots a persistent accessory, and deploys through the local launcher.
#
# Everything it starts is named cid-it-* and removed on exit; CI_DEPLOY_IT_KEEP=1 keeps it running.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IT="$ROOT/test/integration"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cid-it.XXXXXX")
PREFIX=cid-it
NETWORK=$PREFIX-net
HOSTS=(127.0.0.2 127.0.0.3)
REGISTRY=127.0.0.1:55000
PASS=0

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] && [ -f "$WORK/last.log" ]; then
        echo "--- last step output (tail) ---" >&2
        tail -n 80 "$WORK/last.log" >&2
    fi
    if [ "${CI_DEPLOY_IT_KEEP:-}" = 1 ]; then
        echo "Keeping the environment (CI_DEPLOY_IT_KEEP=1). Remove it with:"
        echo "  docker rm -f $PREFIX-host1 $PREFIX-host2 $PREFIX-registry; docker network rm $NETWORK; rm -rf $WORK"
    else
        docker rm -f -v "$PREFIX-host1" "$PREFIX-host2" "$PREFIX-registry" >/dev/null 2>&1 || true
        docker network rm "$NETWORK" >/dev/null 2>&1 || true
        docker image rm "$PREFIX-host" "$REGISTRY/it/app-a:v1" "$REGISTRY/it/app-b:v1" "$REGISTRY/it/app-a:v2" "$REGISTRY/it/app-a:v3-broken" "$REGISTRY/it/app-b:latest" "$REGISTRY/it/app-b:v2-built" "$REGISTRY/it/app-b:v3-unbuilt" >/dev/null 2>&1 || true
        rm -rf "$WORK"
    fi
    if [ "$status" -eq 0 ]; then echo "integration: $PASS checks passed"; else echo "integration: FAILED after $PASS checks" >&2; fi
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }
expect_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; ok "$3"; }
expect_match() { printf '%s' "$1" | grep -qE -- "$2" || fail "$3: '$2' not found in: $1"; ok "$3"; }

# Rebinds HOME so Kamal's known hosts, Docker logins and Bundler state stay in the work directory.
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/home/.cache"
mkdir -p "$HOME"
export IT_SSH_KEY="$WORK/id_ed25519" IT_REGISTRY_PASSWORD=it-password
ssh-keygen -q -t ed25519 -N '' -f "$IT_SSH_KEY"

host_index() { case "$1" in 127.0.0.2) echo 1 ;; 127.0.0.3) echo 2 ;; esac; }
# What app $2 answers on server $1, through that server's kamal-proxy.
answer() { docker exec "$PREFIX-host$(host_index "$1")" wget -qO- -T 5 --header "Host: $2.example.test" http://127.0.0.1/ 2>/dev/null || echo unreachable; }
proxy_version() { docker exec "$PREFIX-host$(host_index "$1")" docker inspect kamal-proxy --format '{{.Config.Image}}' 2>/dev/null | sed 's/.*://'; }

step "Start the registry and two servers"
docker network create "$NETWORK" >/dev/null
docker run -d --name "$PREFIX-registry" --network "$NETWORK" -p "$REGISTRY:5000" registry:2 >/dev/null
docker build -q -t "$PREFIX-host" "$IT/host" >/dev/null
for i in 1 2; do
    docker run -d --privileged --name "$PREFIX-host$i" --network "$NETWORK" -p "${HOSTS[$((i - 1))]}:2222:22" \
        -e AUTHORIZED_KEY="$(cat "$IT_SSH_KEY.pub")" -e REGISTRY_UPSTREAM="$PREFIX-registry:5000" "$PREFIX-host" >/dev/null
done
for host in "${HOSTS[@]}"; do
    for _ in $(seq 1 60); do
        ssh -q -p 2222 -i "$IT_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "root@$host" docker info >/dev/null 2>&1 && break
        sleep 1
    done
    ssh -q -p 2222 -i "$IT_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@$host" docker info >/dev/null || fail "server $host did not come up"
done
ok "servers reachable over SSH with Docker running"

step "Publish the prebuilt images"
publish() { docker build -q --label "service=it-$1" --build-arg "HEALTH=${3:-ok}" -t "$REGISTRY/it/$1:$2" "$IT/app" >/dev/null && docker push -q "$REGISTRY/it/$1:$2" >/dev/null; }
publish app-a v1; publish app-b v1; publish app-a v2; publish app-a v3-broken fail
ok "images published"

# Each app is its own git checkout, as a consumer's would be.
for app in app-a app-b; do
    cp -R "$IT/apps/$app" "$WORK/$app"
    cp "$IT/app/Dockerfile" "$WORK/$app/Dockerfile"
    mkdir -p "$WORK/$app/.kamal"
    cp "$WORK/$app/etc/kamal/secrets-common" "$WORK/$app/.kamal/secrets-common"
    git -C "$WORK/$app" init -q -b main
    git -C "$WORK/$app" -c user.name=it -c user.email=it@example.com add -A
    git -C "$WORK/$app" -c user.name=it -c user.email=it@example.com commit -q -m "$app"
done
export APP_A_HOSTS="127.0.0.2,127.0.0.3" APP_B_HOSTS="127.0.0.2"

step "Stand up the old state with Kamal 2.2.2 (kamal-proxy v0.8.1, two apps on the first server)"
legacy() {
    (cd "$WORK/$1" && shift && IT_LEGACY=1 BUNDLE_GEMFILE="$IT/legacy/Gemfile" BUNDLE_PATH="$WORK/legacy-bundle" \
        bundle exec kamal "$@" -c etc/kamal/deploy.yml)
}
BUNDLE_GEMFILE="$IT/legacy/Gemfile" BUNDLE_PATH="$WORK/legacy-bundle" bundle install --quiet
legacy app-a deploy --skip-push --version v1 -H
legacy app-b deploy --skip-push --version v1 -H
for host in "${HOSTS[@]}"; do expect_eq "$(proxy_version "$host")" v0.8.1 "kamal-proxy on $host is v0.8.1"; done
expect_eq "$(answer 127.0.0.2 a)" "app-a v1" "app A answers v1 on the shared server"
expect_eq "$(answer 127.0.0.2 b)" "app-b v1" "app B answers v1 on the shared server"
expect_eq "$(answer 127.0.0.3 a)" "app-a v1" "app A answers v1 on the second server"

# Runs a bin/ci-deploy step for an app the way the actions do: inputs as CI_DEPLOY_IN_*, outputs
# in a fresh GITHUB_OUTPUT, read back with `out NAME`.
out() { sed -n "/^$1<<CI_DEPLOY_EOF_/{n;p;}" "$WORK/github-output" | tail -n 1; }
ci() {
    local app=$1 command=$2
    shift 2
    local output="$WORK/github-output"
    : > "$output"
    local status=0
    env "$@" GITHUB_OUTPUT="$output" GITHUB_REF_NAME=main GITHUB_SHA=0000000000000000000000000000000000000000 \
        CI_DEPLOY_HOME="$ROOT" CI_DEPLOY_ACTION_HOME="$ROOT" CI_DEPLOY_HOOKS_LIB="$ROOT/lib/sh" \
        CI_DEPLOY_PROJECT_DIR="$WORK/$app" CI_DEPLOY_CONFIG=etc/kamal/deploy.yml \
        BUNDLE_GEMFILE="$ROOT/Gemfile" RUBYLIB="$ROOT/lib" PATH="$ROOT/bin:$PATH" IT_HOOK_LOG="$WORK/hook.log" \
        timeout "${CI_DEPLOY_IT_STEP_TIMEOUT:-300}" ruby "$ROOT/bin/ci-deploy" "$command" > "$WORK/last.log" 2>&1 || status=$?
    return "$status"
}

step "Pre-check: Kamal 2.10 refuses to deploy behind the old proxy and changes nothing"
status=0; ci app-a deploy CI_DEPLOY_IN_BUILD_MODE=prebuilt CI_DEPLOY_IN_VERSION=v2 || status=$?
[ "$status" -ne 0 ] || fail "a deploy behind kamal-proxy v0.8.1 succeeded"
expect_match "$(cat "$WORK/last.log")" "too old" "Kamal 2.10 names the old proxy"
expect_eq "$(answer 127.0.0.2 a)" "app-a v1" "app A still serves v1"

step "Proxy details before the upgrade, for every app on the shared server"
ci app-a operation CI_DEPLOY_IN_OPERATION=proxy-details CI_DEPLOY_IN_HOSTS=127.0.0.2 || fail "proxy-details failed"
expect_match "$(cat "$WORK/last.log")" "kamal-proxy:v0.8.1" "proxy-details reports v0.8.1"
expect_eq "$(answer 127.0.0.2 b)" "app-b v1" "app B checked before the reboot"

step "A proxy reboot without an explicit target is refused"
status=0; ci app-a operation CI_DEPLOY_IN_OPERATION=proxy-reboot || status=$?
[ "$status" -ne 0 ] || fail "proxy-reboot ran without a target"
expect_match "$(cat "$WORK/last.log")" "needs an explicit target" "proxy-reboot names the missing target"
expect_eq "$(proxy_version 127.0.0.2)" v0.8.1 "the proxy is untouched"

step "Reboot the proxy on every app A server to v0.9.0"
ci app-a operation CI_DEPLOY_IN_OPERATION=proxy-reboot CI_DEPLOY_IN_HOSTS=all || { cat "$WORK/last.log"; fail "proxy-reboot failed"; }
for host in "${HOSTS[@]}"; do expect_eq "$(proxy_version "$host")" v0.9.0 "kamal-proxy on $host is v0.9.0"; done
expect_eq "$(answer 127.0.0.2 a)" "app-a v1" "app A answers after the reboot on the shared server"
expect_eq "$(answer 127.0.0.2 b)" "app-b v1" "app B answers after the reboot on the shared server"
expect_eq "$(answer 127.0.0.3 a)" "app-a v1" "app A answers after the reboot on the second server"

step "Deploy a prebuilt image with hooks"
: > "$WORK/hook.log"
ci app-a deploy CI_DEPLOY_IN_BUILD_MODE=prebuilt CI_DEPLOY_IN_VERSION=v2 || { cat "$WORK/last.log"; fail "prebuilt deploy failed"; }
expect_eq "$(out deploy-result)" success "deploy-result"
expect_eq "$(out previous-version)" v1 "previous-version"
expect_eq "$(answer 127.0.0.2 a)" "app-a v2" "app A answers v2 on the shared server"
expect_eq "$(answer 127.0.0.3 a)" "app-a v2" "app A answers v2 on the second server"
expect_eq "$(answer 127.0.0.2 b)" "app-b v1" "app B is untouched"
hook=$(cat "$WORK/hook.log")
expect_match "$hook" "^kamal=$ROOT/(bin|vendor/bundle/ruby/[^/]+/bin)/kamal$" "the hook reaches this revision's kamal"
expect_match "$hook" "^kamal_version=2\.10\.0$" "the hook runs the locked Kamal"
expect_match "$hook" "bundle=$ROOT/Gemfile" "the hook runs with this revision's bundle"
expect_match "$hook" "version=v2" "the hook sees the incoming version"
expect_match "$hook" "^ok$" "the hook ran a command from the incoming image"

step "A prebuilt image that is not published is refused before any host is touched"
status=0; ci app-a deploy CI_DEPLOY_IN_BUILD_MODE=prebuilt CI_DEPLOY_IN_VERSION=v9-missing || status=$?
[ "$status" -ne 0 ] || fail "deploying a missing image succeeded"
expect_eq "$(out deploy-result)" image-missing "deploy-result"
expect_eq "$(answer 127.0.0.2 a)" "app-a v2" "app A still serves v2"

step "Build with Kamal and deploy the same version"
ci app-b deploy CI_DEPLOY_IN_VERSION=v2-built || { cat "$WORK/last.log"; fail "built deploy failed"; }
expect_eq "$(out version)" v2-built "version"
expect_match "$(cat "$WORK/last.log")" "kamal build push --version=v2-built" "built with the explicit version"
expect_match "$(cat "$WORK/last.log")" "kamal deploy --skip-push --version=v2-built" "deployed the same version"
expect_eq "$(answer 127.0.0.2 b)" "app-b v2-built" "app B answers the built version"

step "A failed build touches no host"
before=$(docker exec "$PREFIX-host1" docker ps -a --format '{{.Names}}' | sort | tr '\n' ' ')
status=0; ci app-b deploy CI_DEPLOY_IN_VERSION=v3-unbuilt CI_DEPLOY_IN_ROLLBACK=auto IT_FAIL_BUILD=1 || status=$?
[ "$status" -ne 0 ] || fail "a failed build deployed"
expect_eq "$(out deploy-result)" build-failed "deploy-result"
expect_eq "$(out rollback-result)" not-attempted "rollback-result"
expect_eq "$(docker exec "$PREFIX-host1" docker ps -a --format '{{.Names}}' | sort | tr '\n' ' ')" "$before" "no container changed on the server"
expect_eq "$(answer 127.0.0.2 b)" "app-b v2-built" "app B still serves the built version"

step "A failed health check is rolled back and verified on every server"
status=0; ci app-a deploy CI_DEPLOY_IN_BUILD_MODE=prebuilt CI_DEPLOY_IN_VERSION=v3-broken CI_DEPLOY_IN_ROLLBACK=auto || status=$?
[ "$status" -ne 0 ] || fail "the broken version deployed"
expect_eq "$(out deploy-result)" deploy-failed "deploy-result"
expect_eq "$(out rollback-result)" succeeded "rollback-result"
expect_eq "$(answer 127.0.0.2 a)" "app-a v2" "app A serves v2 again on the shared server"
expect_eq "$(answer 127.0.0.3 a)" "app-a v2" "app A serves v2 again on the second server"
expect_eq "$(answer 127.0.0.2 b)" "app-b v2-built" "app B is untouched by app A's rollback"

step "Commands"
ci app-a operation CI_DEPLOY_IN_OPERATION=host-exec CI_DEPLOY_IN_COMMAND='cat /etc/hostname; echo done' || fail "host-exec failed"
expect_match "$(cat "$WORK/last.log")" "done" "host-exec runs on the primary server"
ci app-a operation CI_DEPLOY_IN_OPERATION=app-exec CI_DEPLOY_IN_CONTAINER_MODE=live-container CI_DEPLOY_IN_COMMAND='cat /www/index.html' \
    || fail "app-exec failed"
expect_match "$(cat "$WORK/last.log")" "app-a v2" "app-exec reaches the live container"
# The command reaches the container as one argument: the container's shell runs it (uid 0 there),
# never the runner's.
ci app-a operation CI_DEPLOY_IN_OPERATION=kamal CI_DEPLOY_IN_ARGS="app exec --reuse \"echo 'semi;colon' \$(id -u)\"" || fail "kamal free arguments failed"
expect_match "$(cat "$WORK/last.log")" "^semi;colon 0$" "free arguments reach the container unexpanded by the runner"

step "A persistent accessory survives a reboot"
ci app-a operation CI_DEPLOY_IN_OPERATION=accessory-boot CI_DEPLOY_IN_TARGET=store || { cat "$WORK/last.log"; fail "accessory boot failed"; }
marker=$(docker exec "$PREFIX-host1" cat /var/lib/it-store/marker)
[ -n "$marker" ] || fail "the accessory wrote no marker"
ci app-a operation CI_DEPLOY_IN_OPERATION=accessory-reboot CI_DEPLOY_IN_TARGET=store || fail "accessory reboot failed"
expect_eq "$(docker exec "$PREFIX-host1" cat /var/lib/it-store/marker)" "$marker" "the accessory's data survives the reboot"
ci app-a operation CI_DEPLOY_IN_OPERATION=accessory-details CI_DEPLOY_IN_TARGET=store || fail "accessory details failed"
expect_match "$(cat "$WORK/last.log")" "Up " "the accessory runs after the reboot"

step "Deploy through the local launcher"
mirror="$WORK/ci-deploy-mirror"
mkdir -p "$mirror"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "$mirror")
git -C "$mirror" init -q
git -C "$mirror" -c user.name=it -c user.email=it@example.com add -A
git -C "$mirror" -c user.name=it -c user.email=it@example.com commit -q -m mirror
sha=$(git -C "$mirror" rev-parse HEAD)
mkdir -p "$WORK/app-a/.github/workflows" "$WORK/app-a/bin"
printf 'jobs:\n  deploy:\n    steps:\n      - uses: marcortola/ci-deploy/setup@%s # test\n      - uses: marcortola/ci-deploy/deploy@%s # test\n' "$sha" "$sha" \
    > "$WORK/app-a/.github/workflows/deploy.yml"
cp "$ROOT/launcher/ci-deploy-local" "$WORK/app-a/bin/ci-deploy-local"
printf 'APP_A_HOSTS=127.0.0.2,127.0.0.3\nIT_REGISTRY_PASSWORD=%s\n' "$IT_REGISTRY_PASSWORD" > "$WORK/local.env"
: > "$WORK/hook.log"
(cd "$WORK/app-a" && env -u BUNDLE_GEMFILE -u RUBYLIB -u CI_DEPLOY_HOOKS_LIB CI_DEPLOY_REPOSITORY_URL="$mirror" IT_HOOK_LOG="$WORK/hook.log" \
    sh bin/ci-deploy-local --env-file "$WORK/local.env" --branch-policy off -- deploy --skip-push --version v1) > "$WORK/last.log" 2>&1 \
    || { tail -40 "$WORK/last.log"; fail "launcher deploy failed"; }
cache="$HOME/.cache/ci-deploy/$sha"
expect_eq "$(answer 127.0.0.2 a)" "app-a v1" "the launcher deployed v1"
expect_match "$(cat "$WORK/hook.log")" "^kamal=$cache/(bin|vendor/bundle/ruby/[^/]+/bin)/kamal$" "the launcher's hook reaches the cached revision's kamal"
expect_match "$(cat "$WORK/hook.log")" "^kamal_version=2\.10\.0$" "the launcher's hook runs the locked Kamal"
expect_match "$(cat "$WORK/hook.log")" "bundle=$cache/Gemfile" "the launcher's hook runs with the cached bundle"
status=0
(cd "$WORK/app-a" && CI_DEPLOY_REPOSITORY_URL="$mirror" sh bin/ci-deploy-local --env-file "$WORK/local.env" -- deploy --skip-push --version v9-missing) \
    > "$WORK/last.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "the launcher deployed an unpublished image"
expect_match "$(cat "$WORK/last.log")" "is not published in the registry" "the launcher refuses an unpublished image"
