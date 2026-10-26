#!/usr/bin/env bash
# diffinery-down.sh: remove a Diffinery instance and everything it created on Cloudflare.
# Lists what it finds and deletes nothing unless you pass --yes.
#
#   scripts/diffinery-down.sh          # dry run: list what would be deleted
#   scripts/diffinery-down.sh --yes    # delete it all (repos and data are gone for good)
#
# Needs: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, DIFFINERY_DOMAIN (e.g. diffinery.example.com),
#        jq, curl. Optional: DIFFINERY_ZONE (default: the domain's last two labels).
# Token permissions: Workers Scripts, Workers Routes, D1, R2, Queues, Workflows, Containers,
# Access: Apps and Policies, Turnstile, DNS and Email Sending (all Edit), Zone Read.
#
# Deletes, in an order Cloudflare accepts: container apps, the Workers route, queue consumers,
# the Email Sending event subscription, the Worker (with its Durable Objects), queues, workflows,
# the D1 database, the R2 bucket (emptied first), the Access app, the Turnstile widget, the
# Email Sending subdomain, DNS records for the hostname, and the runner images.
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}" "${CLOUDFLARE_ACCOUNT_ID:?}" "${DIFFINERY_DOMAIN:?e.g. diffinery.example.com}"
YES=0; [ "${1:-}" = "--yes" ] && YES=1
A="$CLOUDFLARE_ACCOUNT_ID"
ZONE_NAME="${DIFFINERY_ZONE:-$(echo "$DIFFINERY_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')}"
API=https://api.cloudflare.com/client/v4

cf() { curl -fsS -X "$1" "$API$2" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "content-type: application/json" ${3:+--data "$3"}; }
get() { cf GET "$1" 2>/dev/null || { echo "WARNING  couldn't read $1 (token permission?): anything there is not listed" >&2; echo '{"result":[]}'; }; }
gone() { # gone "label" METHOD PATH
  if [ "$YES" = 1 ]; then
    if cf "$2" "$3" >/dev/null 2>&1; then echo "deleted  $1"; else echo "FAILED   $1"; FAILED=1; fi
  else echo "would delete  $1"; fi
}
FAILED=0
Z=$(get "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')
[ -n "$Z" ] || { echo "zone $ZONE_NAME not found in this account" >&2; exit 1; }
echo "Diffinery at $DIFFINERY_DOMAIN (zone $ZONE_NAME), account $A$([ "$YES" = 1 ] || echo ' (dry run)')"

get "/accounts/$A/containers/applications" | jq -r '.result[]? | select(.name|test("^diffinery-")) | "\(.id) \(.name)"' |
  while read -r id name; do gone "container app $name" DELETE "/accounts/$A/containers/applications/$id"; done

get "/zones/$Z/workers/routes" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.pattern|startswith($d)) | "\(.id) \(.pattern)"' |
  while read -r id pat; do gone "route $pat" DELETE "/zones/$Z/workers/routes/$id"; done

QUEUES=$(get "/accounts/$A/queues?per_page=100" | jq -r '.result[]? | select(.queue_name|test("^diffinery-")) | "\(.queue_id) \(.queue_name)"')
while read -r id name; do
  [ -n "$id" ] || continue
  get "/accounts/$A/queues/$id/consumers" | jq -r '.result[]?.consumer_id' |
    while read -r c; do gone "consumer on $name" DELETE "/accounts/$A/queues/$id/consumers/$c"; done
done <<<"$QUEUES"

get "/accounts/$A/event_subscriptions/subscriptions" | jq -r '.result[]? | select(.name|test("diffinery")) | "\(.id) \(.name)"' |
  while read -r id name; do gone "event subscription $name" DELETE "/accounts/$A/event_subscriptions/subscriptions/$id"; done

get "/accounts/$A/workers/scripts" | jq -e '.result[]? | select(.id=="diffinery")' >/dev/null &&
  gone "Worker diffinery (and its Durable Objects)" DELETE "/accounts/$A/workers/scripts/diffinery?force=true"

while read -r id name; do [ -n "$id" ] && gone "queue $name" DELETE "/accounts/$A/queues/$id"; done <<<"$QUEUES"

get "/accounts/$A/workflows?per_page=100" | jq -r '.result[]? | select(.name|test("^diffinery-")) | .name' |
  while read -r w; do gone "workflow $w" DELETE "/accounts/$A/workflows/$w"; done

get "/accounts/$A/d1/database?per_page=100" | jq -r '.result[]? | select(.name=="diffinery") | .uuid' |
  while read -r id; do gone "D1 database diffinery" DELETE "/accounts/$A/d1/database/$id"; done

if get "/accounts/$A/r2/buckets" | jq -e '.result.buckets[]? | select(.name=="diffinery-data")' >/dev/null; then
  if [ "$YES" = 1 ]; then
    n=0
    while :; do
      keys=$(get "/accounts/$A/r2/buckets/diffinery-data/objects?per_page=1000" | jq -r '.result[]?.key')
      [ -n "$keys" ] || break
      while read -r k; do cf DELETE "/accounts/$A/r2/buckets/diffinery-data/objects/$(jq -rn --arg k "$k" '$k|@uri')" >/dev/null && n=$((n+1)); done <<<"$keys"
    done
    echo "emptied  R2 bucket diffinery-data ($n objects)"
  fi
  gone "R2 bucket diffinery-data" DELETE "/accounts/$A/r2/buckets/diffinery-data"
fi

get "/accounts/$A/access/apps" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.domain|startswith($d)) | "\(.id) \(.name)"' |
  while read -r id name; do gone "Access app $name" DELETE "/accounts/$A/access/apps/$id"; done

get "/accounts/$A/challenges/widgets?per_page=1000" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.name=="diffinery \($d)") | .sitekey' |
  while read -r k; do gone "Turnstile widget $k" DELETE "/accounts/$A/challenges/widgets/$k"; done

get "/zones/$Z/email/sending/subdomains" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.name==$d) | (.id // .tag)' |
  while read -r id; do gone "Email Sending for $DIFFINERY_DOMAIN" DELETE "/zones/$Z/email/sending/subdomains/$id"; done

get "/zones/$Z/dns_records?per_page=500" | jq -r --arg d "$DIFFINERY_DOMAIN" '.result[]? | select(.name==$d or (.name|endswith("."+$d))) | "\(.id) \(.type) \(.name)"' |
  while read -r id type name; do gone "DNS $type $name" DELETE "/zones/$Z/dns_records/$id"; done

if command -v npx >/dev/null; then
  imgs=$(npx -y wrangler@4 containers images list 2>/dev/null | awk '$1=="diffinery-runner"{print $1":"$2}' || true)
  for i in $imgs; do
    if [ "$YES" = 1 ]; then npx -y wrangler@4 containers images delete "$i" >/dev/null 2>&1 && echo "deleted  image $i" || { echo "FAILED   image $i"; FAILED=1; }
    else echo "would delete  image $i"; fi
  done
fi

[ "$YES" = 1 ] || echo "Dry run: nothing was deleted. Run again with --yes to delete."
exit "$FAILED"
