#!/bin/sh
# Checks one remote-consumption scenario against the deploy action's outputs and the calls the
# fake Kamal recorded. Env in: SCENARIO, OUTCOME (the deploy step's outcome), VERSION,
# PREVIOUS_VERSION, DEPLOY_RESULT, ROLLBACK_RESULT, EXPECTED_VERSION, FAKE_KAMAL_LOG.
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

called() {
    # The recorded call whose lines, joined by spaces, equal $1.
    awk -v want="$1" '
        /^--- call$/ { if (n) print line; line = ""; n = 1; next }
        { line = line == "" ? $0 : line " " $0 }
        END { if (n) print line }
    ' "$FAKE_KAMAL_LOG" | grep -Fxq -- "$1"
}

count() {
    grep -c -- "^$1\$" "$FAKE_KAMAL_LOG" || true
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
        ;;
    deploy-failure)
        check "step outcome" "$OUTCOME" failure
        check "deploy result" "$DEPLOY_RESULT" deploy-failed
        check "rollback result" "$ROLLBACK_RESULT" succeeded
        check "previous version" "$PREVIOUS_VERSION" v0-serving
        check "rolled back to the previous version" "$(called "rollback v0-serving -c etc/kamal/deploy.yml -d staging" && echo yes)" yes
        ;;
    build-failure)
        check "step outcome" "$OUTCOME" failure
        check "deploy result" "$DEPLOY_RESULT" build-failed
        check "rollback result" "$ROLLBACK_RESULT" not-attempted
        check "previous version" "$PREVIOUS_VERSION" ""
        check "no deploy after a failed build" "$(count deploy)" 0
        check "no rollback after a failed build" "$(count rollback)" 0
        ;;
    *)
        echo "::error::unknown scenario $SCENARIO"
        exit 64
        ;;
esac

[ "$failures" -eq 0 ] || exit 1
