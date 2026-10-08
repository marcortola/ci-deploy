#!/bin/sh
#
# Shared helpers for Kamal deploy hooks. SOURCED, not executed:
#
#   . "${CI_DEPLOY_HOOKS_LIB:?run through the ci-deploy setup action or launcher}/hooks.sh"
#
# The setup action and the local launcher export CI_DEPLOY_HOOKS_LIB, put this repository's bin/
# first on PATH and export BUNDLE_GEMFILE, so `kamal` here is the locked version.
#
# Which commands a hook runs, in which phase and order, and what a failure means stay in the
# consumer's hooks. These helpers only run one command on the primary host, in a container chosen
# explicitly:
#
#   new-image       a disposable container from the image being deployed (KAMAL_VERSION). Use it
#                   before boot - the live container still runs the old code - and for anything
#                   that must not share the live container's state.
#   live-container  the running container (--reuse). After boot it runs the new code; before boot
#                   it runs the old one.
#
# Symfony note: the live web container has no USER directive, so `bin/console` run there executes
# as root; booting the prod kernel as root leaves var/cache/prod owned by root, after which php-fpm
# can no longer write the lazily dumped route matcher and every request fails with "Permission
# denied". Symfony consumers use new-image for console commands.
#
# Settings (environment):
#   CI_DEPLOY_HOOK_CONFIG  Kamal configuration (default: CI_DEPLOY_CONFIG, else ./etc/kamal/deploy.yml)
#   CI_DEPLOY_HOOK_ROLES   role filter (default: web; set it empty to run without --roles)
# KAMAL_DESTINATION is passed as -d only when set; KAMAL_VERSION is required.

# ci_deploy_exec MODE COMMAND -- run COMMAND as given.
ci_deploy_exec() {
    _ci_deploy_mode=${1:-}
    _ci_deploy_command=${2:-}
    case "$_ci_deploy_mode" in
        new-image) set -- ;;
        live-container) set -- --reuse ;;
        *)
            echo "ci-deploy hooks: choose the container explicitly: new-image or live-container (got '${_ci_deploy_mode}')" >&2
            return 64
            ;;
    esac
    if [ -z "$_ci_deploy_command" ]; then
        echo "ci-deploy hooks: no command given" >&2
        return 64
    fi
    if [ -z "${KAMAL_VERSION:-}" ]; then
        echo "ci-deploy hooks: KAMAL_VERSION is required" >&2
        return 64
    fi

    _ci_deploy_roles=${CI_DEPLOY_HOOK_ROLES-web}
    if [ -n "$_ci_deploy_roles" ]; then
        set -- "$@" "--roles=$_ci_deploy_roles"
    fi
    set -- "$@" -c "${CI_DEPLOY_HOOK_CONFIG:-${CI_DEPLOY_CONFIG:-./etc/kamal/deploy.yml}}"
    if [ -n "${KAMAL_DESTINATION:-}" ]; then
        set -- "$@" -d "$KAMAL_DESTINATION"
    fi

    echo "[PRIMARY] $_ci_deploy_command"
    kamal app exec --primary "$@" --version "$KAMAL_VERSION" "$_ci_deploy_command"
}

# ci_deploy_symfony MODE CONSOLE_ARGS -- run `bin/console CONSOLE_ARGS`.
ci_deploy_symfony() {
    ci_deploy_exec "${1:-}" "bin/console ${2:-}"
}

# ci_deploy_node MODE COMMAND -- run a Node command line (npm run ..., node dist/...).
ci_deploy_node() {
    ci_deploy_exec "${1:-}" "${2:-}"
}

# ci_deploy_python MODE ARGS -- run `python ARGS`.
ci_deploy_python() {
    ci_deploy_exec "${1:-}" "python ${2:-}"
}

# ci_deploy_retry ATTEMPTS SLEEP COMMAND [ARGS...] -- retry a command a fixed number of times.
ci_deploy_retry() {
    _ci_deploy_attempts=$1
    _ci_deploy_sleep=$2
    shift 2
    _ci_deploy_n=1
    while :; do
        "$@" && return 0
        [ "$_ci_deploy_n" -ge "$_ci_deploy_attempts" ] && return 1
        echo "  attempt $_ci_deploy_n/$_ci_deploy_attempts failed; retrying in ${_ci_deploy_sleep}s..."
        sleep "$_ci_deploy_sleep"
        _ci_deploy_n=$((_ci_deploy_n + 1))
    done
}

# ci_deploy_is_rollback -- true while Kamal runs the hooks for `kamal rollback`.
ci_deploy_is_rollback() {
    [ "${KAMAL_COMMAND:-}" = "rollback" ]
}
