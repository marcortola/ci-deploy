#!/usr/bin/env bash
# Merges a Dependabot security fix that stays inside the caret range of the current version, and
# optionally dispatches the deploy workflow on the default branch. Anything else is held for
# review with a notice, never failed.
#
# Env in:
#   DEPS              dependabot/fetch-metadata updated-dependencies-json
#   DEPENDENCY_GROUP  dependabot/fetch-metadata dependency-group
#   ECOSYSTEM         dependabot/fetch-metadata package-ecosystem
#   GH_REPO, PR_URL, HEAD_SHA, DEFAULT_BRANCH, GH_TOKEN
#   DEPLOY_WORKFLOW   workflow file dispatched after the merge; empty dispatches nothing
set -euo pipefail

if [ -n "${DEPENDENCY_GROUP:-}" ]; then
    echo "::notice::Held for review: grouped update."
    exit 0
fi
if [ "${ECOSYSTEM:-}" = "github_actions" ]; then
    echo "::notice::Held for review: GitHub Actions update."
    exit 0
fi

jq -e '
  def semver: sub("^[^0-9]*"; "") | split(".")[0:3] | map(tonumber? // null);
  length > 0 and all(.[];
    (.prevVersion // "" | semver) as $p | (.newVersion // "" | semver) as $n
    | ($p + $n | length == 6 and all(. != null))
    and (if $p[0] > 0 then $n[0] == $p[0]
         elif $p[1] > 0 then $n[0] == 0 and $n[1] == $p[1]
         else false end))' <<<"${DEPS:-[]}" >/dev/null \
  || { echo "::notice::Held for review: outside the caret range of the current version."; exit 0; }

alerts=$(gh api -X GET "repos/$GH_REPO/dependabot/alerts" -f state=open \
  -f package="$(jq -r 'map(.dependencyName) | unique | join(",")' <<<"$DEPS")" --jq length)
[ "$alerts" -gt 0 ] || { echo "::notice::Held for review: no open Dependabot alert."; exit 0; }

gh pr merge "$PR_URL" --squash --match-head-commit "$HEAD_SHA"
if [ -n "${DEPLOY_WORKFLOW:-}" ]; then
    gh workflow run "$DEPLOY_WORKFLOW" --ref "$DEFAULT_BRANCH"
fi
