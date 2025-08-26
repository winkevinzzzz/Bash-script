#Makefile

include ./include.mk

help:
	@echo "  check         - Test config.sh for user ID and token"
	@echo "  subscription  - Prompt user to confirm subscription"
	@echo "  deploy        - Deploy stack (create|update)"

##############################################
#               DEPLOY WORKFLOW              #
#   Handles both new and existing stacks      #
##############################################

check:
	@bash ./build-docker/scripts/config.sh '$(INPUT_JSON)' '$(GATEWAY_GQL_URL)' '$(USERNAME)' '$(PASSWORD)' '$(LOGIN_URL)' '$(PRODUCT_ID)' '$(CURRENCY)' '$(SUBSCRIPTION_ID)'

subscription:
	@bash ./build-docker/scripts/subscription.sh '$(INPUT_JSON)' '$(GATEWAY_GQL_URL)' '$(USERNAME)' '$(PASSWORD)' '$(LOGIN_URL)' '$(PRODUCT_ID)' '$(CURRENCY)' '$(SUBSCRIPTION_ID)'

deploy:
	@bash ./build-docker/scripts/deploy.sh '$(INPUT_JSON)' '$(GATEWAY_GQL_URL)' '$(USERNAME)' '$(PASSWORD)' '$(LOGIN_URL)' '$(PRODUCT_ID)' '$(CURRENCY)' '$(SUBSCRIPTION_ID)'
