#!/bin/bash

# --- Input Arguments ---
GATEWAY_GQL_URL="$2"
USERNAME="$3"
PASSWORD="$4"
LOGIN_URL="$5"
# --- if you print out  ---
# echo "GATEWAY_GQL_URL:$2 or $GATEWAY_GQL_URL"
# echo "USERNAME:$3 or $USERNAME"
# echo "PASSWORD:$4 or $PASSWORD"
# echo "LOGIN_URL:$5 or $LOGIN_URL"

# --- Constants ---
REALM="sabay"
TOKEN_ENDPOINT="$LOGIN_URL/realms/$REALM/protocol/openid-connect/token"

# --- Helpers for Colored Output ---
success() { echo -e "✅ \033[1;32m$1\033[0m"; }
error()   { echo -e "❌ \033[1;31m$1\033[0m"; }

# --- Request Access Token ---
get_access_token() {
  local body="client_id=mysabay_user&grant_type=password&username=$USERNAME&password=$PASSWORD&scope=openid"

  local response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "$body")

  # Quick check: is response empty?
  if [[ -z "$response" ]]; then
    error "No response from server."
    return 1
  fi

  # Try to extract token safely
  local token=$(echo "$response" | node -p "
    let data;
    try { data = JSON.parse(require('fs').readFileSync(0)); }
    catch { data = {}; }
    data.access_token || ''
  ")

  if [[ -z "$token" || "$token" == "null" ]]; then
    local error_desc=$(echo "$response" | node -p "
      let data;
      try { data = JSON.parse(require('fs').readFileSync(0)); }
      catch { data = {}; }
      data.error_description || data.error || 'Unknown error'
    ")
    error "Login failed! Wrong USERNAME or PASSWORD."
    echo "🔎 Server Response: $error_desc"
    return 1
  fi

  echo "$token"
}

# --- Decode JWT and extract mysabay_user_id ---
decode_jwt_payload() {
  local jwt="$1"
  local payload=$(echo "$jwt" | cut -d '.' -f2)

  # Add padding to base64 string
  local padded=$(printf "%s%s" "$payload" "$(printf '=%.0s' $(seq 1 $(( (4 - ${#payload} % 4) % 4 ))))")
  local base64_str=$(echo "$padded" | tr '_-' '/+')

  local decoded=$(echo "$base64_str" | base64 -d 2>/dev/null)
  local mysabay_user_id=$(echo "$decoded" | node -p "
    let data;
    try { data = JSON.parse(require('fs').readFileSync(0)); }
    catch { data = {}; }
    data.mysabay_user_id || ''
  ")

  echo "$mysabay_user_id"
}

# --- Perform GraphQL Request ---
graphql_request() {
  local query="$1"
  curl -s -X POST "$GATEWAY_GQL_URL" \
    -H "Content-Type: application/json" \
    -H "service-code: mysabay_user" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$query"
}

# --- Main Execution ---
TOKEN=$(get_access_token)
if [[ $? -ne 0 || -z "$TOKEN" ]]; then
  error "Access token not retrieved."
  echo "Access Token: ❌ Login failed!"
  exit 1
else
  success "Access token retrieved."
  echo "Access Token: $TOKEN"
fi

MYSABAY_USER_ID=$(decode_jwt_payload "$TOKEN")
if [[ -z "$MYSABAY_USER_ID" ]]; then
  error "Failed to decode MYSABAY_USER_ID"
else
  success "MYSABAY_USER_ID: $MYSABAY_USER_ID"
fi

