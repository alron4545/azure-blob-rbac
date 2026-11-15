#!/usr/bin/env bash
# Test what the service principal can and cannot do.
#
# Signs in AS THE SERVICE PRINCIPAL in a temporary, isolated Azure CLI
# profile (your own `az login` is not touched), runs the access tests from
# the assignment, and prints a results table.
#
# Usage (from the project root, after terraform apply):
#   scripts/test-access.sh
#
# The client secret is read from Terraform state into memory only. It is
# never printed or written to disk.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

out() { terraform output -raw "$1"; }

TENANT_ID="$(out tenant_id)"
CLIENT_ID="$(out client_id)"
SP_OBJECT_ID="$(out service_principal_object_id)"
ACCOUNT="$(out storage_account_name)"
APP_CONTAINER="$(out app_container_name)"
RESTRICTED_CONTAINER="$(out restricted_container_name)"
RESOURCE_GROUP="$(out resource_group_name)"
SUBSCRIPTION_ID="$(terraform console <<<'var.subscription_id' 2>/dev/null | tr -d '"')"
CLIENT_SECRET="$(out client_secret)"

# Terraform doesn't store null outputs, so a missing output means no assignment.
if terraform output -json role_assignment 2>/dev/null | grep -q '"role"'; then
  GRANTED=yes
else
  GRANTED=no
fi

# Isolated Azure CLI profile for the service principal.
export AZURE_CONFIG_DIR="$(mktemp -d)"
cleanup() {
  az logout >/dev/null 2>&1
  rm -rf "$AZURE_CONFIG_DIR"
}
trap cleanup EXIT

mkdir -p test-output
STAMP="$(date +%Y%m%d-%H%M%S)"
UPLOAD_FILE="test-output/report-$STAMP.txt"
DOWNLOAD_FILE="test-output/report-$STAMP.downloaded.txt"
printf 'Automated report generated %s by the reporting service principal.\n' "$(date)" >"$UPLOAD_FILE"

ROWS=""
row() { ROWS="$ROWS$1|$2|$3"$'\n'; }

# Run an az command; print "Success" or "Denied (reason)".
result() {
  local output
  if output="$("$@" 2>&1)"; then
    echo "Success"
  else
    denied_reason "$output"
  fi
}

# Pick the most useful reason out of an Azure CLI error.
denied_reason() {
  # Drop CLI noise: warnings and Python deprecation messages.
  local clean
  clean="$(grep -vE '^WARNING:|SyntaxWarning|^ +(following actions|excludedActions)|^\s*$' <<<"$1")"

  local code
  code="$(grep -oE 'AuthorizationPermissionMismatch|AuthorizationFailure|AuthorizationFailed|AuthenticationFailed|KeyBasedAuthenticationNotPermitted|SubscriptionNotFound|ContainerNotFound|InvalidAuthenticationInfo|AADSTS[0-9]+' <<<"$1" | head -1)"

  local message
  # GUIDs (subscription, object IDs) are masked so the table is safe to screenshot.
  message="$(sed -E 's/^ERROR: *//; s/^\(([A-Za-z]+)\) */\1: /; s/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}/<id>/g' <<<"$clean" | grep -vE '^\s*$' | head -1 | cut -c1-90)"

  if [ -n "$code" ] && [ -n "$message" ] && ! grep -q "$code" <<<"$message"; then
    echo "Denied ($code: $message)"
  elif [ -n "$message" ]; then
    echo "Denied ($message)"
  else
    echo "Denied (${code:-unknown error})"
  fi
}

echo "Service principal:  $CLIENT_ID"
echo "Storage account:    $ACCOUNT"
echo "RBAC assignment:    $([ "$GRANTED" = yes ] && echo "present ($APP_CONTAINER container)" || echo "NOT present")"
echo

# 1. Authenticate as the service principal
login="$(result az login --service-principal --username "$CLIENT_ID" --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID" --allow-no-subscriptions --output none)"
unset CLIENT_SECRET
row "Authenticate as service principal" "Success" "$login"

if [ "$login" != "Success" ]; then
  echo "Sign-in failed: $login"
  exit 1
fi

# 2. Confirm the active identity is the service principal, not a person
active_type="$(az account show --query user.type -o tsv 2>/dev/null)"
active_name="$(az account show --query user.name -o tsv 2>/dev/null)"
if [ "$active_type" = "servicePrincipal" ] && [ "$active_name" = "$CLIENT_ID" ]; then
  row "Active identity is the service principal" "Success" "Success (type=$active_type)"
else
  row "Active identity is the service principal" "Success" "Unexpected: $active_type $active_name"
fi

blob() { az storage blob "$@" --account-name "$ACCOUNT" --auth-mode login --output none; }

if [ "$GRANTED" = yes ]; then exp_ok="Success"; else exp_ok="Denied"; fi

# 3-5. Required blob operations on the app container
row "List blobs in '$APP_CONTAINER'" "$exp_ok" "$(result blob list --container-name "$APP_CONTAINER")"
row "Upload blob to '$APP_CONTAINER'" "$exp_ok" \
  "$(result blob upload --container-name "$APP_CONTAINER" --name "$(basename "$UPLOAD_FILE")" --file "$UPLOAD_FILE" --overwrite)"

download="$(result blob download --container-name "$APP_CONTAINER" --name "$(basename "$UPLOAD_FILE")" --file "$DOWNLOAD_FILE")"
if [ "$download" = "Success" ]; then
  if cmp -s "$UPLOAD_FILE" "$DOWNLOAD_FILE"; then
    download="Success (contents match)"
  else
    download="Downloaded, but contents DIFFER"
  fi
fi
row "Download blob and verify contents" "$exp_ok" "$download"

# 6. Negative tests: outside the assigned scope / permissions
row "List blobs in '$RESTRICTED_CONTAINER' (out of scope)" "Denied" \
  "$(result blob list --container-name "$RESTRICTED_CONTAINER")"
row "Read storage account keys (management plane)" "Denied" \
  "$(result az storage account keys list --account-name "$ACCOUNT" --resource-group "$RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" --output none)"
# Listing is filtered to what the caller may read, so it can "succeed" with
# an empty list. Report how many resource groups are visible: 0 = no access.
if rg_count="$(az group list --subscription "$SUBSCRIPTION_ID" --query 'length(@)' -o tsv 2>/dev/null)"; then
  if [ "$rg_count" = "0" ]; then
    rg_result="Denied (call allowed, but 0 resource groups visible)"
  else
    rg_result="ALLOWED: $rg_count resource group(s) visible"
  fi
else
  rg_result="$(result az group list --subscription "$SUBSCRIPTION_ID" --output none)"
fi
row "List resource groups in subscription" "Denied" "$rg_result"
row "Read resource group '$RESOURCE_GROUP' (management plane)" "Denied" \
  "$(result az group show --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" --output none)"

# Results table
echo "| Test | Expected | Actual Result |"
echo "| ---- | -------- | ------------- |"
printf '%s' "$ROWS" | while IFS='|' read -r test expected actual; do
  echo "| $test | $expected | $actual |"
done

if [ "$GRANTED" = yes ] && printf '%s' "$ROWS" | grep -q "^Upload.*|Success|Denied"; then
  echo
  echo "Note: RBAC changes can take up to ~10 minutes to take effect. If uploads are"
  echo "denied right after 'terraform apply', wait a few minutes and run this again."
fi
