# === Registry & Project Info ===
CI_REGISTRY           ?= docker-registry.sabay.com
CI_PROJECT_NAMESPACE  ?= sabay-cloud-api/web
CI_PROJECT_NAME       ?= landing-page
IMG                   = $(CI_REGISTRY)/$(CI_PROJECT_NAMESPACE)/$(CI_PROJECT_NAME)
COMPOSE_PROJECT_NAME  ?= $(CI_PROJECT_NAME)

# === MySabay Configuration ===
# (Optional) Path to input JSON file for deploy payloads
# NOTE: This will be provided in the next step of the script
# INPUT_JSON =

# === API Endpoints ===
GATEWAY_GQL_URL       = https://gateway.testing.sabay.com/graphql
MYSABAY_URL           = https://mysabay.testing.sabay.com/
LOGIN_URL             = https://id.testing.sabay.com/

# === Account Credentials ===
USERNAME              = sabay
PASSWORD              = UxB86fWImCnD3nDF

# === Service Configuration ===
# Product ID (depends on SERVICE_CODE and plan)
# Example: cloud_container_app → Basic plan 
PRODUCT_ID            = 65fd3f9cfca6cdbe03435c6d #(replace)

# Currency
# Example values: "SC" = Sabay Coin, "SG" = Sabay Gold
CURRENCY              = SC

# Subscription ID
# - Leave empty to create a new subscription
# - Set a valid ID to reuse an existing subscription
SUBSCRIPTION_ID       =

# === Documentation & Extra URLs ===
CLOUD_DOC_API         = https://elegant-barberry-1a3.notion.site/ebd/19ffbf65426780838d44f18ecfb58ba6
CLOUD_DOC_USER_GUIDE  = https://inky-fisher-dcb.notion.site/ebd/138af76af09380a2a386d90527979c02
MYSABAY_URL_BUSINESS  = https://mysabay.testing.sabay.com/business
GATEWAY_GQL_URL_ALT   = https://gateway.testing.sabay.com/graphql

# === Stack Information ===
INPUT_JSON := { \
  "stackName": "$(COMPOSE_PROJECT_NAME)", \
  "deployNow": true, \
  "environments": [], \
  "services": [ \
    { \
      "serviceName": "$(COMPOSE_PROJECT_NAME)", \
      "restartPolicy": { \
        "maxAttempt": 5, \
        "restartWindow": "120s", \
        "delay": "5s", \
        "condition": "NONE" \
      }, \
      "resources": { \
        "memory": 1024, \
        "cpu": 0.5 \
      }, \
      "domainName": "$(DOMAIN)", \
      "port": 80, \
      "image": "$(IMG)/app:$(ENVIRONMENT)", \
      "privateRegistry": { \
        "name": "", \
        "host": "", \
        "username": "", \
        "accessToken": "" \
      }, \
      "entrypoint": "", \
      "mountVolume": [], \
      "environments": [ \
        { "envKey": "NODE_ENV", "envValue": "$(ENVIRONMENT)" }, \
        { "envKey": "MYSABAY_URL", "envValue": "$(MYSABAY_URL)" }, \
        { "envKey": "CLOUD_DOC_API", "envValue": "$(CLOUD_DOC_API)" }, \
        { "envKey": "CLOUD_DOC_USER_GUIDE", "envValue": "$(CLOUD_DOC_USER_GUIDE)" }, \
        { "envKey": "GATEWAY_GQL_URL", "envValue": "$(GATEWAY_GQL_URL)" } \
      ] \
    } \
  ] \
}

