#!/usr/bin/env bash
# Formatting, init and validate for every Terraform root module, without state access.
#
# Env in:
#   TF_ROOT            directory searched for root modules and checked for formatting
#   TF_DIRECTORIES     explicit root modules, one per line; empty discovers every directory under
#                      TF_ROOT holding a backend.tf
#   TF_FMT             'true' runs terraform fmt -check -diff -recursive on TF_ROOT
#   TF_INIT_ARGS       init arguments, separated by spaces (e.g. -backend=false -lockfile=readonly)
#   TF_INIT_ATTEMPTS   init attempts per module (provider downloads flap; validate is never retried)
#   TF_RETRY_DELAY     seconds before the second attempt; each later wait adds as much again
#
# Every module is checked even after one fails, so one broken module does not hide the others.
set -euo pipefail

root=${TF_ROOT:-.}
attempts=${TF_INIT_ATTEMPTS:-3}
delay=${TF_RETRY_DELAY:-20}
read -r -a init_args <<< "${TF_INIT_ARGS:--backend=false -input=false}"

case "$attempts" in ''|*[!0-9]*|0) echo "::error::TF_INIT_ATTEMPTS must be a positive number" >&2; exit 64 ;; esac
[ -d "$root" ] || { echo "::error::Terraform root '$root' does not exist" >&2; exit 1; }

failed=()
if [ "${TF_FMT:-true}" = "true" ]; then
    if ! terraform fmt -check -diff -recursive "$root"; then
        failed+=("formatting under $root")
    fi
fi

modules=()
if [ -n "${TF_DIRECTORIES:-}" ]; then
    while IFS= read -r dir; do
        [ -n "$dir" ] && modules+=("$dir")
    done <<< "$TF_DIRECTORIES"
else
    while IFS= read -r backend; do
        modules+=("$(dirname "$backend")")
    done < <(find "$root" -name .terraform -prune -o -type f -name backend.tf -print | sort)
fi
if [ "${#modules[@]}" -eq 0 ]; then
    echo "::error::No Terraform root module found under $root (none holds a backend.tf)" >&2
    exit 1
fi

for module in "${modules[@]}"; do
    echo "::group::$module"
    initialized=""
    for attempt in $(seq 1 "$attempts"); do
        if terraform -chdir="$module" init "${init_args[@]}" -no-color; then
            initialized=yes
            break
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            sleep "$((delay * attempt))"
        fi
    done
    if [ -z "$initialized" ]; then
        echo "::error::terraform init failed in $module after $attempts attempts"
        failed+=("$module (init)")
    elif terraform -chdir="$module" validate -no-color; then
        echo "$module: valid"
    else
        failed+=("$module (validate)")
    fi
    echo "::endgroup::"
done

if [ "${#failed[@]}" -gt 0 ]; then
    printf '::error::Terraform checks failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
