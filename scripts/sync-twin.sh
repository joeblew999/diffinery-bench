#!/usr/bin/env bash
# sync-twin.sh: make the Diffinery twin identical to this GitHub repo.
# Pushes every GitHub branch to the branch of the same name on Diffinery with force, so
# GitHub wins (the same rule as Diffinery's own mirror workflow). Branches deleted on GitHub
# are not deleted on Diffinery.
#
# Needs DIFFINERY_TOKEN (diffinery login; write scope is enough unless branches are protected).
# Settings: DIFFINERY_URL (default https://diffinery.ubuntusoftware.net),
#           DIFFINERY_REPO (default gedw99/diffinery-bench), GH_REPO (default joeblew999/diffinery-bench).
set -euo pipefail

: "${DIFFINERY_TOKEN:?set DIFFINERY_TOKEN (diffinery login)}"
DURL="${DIFFINERY_URL:-https://diffinery.ubuntusoftware.net}"
DREPO="${DIFFINERY_REPO:-gedw99/diffinery-bench}"
GREPO="${GH_REPO:-joeblew999/diffinery-bench}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Fetching every branch from github.com/$GREPO"
git clone -q --mirror "https://github.com/$GREPO.git" "$work/repo.git"

echo "Pushing them to $DURL/$DREPO (GitHub wins)"
git -C "$work/repo.git" -c http.extraHeader="Authorization: Bearer $DIFFINERY_TOKEN" \
  push --force "$DURL/$DREPO.git" 'refs/heads/*:refs/heads/*'

gh_head="$(git -C "$work/repo.git" rev-parse refs/heads/main)"
d_head="$(git -c http.extraHeader="Authorization: Bearer $DIFFINERY_TOKEN" ls-remote "$DURL/$DREPO.git" refs/heads/main | cut -f1)"
if [ "$gh_head" = "$d_head" ]; then
  echo "In sync: main is $gh_head on both"
else
  echo "NOT in sync: GitHub main $gh_head, Diffinery main $d_head" >&2
  exit 1
fi
