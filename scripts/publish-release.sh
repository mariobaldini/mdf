#!/usr/bin/env bash
# Publish only complete bundles, keeping retries and older builds predictable.
set -euo pipefail
cd "$(dirname -- "$0")/.."
: "${GH_REPO:?GH_REPO is required}"
if [[ ${1:-} == --promote ]]; then
    mdf_newest_release() {
        gh api "repos/$GH_REPO/releases?per_page=100" --paginate \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' | python3 -c '
import re, sys
versions = []
for tag in sys.stdin.read().splitlines():
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-([1-9]\d*))?", tag)
    if match:
        versions.append((tuple(int(part or 1) for part in match.groups()), tag))
if not versions:
    raise SystemExit("No published MDF release found")
print(max(versions)[1])
'
    }
    # Recheck after promotion so overlapping publishers converge on the newest
    # completed release without canceling another commit's publication job.
    while :; do
        mdf_tag=$(mdf_newest_release)
        gh release edit "$mdf_tag" --latest
        if [ "$(mdf_newest_release)" = "$mdf_tag" ]; then break; fi
    done
    exit 0
fi
: "${GITHUB_SHA:?GITHUB_SHA is required}"
mdf_tag=${1:?A release tag is required}
if [[ ! $mdf_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[1-9][0-9]*)?$ || ! $GITHUB_SHA =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' 'Invalid release tag or source commit.' >&2
    exit 1
fi
shopt -s nullglob
mdf_rpms=(build/*.rpm)
mdf_debs=(build/*.deb)
if (( ${#mdf_rpms[@]} != 1 || ${#mdf_debs[@]} != 1 )); then
    printf '%s\n' 'A release must contain exactly one RPM and one DEB.' >&2
    exit 1
fi
(cd build && sha256sum --check mdf.sha256)
for mdf_file in "${mdf_rpms[@]}" "${mdf_debs[@]}"; do
    mdf_checksum=$(cd build && sha256sum "${mdf_file#build/}")
    if ! grep -Fxq -- "$mdf_checksum" build/mdf.sha256; then
        printf 'Release manifest does not cover %s.\n' "$mdf_file" >&2
        exit 1
    fi
done
mdf_assets=("${mdf_rpms[@]}" "${mdf_debs[@]}")
mdf_draft=$(gh release view "$mdf_tag" --json isDraft --jq .isDraft 2>/dev/null || true)
if [[ $mdf_draft == false ]]; then
    printf 'Release %s is already published.\n' "$mdf_tag"
    exit 0
fi
if [[ $mdf_draft == true ]]; then
    gh release upload "$mdf_tag" --clobber "${mdf_assets[@]}"
else
    mdf_options=(--target "$GITHUB_SHA")
    if [[ ${GITHUB_REF:-} == "refs/tags/$mdf_tag" ]]; then mdf_options+=(--verify-tag); fi
    gh release create "$mdf_tag" "${mdf_options[@]}" --draft \
        --title "Markdown FAST ${mdf_tag#v}" --generate-notes "${mdf_assets[@]}"
fi
gh release edit "$mdf_tag" --draft=false --latest=false
