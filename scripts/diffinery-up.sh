#!/usr/bin/env bash
# diffinery-up.sh: deploy a Diffinery instance to your Cloudflare account, including the steps
# Diffinery's own scripts/setup.sh leaves to you (DNS record, Email Sending, Turnstile, Access
# team domain). Safe to run again: every step checks before it creates.
#
# Needs: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, DIFFINERY_DOMAIN, BOOTSTRAP_ADMINS,
#        git, Node 22 + pnpm 10 (via mise), Docker, jq, curl, openssl.
# Optional: DIFFINERY_REF (the Diffinery commit to deploy; default is the one this kit was tested
#           with), DIFFINERY_ZONE (default: the domain's last two labels).
# Token permissions: everything in Diffinery's deploy guide (Workers Scripts, D1, R2, Queues,
# Workflows, Containers, Access: Apps and Policies, Turnstile, Workers Routes, Zone Read), plus
# DNS Edit, Email Sending Edit and Access: Organizations Read, which this script uses for the
# extra steps. The same token works for scripts/diffinery-down.sh.
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}" "${CLOUDFLARE_ACCOUNT_ID:?}" "${DIFFINERY_DOMAIN:?e.g. diffinery.example.com}" "${BOOTSTRAP_ADMINS:?your email}"
REF="${DIFFINERY_REF:-1e2f4b74790a208406663d5c478ce77151e72d85}"
A="$CLOUDFLARE_ACCOUNT_ID"
ZONE_NAME="${DIFFINERY_ZONE:-$(echo "$DIFFINERY_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')}"
API=https://api.cloudflare.com/client/v4
cf() { curl -fsS -X "$1" "$API$2" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "content-type: application/json" ${3:+--data "$3"}; }
say() { echo; echo "==> $*"; }

Z=$(cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')
[ -n "$Z" ] || { echo "zone $ZONE_NAME not found in this account" >&2; exit 1; }

say "Access team domain"
if [ -z "${ACCESS_TEAM_DOMAIN:-}" ]; then
  ACCESS_TEAM_DOMAIN=$(cf GET "/accounts/$A/access/organizations" | jq -r '.result.auth_domain // empty' || true)
fi
echo "${ACCESS_TEAM_DOMAIN:-not found (set ACCESS_TEAM_DOMAIN)}"
export ACCESS_TEAM_DOMAIN

say "DNS record for $DIFFINERY_DOMAIN (a Workers route only runs on a proxied record)"
if cf GET "/zones/$Z/dns_records?name=$DIFFINERY_DOMAIN" | jq -e '.result | length > 0' >/dev/null; then
  echo "exists"
else
  cf POST "/zones/$Z/dns_records" "$(jq -nc --arg n "$DIFFINERY_DOMAIN" '{type:"AAAA",name:$n,content:"100::",proxied:true,ttl:1,comment:"Diffinery (Worker route only)"}')" >/dev/null
  echo "created proxied AAAA 100::"
fi

say "Email Sending for $DIFFINERY_DOMAIN"
sub=$(cf GET "/zones/$Z/email/sending/subdomains" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.name==$d) | (.id // .tag)' || true)
if [ -z "$sub" ]; then
  sub=$(cf POST "/zones/$Z/email/sending/subdomains" "$(jq -nc --arg d "$DIFFINERY_DOMAIN" '{name:$d}')" | jq -r '.result.id // .result.tag')
  echo "onboarded"
fi
cf POST "/zones/$Z/email/sending/subdomains/$sub/dns" >/dev/null && echo "DNS records for sending: $(cf GET "/zones/$Z/email/sending/subdomains/$sub/dns/status" | jq -r '.result.status')"

say "Diffinery $REF"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git clone -q https://github.com/codician-team/diffinery.git "$work/diffinery"
git -C "$work/diffinery" checkout -q "$REF"

say "Turnstile widget"
wname="diffinery $DIFFINERY_DOMAIN"
key=$(cf GET "/accounts/$A/challenges/widgets?per_page=1000" | jq -r --arg n "$wname" '.result[]? | select(.name==$n) | .sitekey' | head -1)
if [ -z "$key" ]; then
  key=$(cf POST "/accounts/$A/challenges/widgets" "$(jq -nc --arg n "$wname" --arg d "$DIFFINERY_DOMAIN" '{name:$n,domains:[$d],mode:"managed"}')" | jq -r '.result.sitekey')
  echo "created $key"
else echo "exists $key"; fi
# Pin the site key in Diffinery's config, so its setup.sh leaves Turnstile alone; the secret is set after the deploy.
node -e '
  const fs=require("fs"), f=process.argv[1], k=process.argv[2];
  let s=fs.readFileSync(f,"utf8");
  if(!s.includes("\"TURNSTILE_SITE_KEY\"")) s=s.replace(/"vars":\s*\{/, m=>m+"\n    \"TURNSTILE_SITE_KEY\": \""+k+"\",");
  fs.writeFileSync(f,s);' "$work/diffinery/apps/diffinery/wrangler.jsonc" "$key"

say "Diffinery's own deploy (scripts/setup.sh)"
# Its last check can fail right after a deploy while the new version spreads; it is safe to repeat.
(cd "$work/diffinery" && DIFFINERY_ZONE="$ZONE_NAME" scripts/setup.sh) ||
  { echo "setup.sh failed; retrying once in 30 s"; sleep 30; (cd "$work/diffinery" && DIFFINERY_ZONE="$ZONE_NAME" scripts/setup.sh); }

say "Turnstile secret on the Worker"
cf GET "/accounts/$A/challenges/widgets/$key" | jq -j '.result.secret' |
  (cd "$work/diffinery/apps/diffinery" && pnpm exec wrangler secret put TURNSTILE_SECRET --name diffinery >/dev/null) && echo "set"

say "Done: https://$DIFFINERY_DOMAIN"
echo "Sign in as the first administrator at https://$DIFFINERY_DOMAIN/auth/access and add a passkey."
