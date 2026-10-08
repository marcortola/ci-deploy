#!/usr/bin/env bash
# Builds an image, runs smoke commands in it and optionally publishes it.
#
# Env in (lists are one item per line):
#   IMAGE_TAGS         tags; the first is the one smoke commands run
#   BUILD_CONTEXT      build context
#   BUILD_FILE         Dockerfile path; empty uses the context's Dockerfile
#   BUILD_TARGET       target stage; empty builds the last
#   BUILD_ARGS         NAME (value read from the environment) or NAME=value
#   BUILD_SECRETS      buildx secret specs, e.g. id=key,src=/path or id=key,env=VAR
#   BUILD_LABELS       labels, NAME=value
#   BUILD_CACHE        gha or none
#   SMOKE_COMMANDS     commands run in the image with `sh -c`, so the image's shell - never the
#                      runner's - interprets them
#   SMOKE_RUN_ARGS     docker run options for the smoke commands, separated by spaces
#   PUSH               'true' publishes every tag after the smoke commands pass
#   REGISTRY, REGISTRY_USER, REGISTRY_PASSWORD  login for PUSH; empty user skips the login
set -euo pipefail

# Non-empty lines of a list input, trimmed.
lines() {
    local line
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        if [ -n "$line" ]; then printf '%s\n' "$line"; fi
    done <<< "$1"
}

mapfile -t tags < <(lines "${IMAGE_TAGS:-}")
[ "${#tags[@]}" -gt 0 ] || { echo "::error::at least one image tag is required" >&2; exit 64; }
mapfile -t build_args < <(lines "${BUILD_ARGS:-}")
mapfile -t build_secrets < <(lines "${BUILD_SECRETS:-}")
mapfile -t build_labels < <(lines "${BUILD_LABELS:-}")
mapfile -t smoke_commands < <(lines "${SMOKE_COMMANDS:-}")
read -r -a run_args <<< "${SMOKE_RUN_ARGS:-}"

build=(docker buildx build --load --progress plain)
[ -n "${BUILD_FILE:-}" ] && build+=(--file "$BUILD_FILE")
[ -n "${BUILD_TARGET:-}" ] && build+=(--target "$BUILD_TARGET")
for tag in "${tags[@]}"; do build+=(--tag "$tag"); done
for arg in "${build_args[@]}"; do build+=(--build-arg "$arg"); done
for secret in "${build_secrets[@]}"; do build+=(--secret "$secret"); done
for label in "${build_labels[@]}"; do build+=(--label "$label"); done
case "${BUILD_CACHE:-none}" in
    gha) build+=(--cache-from type=gha --cache-to "type=gha,mode=max") ;;
    none) ;;
    *) echo "::error::cache must be gha or none" >&2; exit 64 ;;
esac
build+=("${BUILD_CONTEXT:-.}")

"${build[@]}"

for command in "${smoke_commands[@]}"; do
    echo "::group::smoke: $command"
    docker run --rm "${run_args[@]}" "${tags[0]}" sh -c "$command"
    echo "::endgroup::"
done

if [ "${PUSH:-false}" = "true" ]; then
    if [ -n "${REGISTRY_USER:-}" ]; then
        printf '%s' "${REGISTRY_PASSWORD:-}" | docker login "${REGISTRY:?REGISTRY is required to log in}" --username "$REGISTRY_USER" --password-stdin
    fi
    for tag in "${tags[@]}"; do docker push "$tag"; done
fi
