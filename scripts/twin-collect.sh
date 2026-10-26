#!/usr/bin/env bash
# twin-collect.sh: download the results of the latest `check` run on main from both twins and
# print a side-by-side comparison (markdown).
#
# Needs: gh signed in to github.com, DIFFINERY_TOKEN (diffinery login), jq, unzip, node.
# Results go to results/twin/{github,diffinery}/ (not committed).
set -euo pipefail

: "${DIFFINERY_TOKEN:?set DIFFINERY_TOKEN (diffinery login)}"
GREPO="${GH_REPO:-joeblew999/diffinery-bench}"
DURL="${DIFFINERY_URL:-https://diffinery.ubuntusoftware.net}"
DREPO="${DIFFINERY_REPO:-gedw99/diffinery-bench}"
DAPI="$DURL/api/v3/repos/$DREPO"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/results/twin"
rm -rf "$out" && mkdir -p "$out/github" "$out/diffinery"

dcurl() { curl -fsSL -H "authorization: Bearer $DIFFINERY_TOKEN" "$@"; }

# GitHub: latest completed `check` run on main, then its check-results artifact.
g_run=$(gh api "repos/$GREPO/actions/runs?branch=main&status=completed" --jq '[.workflow_runs[] | select(.name=="check")][0] | "\(.id) \(.head_sha) \(.conclusion)"')
read -r g_id g_sha g_concl <<<"$g_run"
g_art=$(gh api "repos/$GREPO/actions/runs/$g_id/artifacts" --jq '.artifacts[] | select(.name=="check-results") | .id')
gh api "repos/$GREPO/actions/artifacts/$g_art/zip" > "$out/github.zip"
unzip -o -q "$out/github.zip" -d "$out/github"

# Diffinery: the same.
d_run=$(dcurl "$DAPI/actions/runs?branch=main&status=completed" | jq -r '[.workflow_runs[] | select(.name=="check")][0] | "\(.id) \(.head_sha) \(.conclusion)"')
read -r d_id d_sha d_concl <<<"$d_run"
d_art=$(dcurl "$DAPI/actions/runs/$d_id/artifacts" | jq -r '.artifacts[] | select(.name=="check-results") | .id')
dcurl "$DAPI/actions/artifacts/$d_art/zip" -o "$out/diffinery.zip"
unzip -o -q "$out/diffinery.zip" -d "$out/diffinery"

echo "## Twin check: GitHub vs Diffinery"
echo
echo "| | GitHub | Diffinery |"
echo "|---|---|---|"
echo "| check run | \`$g_id\` ($g_concl) | \`$d_id\` ($d_concl) |"
echo "| commit | \`${g_sha:0:7}\` | \`${d_sha:0:7}\` |"
[ "$g_sha" = "$d_sha" ] || echo "| **warning** | twins ran different commits | run \`mise run twin:sync\` |"
echo
echo "### gh commands, each platform against itself"
echo
echo "| command | GitHub | Diffinery |"
echo "|---|---|---|"
# Join the two ghcheck tables on the command column.
join -t '|' -j1 \
  <(grep -E '^\| [a-z]' "$out/github/ghcheck.md" | grep -v '^| command ' | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/ /,"",$3); print $2"|"$3}' | sort) \
  <(grep -E '^\| [a-z]' "$out/diffinery/ghcheck.md" | grep -v '^| command ' | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/ /,"",$3); e=$4; gsub(/^ +| +$/,"",e); print $2"|"$3 (e ? " ("e")" : "")}' | sort) \
  | awk -F'|' '{print "| "$1" | "$2" | "$3" |"}'
echo
echo "### API answers (fields GitHub clients rely on)"
echo
echo '```'
node "$root/scripts/apidiff.mjs" compare "$out/github/api-self.json" "$out/diffinery/api-self.json"
echo '```'
