#!/bin/sh
# Called by the setup action: records where this revision's tooling lives and puts its bin/ first
# on PATH for the rest of the job. Env in: GITHUB_ACTION_PATH, GITHUB_WORKSPACE, GITHUB_ENV,
# GITHUB_PATH, GITHUB_OUTPUT, PROJECT_DIRECTORY, CONFIG.
set -eu

for value in "$PROJECT_DIRECTORY" "$CONFIG"; do
    case "$value" in
        *'
'*) echo "::error::project-directory and config must be single-line paths" >&2; exit 1 ;;
    esac
done

home=$(CDPATH='' cd -- "$GITHUB_ACTION_PATH/.." && pwd -P)
project=$(CDPATH='' cd -- "$GITHUB_WORKSPACE/$PROJECT_DIRECTORY" 2>/dev/null && pwd -P) \
    || { echo "::error::project-directory '$PROJECT_DIRECTORY' does not exist in the workspace" >&2; exit 1; }
[ -f "$project/$CONFIG" ] \
    || { echo "::error::Kamal configuration '$CONFIG' not found in $project" >&2; exit 1; }

{
    echo "CI_DEPLOY_HOME=$home"
    echo "CI_DEPLOY_HOOKS_LIB=$home/lib/sh"
    echo "CI_DEPLOY_PROJECT_DIR=$project"
    echo "CI_DEPLOY_CONFIG=$CONFIG"
    echo "BUNDLE_GEMFILE=$home/Gemfile"
    echo "RUBYLIB=$home/lib${RUBYLIB:+:$RUBYLIB}"
} >> "$GITHUB_ENV"
echo "$home/bin" >> "$GITHUB_PATH"
{
    echo "home=$home"
    echo "project-directory=$project"
} >> "$GITHUB_OUTPUT"
echo "ci-deploy at $home; Kamal runs in $project with $CONFIG"
