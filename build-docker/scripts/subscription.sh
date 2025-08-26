#!/bin/bash

source ./build-docker/scripts/config.sh

# === Variables ===
PRODUCT_ID=$(echo "$6" | xargs)
CURRENCY=$(echo "$7" | xargs)
SUBSCRIPTION_ID=$(echo "${8}" | xargs)
ENVIRONMENT=$(echo "${9}" | xargs)
REQ_TIME=$(date +%s)
TYPE=2
QUANTITY=1
IS_USED_STORE=true
# INFO="{\"type\":\"purchase_cloud_subscription\",\"value\":null,\"service_provider\":null,\"user_id\":$MYSABAY_USER_ID}"

# === Helper: GraphQL error checker ===
check_graphql_error() {
  local response="$1"
  local context="$2"
  if echo "$response" | node -p 'JSON.parse($input).errors' >/dev/null 2>&1; then
    echo -e "❌ \033[1;31mGraphQL Error during $context:\033[0m"
    echo "$response" | node -p 'JSON.stringify(JSON.parse($input), null, 2)'
    exit 1
  fi
}

# === Function: Create Invoice ===
create_invoice() {
  echo -ne "⏳ Creating invoice..."

  if [[ "$CURRENCY" == "SC" ]]; then
    CREATE_INVOICE_RESPONSE=$(graphql_request '{
      "query": "mutation Invoice_createInvoice($input: invoice_CreateInvoiceInput) { invoice_createInvoice(input: $input) { status invoice { id userId } } }",
      "variables": {
        "input": {
          "items": [{"itemId": "'"$PRODUCT_DETAIL_ID"'", "quantity": 1}],
          "amount": '"$AMOUNT"',
          "notes": "",
          "paymentProvider": "Sabay Coin",
          "currency": "SC",
          "isUsedStore": '"$IS_USED_STORE"',
          "info": "{\"type\":\"purchase_cloud_subscription\",\"value\":null,\"service_provider\":null,\"user_id\":\"'"$MYSABAY_USER_ID"'\"}",
          "serviceCode": "cloud_container_app"
        }
      }
    }')
    INVOICE_ID=$(echo "$CREATE_INVOICE_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.invoice_createInvoice.invoice.id')

  elif [[ "$CURRENCY" == "SG" ]]; then
    CREATE_INVOICE_RESPONSE=$(graphql_request '{
      "query": "mutation Invoice_createPaymentReference($input: invoice_CreatePaymentReferenceInput) { invoice_createPaymentReference(input: $input) { status paymentReference { id userId } } }",
      "variables": {
        "input": {
          "items": [{"itemId": "'"$PRODUCT_DETAIL_ID"'", "quantity": 1}],
          "amount": '"$AMOUNT"',
          "notes": "",
          "paymentProvider": "Sabay Gold",
          "currency": "SG",
          "isUsedStore": '"$IS_USED_STORE"',
          "info": "{\"type\":\"purchase_cloud_subscription\",\"value\":null,\"service_provider\":null,\"user_id\":\"'"$MYSABAY_USER_ID"'\"}",
          "serviceCode": "cloud_container_app"
        }
      }
    }')
    INVOICE_ID=$(echo "$CREATE_INVOICE_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.invoice_createPaymentReference.paymentReference.id')
  else
    echo "❌ Unsupported currency: $CURRENCY"
    exit 1
  fi

  check_graphql_error "$CREATE_INVOICE_RESPONSE" "invoice/payment reference creation"
  echo -e "\r✅ Invoice/Reference created with ID: \033[0;32m$INVOICE_ID\033[0m.\033[K"
}

# === Subscription Creation Flow ===
if [ -z "$SUBSCRIPTION_ID" ]; then
  # --- Confirm Subscription Intent ---
  options=("Yes" "No")
  selected=0

  print_menu() {
    clear
    echo "Are you sure you want to subscribe to a new plan?"
    echo "Use ↑ ↓ to navigate, Enter to select:"
    for i in "${!options[@]}"; do
      [[ $i -eq $selected ]] && echo "> ${options[i]}" || echo "  ${options[i]}"
    done
  }

  while true; do
    print_menu
    read -rsn1 key
    case "$key" in
      $'\x1b')
        read -rsn2 key
        [[ "$key" == "[A" ]] && ((selected = (selected - 1 + ${#options[@]}) % ${#options[@]}))
        [[ "$key" == "[B" ]] && ((selected = (selected + 1) % ${#options[@]}))
        ;;
      "")
        echo "You selected: ${options[selected]}"
        [[ "${options[selected]}" == "No" ]] && echo "❌ Cancelled." && exit 0
        break
        ;;
    esac
  done

  # --- Get Payment Service Provider ---
  echo -ne "⏳ Querying payment service provider..."
  PAYMENT_SERVICE_PROVIDER_QUERY=$(node -p -e "
  JSON.stringify({
    query: \"query Checkout_getPaymentServiceProviderForProduct(\$productId: ID!) { checkout_getPaymentServiceProviderForProduct(productId: \$productId) { paymentServiceProviders { providers { id issueCurrencies } } } }\",
    variables: { productId: '$PRODUCT_ID' }
  })")
  
  PAYMENT_SERVICE_PROVIDER_RESPONSE=$(graphql_request "$PAYMENT_SERVICE_PROVIDER_QUERY")
  check_graphql_error "$PAYMENT_SERVICE_PROVIDER_RESPONSE" "fetching payment provider"
  echo -e "\r✅ Provider query completed.\033[K"

  PROVIDER_ID=$(echo "$PAYMENT_SERVICE_PROVIDER_RESPONSE" | node -p '
    const response = JSON.parse(require("fs").readFileSync(0, "utf-8"));
    const providers = response.data?.checkout_getPaymentServiceProviderForProduct?.paymentServiceProviders || [];
    providers.flatMap(provider => provider.providers)
      .find(provider => provider.issueCurrencies.includes("'"$CURRENCY"'"))?.id
  ')

  if [[ -z "$PROVIDER_ID" || "$PROVIDER_ID" == "null" ]]; then
    echo "❌ Provider ID not found."
    exit 1
  fi

  # --- Product Detail ---
  echo -ne "⏳ Querying product details..."
  PRODUCT_DETAILS_QUERY=$(node -p -e "
  JSON.stringify({
    query: 'query Store_getProductById(\$storeGetProductByIdId: ID!) { store_getProductById(id: \$storeGetProductByIdId) { id, properties } }',
    variables: { storeGetProductByIdId: '$PRODUCT_ID' }
  })")

  PRODUCT_DETAILS_RESPONSE=$(graphql_request "$PRODUCT_DETAILS_QUERY")
  check_graphql_error "$PRODUCT_DETAILS_RESPONSE" "product details"
  echo -e "\r✅ Product details fetched.\033[K"

  PRODUCT_DETAIL_ID=$(echo "$PRODUCT_DETAILS_RESPONSE" | node -p '
    const response = JSON.parse(require("fs").readFileSync(0, "utf-8"));
    response.data?.store_getProductById?.id || null
  ')
  AMOUNT=$(echo "$PRODUCT_DETAILS_RESPONSE" | node -p '
    const response = JSON.parse(require("fs").readFileSync(0, "utf-8"));
    response.data?.store_getProductById?.properties?.price?.find(p => p.currency === "SG")?.amount || null
  ')
echo -e " \033[0;32m$PRODUCT_DETAIL_ID\033[0m | \033[0;32m$AMOUNT\033[0m"
  [[ -z "$PRODUCT_DETAIL_ID" || "$PRODUCT_DETAIL_ID" == "null" ]] && echo "❌ Product not found." && exit 1
  [[ -z "$AMOUNT" || "$AMOUNT" == "null" ]] && echo "❌ Price not found." && exit 1
  echo -e "✅ Product ID: \033[0;32m$PRODUCT_DETAIL_ID\033[0m | Amount: \033[0;32m$AMOUNT $CURRENCY\033[0m"

  # --- Create Invoice ---
  create_invoice

  # --- Get Provider Signature ---

  PAYMENT_ADDRESS="${INVOICE_ID}:${TYPE}*invoice-api.testing.sabay.com?req_time=${REQ_TIME}"
  echo -ne "⏳ Fetching provider signature..."

  PAYMENT_SERVICE_PROVIDER_DETAIL_QUERY=$(node -p -e "
  JSON.stringify({
    query: \"query Checkout_getPaymentServiceProviderDetailForPayment(\$id: ID!, \$paymentAddress: String!) { checkout_getPaymentServiceProviderDetailForPayment(id: \$id, paymentAddress: \$paymentAddress) { id hash signature publicKey } }\",
    variables: {
      id: '$PROVIDER_ID',
      paymentAddress: '$PAYMENT_ADDRESS'
    }
  })")

  PAYMENT_SERVICE_PROVIDER_DETAIL_RESPONSE=$(graphql_request "$PAYMENT_SERVICE_PROVIDER_DETAIL_QUERY")
  check_graphql_error "$PAYMENT_SERVICE_PROVIDER_DETAIL_RESPONSE" "signature fetch"
  echo -e "\r✅ Signature fetched.\033[K"

SERVICE_PROVIDER_HASH=$(echo "$PAYMENT_SERVICE_PROVIDER_DETAIL_RESPONSE" | node -p '
  const response = JSON.parse(require("fs").readFileSync(0, "utf-8"));
  response.data?.checkout_getPaymentServiceProviderDetailForPayment?.hash || null
')
  SERVICE_PROVIDER_SIGNATURE=$(echo "$PAYMENT_SERVICE_PROVIDER_DETAIL_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.checkout_getPaymentServiceProviderDetailForPayment.signature')
  SERVICE_PROVIDER_PUBLIC_KEY=$(echo "$PAYMENT_SERVICE_PROVIDER_DETAIL_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.checkout_getPaymentServiceProviderDetailForPayment.publicKey')
[[ -z "$SERVICE_PROVIDER_HASH" ]] && echo "❌ Missing: serviceProviderHash" && exit 1
[[ -z "$SERVICE_PROVIDER_SIGNATURE" ]] && echo "❌ Missing: serviceProviderSignature" && exit 1
[[ -z "$SERVICE_PROVIDER_PUBLIC_KEY" ]] && echo "❌ Missing: serviceProviderPublicKey" && exit 1

  # --- Charge Request ---
  CHARGE_URL="https://psp.testing.mysabay.com/v1/charge/auth/${INVOICE_ID}:${TYPE}*invoice-api.testing.sabay.com?req_time=${REQ_TIME}"
  echo -ne "⏳ Sending charge request..."

  CHARGE_RESPONSE=$(curl -s -f -X POST "$CHARGE_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "service-code: 'mysabay_user'" \
    --data-urlencode "hash=$SERVICE_PROVIDER_HASH" \
    --data-urlencode "signature=$SERVICE_PROVIDER_SIGNATURE" \
    --data-urlencode "public_key=$SERVICE_PROVIDER_PUBLIC_KEY" \
    --data-urlencode "payment_address=$PAYMENT_ADDRESS")

  CURL_EXIT_CODE=$?

  if [[ $CURL_EXIT_CODE -ne 0 || -z "$CHARGE_RESPONSE" ]]; then
    echo -e "\n❌ \033[1;31mCharge request failed (curl exit code: $CURL_EXIT_CODE).\033[0m"
    exit 1
  fi

  echo -e "\r✅ Charge request sent.\033[K"

  # Check response status and hash
  CHARGE_STATUS=$(echo "$CHARGE_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).status')
  TRANSACTION_HASH=$(echo "$CHARGE_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).TransactionHash')

  if [[ "$CHARGE_STATUS" != "200" || -z "$TRANSACTION_HASH" || "$TRANSACTION_HASH" == "null" ]]; then
    echo -e "❌ \033[1;31mCharge failed.\033[0m"
    echo "$CHARGE_RESPONSE" | node -p 'JSON.stringify(JSON.parse($input), null, 2)'
    exit 1
  fi

  # --- Create Subscription ---
  echo -ne "⏳ Creating subscription..."
  CREATE_SUBSCRIPTION_QUERY=$(node -p -e "
  JSON.stringify({
    query: \"mutation Sb_createSubscription(\$txnHash: String!) { sb_createSubscription(txnHash: \$txnHash) { id status } }\",
    variables: {
      txnHash: '$TRANSACTION_HASH'
    }
  })")

  CREATE_SUBSCRIPTION_RESPONSE=$(graphql_request "$CREATE_SUBSCRIPTION_QUERY")

  check_graphql_error "$CREATE_SUBSCRIPTION_RESPONSE" "subscription creation"
  echo -e "\r✅ Subscription created.\033[K"

  SUBSCRIPTION_ID=$(echo "$CREATE_SUBSCRIPTION_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.sb_createSubscription.id')
  SUBSCRIPTION_STATUS=$(echo "$CREATE_SUBSCRIPTION_RESPONSE" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf-8")).data.sb_createSubscription.status')
  echo -e "✅ Subscription ID: \033[0;32m$SUBSCRIPTION_ID\033[0m | Status: \033[0;32m$SUBSCRIPTION_STATUS\033[0m"
  echo -e "productId: \033[0;32m$PRODUCT_ID \033[0m ."

else
  # === Existing Subscription Check ===
  echo -e "🔍 Checking if subscription ID \033[1;33m$SUBSCRIPTION_ID\033[0m exists..."
  SUBSCRIPTION_LIST_RESPONSE=$(graphql_request '{
    "query": "query Sb_listSubscription { sb_listSubscription(filter: { serviceCode: \"cloud_container_app\" }) { documents { id } } }"
  }')
  check_graphql_error "$SUBSCRIPTION_LIST_RESPONSE" "listing subscriptions"

  if [[ -z "$SUBSCRIPTION_LIST_RESPONSE" || ! $(echo "$SUBSCRIPTION_LIST_RESPONSE" | node -p 'try { JSON.parse(require("fs").readFileSync(0, "utf-8")); true } catch { false }') == "true" ]]; then
    echo -e "❌ \033[1;31mError: Invalid or empty subscription list response.\033[0m"
    exit 1
  fi

  SUBSCRIPTION_EXISTS=$(echo "$SUBSCRIPTION_LIST_RESPONSE" | node -p '
    const response = JSON.parse(require("fs").readFileSync(0, "utf-8"));
    const ids = response.data?.sb_listSubscription?.documents?.map(doc => doc.id) || [];
    ids.some(id => id === "'"$SUBSCRIPTION_ID"'")
  ')
  if [[ "$SUBSCRIPTION_EXISTS" != "true" ]]; then
    echo -e "❌ \033[1;31mError: Subscription ID $SUBSCRIPTION_ID does not exist.\033[0m"
    exit 1
  fi

  echo -e "✅ Subscription ID \033[0;32m$SUBSCRIPTION_ID\033[0m exists."
  echo -e "productId: \033[0;32m$PRODUCT_ID\033[0m ."
fi
