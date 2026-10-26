#!/usr/bin/env bash
# ghcheck.sh: run the same gh commands against a repo on GitHub and its twin on Diffinery,
# and print one line per command: ok, or FAIL with the first error line.
#
#   scripts/ghcheck.sh github.com/joeblew999/diffinery-bench
#   scripts/ghcheck.sh diffinery.ubuntusoftware.net/gedw99/diffinery-bench
#
# gh must be signed in to the host (for Diffinery: diffinery auth setup-gh, write scope).
# The write checks create an issue, a comment, a label and a workflow run, then close and
# delete what they made. Set GHCHECK_READONLY=1 to skip them.
set -uo pipefail

R="${1:?usage: ghcheck.sh HOST/OWNER/REPO}"
PR="${GHCHECK_PR:-3}"
ISSUE="${GHCHECK_ISSUE:-2}"
STAMP="ghcheck-$(date -u +%Y%m%d%H%M%S)"

check() { # check "label" cmd...
  local label="$1"; shift
  local out
  if out=$(timeout 60 "$@" 2>&1); then
    printf '| %-34s | ok   | |\n' "$label"
  else
    printf '| %-34s | FAIL | %s |\n' "$label" "$(printf '%s' "$out" | grep -v '^\s*$' | head -1 | cut -c1-110 | tr '|' '/')"
  fi
  LAST_OUT="$out"
}

# check_has "label" "regex the output must contain" cmd...
# A command that exits 0 but shows the wrong answer (e.g. an empty list) is a FAIL.
check_has() {
  local label="$1" want="$2"; shift 2
  local out
  if ! out=$(timeout 60 "$@" 2>&1); then
    printf '| %-34s | FAIL | %s |\n' "$label" "$(printf '%s' "$out" | grep -v '^\s*$' | head -1 | cut -c1-110 | tr '|' '/')"
  elif printf '%s' "$out" | grep -qE "$want"; then
    printf '| %-34s | ok   | |\n' "$label"
  else
    printf '| %-34s | FAIL | ran, but the output does not show %s |\n' "$label" "$want"
  fi
  LAST_OUT="$out"
}

echo "### gh against $R"
echo
echo "| command | result | first error |"
echo "|---|---|---|"
check "repo view"               gh repo view "$R"
check_has "pr list --state all" "^$PR\b" gh pr list -R "$R" --state all
check_has "pr view $PR" "number:\s+$PR" gh pr view "$PR" -R "$R"
check "pr view $PR --json"      gh pr view "$PR" -R "$R" --json number,title,state,mergedAt,headRefName
check "pr diff $PR"             gh pr diff "$PR" -R "$R"
check "pr checks $PR"           gh pr checks "$PR" -R "$R"
check_has "issue list --state all" "^$ISSUE\b" gh issue list -R "$R" --state all
check_has "issue view $ISSUE" "number:\s+$ISSUE" gh issue view "$ISSUE" -R "$R"
check_has "label list" "bug" gh label list -R "$R"
check "release list"            gh release list -R "$R"
check_has "workflow list" "bench" gh workflow list -R "$R"
check_has "run list" "bench" gh run list -R "$R" --limit 5
RUN_ID=$(gh api "repos/${R#*/}/actions/runs" --hostname "${R%%/*}" --jq '.workflow_runs[0].id' 2>/dev/null)
check "run view <latest>"       gh run view "${RUN_ID:-0}" -R "$R"
check "api repos/{repo}"        gh api "repos/${R#*/}" --hostname "${R%%/*}"
check "search via api: issues"  gh api "repos/${R#*/}/issues?state=all" --hostname "${R%%/*}"

if [ -z "${GHCHECK_READONLY:-}" ]; then
  check "issue create"          gh issue create -R "$R" --title "$STAMP" --body "Made by scripts/ghcheck.sh; closed straight away."
  NEW=$(printf '%s' "$LAST_OUT" | grep -oE '[0-9]+$' | tail -1)
  check "issue comment"         gh issue comment "${NEW:-0}" -R "$R" --body "comment from ghcheck"
  check "issue close"           gh issue close "${NEW:-0}" -R "$R"
  check "label create"          gh label create "$STAMP" -R "$R" --color ededed
  check "label delete"          gh label delete "$STAMP" -R "$R" --yes
  check "workflow run bench.yml" gh workflow run bench.yml -R "$R" --ref main
fi
