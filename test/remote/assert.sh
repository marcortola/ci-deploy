#!/bin/sh
# Checks one remote-consumption scenario against the deploy action's outputs and the calls the
# fake Kamal and the fake ci-deploy-push-env recorded. Env in: SCENARIO, OUTCOME (the deploy
# step's outcome), VERSION, PREVIOUS_VERSION, DEPLOY_RESULT, ROLLBACK_RESULT, EXPECTED_VERSION,
# FAKE_KAMAL_LOG.
set -eu
failures=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok: $1"
    else
        echo "::error::$1: expected '$3', got '$2'"
        failures=$((failures + 1))
    fi
}

calls() {
    # One line per recorded call, its lines joined by spaces, in call order.
    awk '
        /^--- call$/ { if (n) print line; line = ""; n = 1; next }
        { line = line == "" ? $0 : line " " $0 }
        END { if (n) print line }
    ' "$FAKE_KAMAL_LOG"
}

called() {
    # The recorded call whose lines, joined by spaces, equal $1.
    calls | grep -Fxq -- "$1"
}

position() {
    # The order of the first recorded call equal to $1; empty when there is none.
    calls | grep -Fxn -- "$1" | head -n 1 | cut -d: -f1
}

count() {
    grep -c -- "^$1\$" "$FAKE_KAMAL_LOG" || true
}

# The fake ci-deploy-push-env records itself in the same log: the env files are pushed with the
# deploy's configuration, destination and version, and the very next call is kamal deploy.
pushed_right_before_deploy() {
    push=$(position "ci-deploy-push-env -c etc/kamal/deploy.yml -d staging --version=$VERSION")
    deploy=$(position "deploy --skip-push --version=$VERSION -c etc/kamal/deploy.yml -d staging")
    [ -n "$push" ] && [ -n "$deploy" ] && [ "$((push + 1))" -eq "$deploy" ] && echo yes
}

check "version is the checked-out commit" "$VERSION" "$EXPECTED_VERSION"
check "build used that version" "$(called "build push --version=$VERSION -c etc/kamal/deploy.yml -d staging" && echo yes)" yes
check "cleanup ran once" "$(called "cleanup-marker" && count cleanup-marker)" 1

case "$SCENARIO" in
    success)
        check "step outcome" "$OUTCOME" success
        check "deploy result" "$DEPLOY_RESULT" success
        check "rollback result" "$ROLLBACK_RESULT" not-needed
        check "previous version" "$PREVIOUS_VERSION" v0-serving
        check "deploy used the same version" "$(called "deploy --skip-push --version=$VERSION -c etc/kamal/deploy.yml -d staging" && echo yes)" yes
        check "env pushed right before deploy" "$(pushed_right_before_deploy)" yes
        ;;
    deploy-failure)
        check "step outcome" "$OUTCOME" failure
        check "deploy result" "$DEPLOY_RESULT" deploy-failed
        check "rollback result" "$ROLLBACK_RESULT" succeeded
        check "previous version" "$PREVIOUS_VERSION" v0-serving
        check "env pushed right before deploy" "$(pushed_right_before_deploy)" yes
        check "rolled back to the previous version" "$(called "rollback v0-serving -c etc/kamal/deploy.yml -d staging" && echo yes)" yes
        ;;
    build-failure)
        check "step outcome" "$OUTCOME" failure
        check "deploy result" "$DEPLOY_RESULT" build-failed
        check "rollback result" "$ROLLBACK_RESULT" not-attempted
        check "previous version" "$PREVIOUS_VERSION" ""
        check "no env push after a failed build" "$(count ci-deploy-push-env)" 0
        check "no deploy after a failed build" "$(count deploy)" 0
        check "no rollback after a failed build" "$(count rollback)" 0
        ;;
    *)
        echo "::error::unknown scenario $SCENARIO"
        exit 64
        ;;
esac

[ "$failures" -eq 0 ] || exit 1
