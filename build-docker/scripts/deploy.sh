#!/bin/bash
source ./build-docker/scripts/config.sh # Import shared config
source ./build-docker/scripts/subscription.sh # Import shared subscription management config

# Validate if the input JSON parameter ($1) is provided
if [ -z "$1" ]; then
  echo -e "❌ \033[1;31mError: Input JSON parameter is missing.\033[0m"
  exit 1
fi

INPUT_JSON=$1

# Validate that the provided input JSON is valid
if ! echo "$INPUT_JSON" | node -e '
  const fs = require("fs");
  const stdin = fs.readFileSync(0, "utf-8");
  try {
    JSON.parse(stdin);
  } catch (e) {
    console.error("❌ \x1b[1;31mInvalid input JSON provided.\x1b[0m");
    process.exit(1);
  }
' > /dev/null; then
  exit 1
fi


# Extract the stack name from the input JSON
STACK_NAME=$(echo "$INPUT_JSON" | node -p 'JSON.parse(process.argv[1]).stackName' -- "$INPUT_JSON")
if [[ -z "$STACK_NAME" || "$STACK_NAME" == "null" ]]; then
  echo -e "❌ ${RED}Missing stackName in input JSON.${RESET}"
  exit 1
fi

# Debug log function (only runs if DEBUG is set to true)
log_debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo -e "\033[1;36mDEBUG:\033[0m $1"
  fi
}

# General error handler that checks for GraphQL errors in the response
check_graphql_response() {
  local response="$1"
  local has_errors=$(echo "$response" | node -p 'JSON.parse(process.argv[1]).errors?.length || 0' -- "$response")
  if [[ "$has_errors" -gt 0 ]]; then
    echo -e "❌ ${RED}GraphQL Errors:${RESET}"
    echo "$response" | node -p 'JSON.parse(process.argv[1]).errors.forEach(e => console.log(e.message))' -- "$response"
    exit 1
  fi
}

# Fetches the list of volumes associated with a subscription using GraphQL
VOLUME_LIST=$(graphql_request '{"query":"query Container_listSubscriptionVolume($subscriptionId: String!) { container_listSubscriptionVolume(subscriptionId: $subscriptionId) { volumes { id services { id name } name } } }","variables":{"subscriptionId":"'$SUBSCRIPTION_ID'"}}' | node -p "JSON.parse(require('fs').readFileSync(0, 'utf-8')).data.container_listSubscriptionVolume.volumes")

# Fetches the list of container registries associated with the subscription
REGISTRY_LIST=$(graphql_request '{
  "query": "query ContainerRegistries($subscriptionId: String!, $pager: container_PagerInput) { container_listContainerRegistry(subscriptionId: $subscriptionId, pager: $pager) { containerRegistries { id mysabayUserId name host userAccess } } }",
  "variables": {
    "subscriptionId": "'$SUBSCRIPTION_ID'",
    "pager": { "page": 1, "limit": 100 }
  }
}' | node -p "JSON.parse(require('fs').readFileSync(0, 'utf-8')).data.container_listContainerRegistry.containerRegistries")

# Resolves the ID of a volume by its name and container path. If the volume does not exist, creates it.
resolve_volume_id() {
  local volume_name="$1"
  local containerPath="$2"

  if [[ -z "$volume_name" || -z "$containerPath" ]]; then return; fi

  # Check if the volume already exists
  local existing_id=$(echo "$VOLUME_LIST" | node -p "
    const volumes = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    const volume = volumes.find(v => v.name === '$volume_name');
    volume ? volume.id : null;
  ")
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    echo "$existing_id"  # Return the existing volume ID if found
    return
  fi

  # Create a new volume if it does not exist
  local RESPONSE=$(graphql_request '{
    "query": "mutation createVolume($subscriptionId: String!, $volumeName: String!) { container_createVolume(subscriptionId: $subscriptionId, volumeName: $volumeName) { id } }",
    "variables": {"subscriptionId": "'$SUBSCRIPTION_ID'", "volumeName": "'$volume_name'"}
  }')

  check_graphql_response "$RESPONSE"  # Validate GraphQL response
  echo "$RESPONSE" | node -p "
    const response = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    response.data.container_createVolume.id;
  "  # Return the new volume ID
}

# Resolves the ID of a container registry by checking for its name, host, and access credentials. If it does not exist, creates it.
resolve_registry_id() {
  local name="$1" host="$2" username="$3" access_token="$4"
  if [[ -z "$name" || -z "$host" || -z "$username" || -z "$access_token" ]]; then return; fi

  # Check if the registry already exists
  local existing_id=$(echo "$REGISTRY_LIST" | node -p "
    const registries = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    const registry = registries.find(r => r.name === '$name' && r.host === '$host' && r.userAccess?.username === '$username');
    registry ? registry.id : null;
  ")
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    echo "$existing_id"  # Return the existing registry ID if found
    return
  fi

  # Create a new container registry if it does not exist
  local RESPONSE=$(graphql_request '{
    "query": "mutation createRegistry($subscriptionId: String!, $input: container_CreateContainerRegistryInput!) { container_createContainerRegistry(subscriptionId: $subscriptionId, input: $input) { id } }",
    "variables": {
      "subscriptionId": "'$SUBSCRIPTION_ID'",
      "input": {
        "username": "'$username'",
        "name": "'$name'",
        "host": "'$host'",
        "accessToken": "'$access_token'"
      }
    }
  }')

  check_graphql_response "$RESPONSE"  # Validate GraphQL response
  echo "$RESPONSE" | node -p "
    const response = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    response.data.container_createContainerRegistry.id;
  "  # Return the new registry ID
}
# Parse the 'services' array from the input JSON and process each service
SERVICES_JSON=$(echo "$INPUT_JSON" | node -p "JSON.stringify(JSON.parse(require('fs').readFileSync(0, 'utf-8')).services)")

SERVICES="[]"

while read -r service; do
  MOUNT_VOLUMES="[]"
  for volume in $(echo "$service" | node -p "
    const service = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    (service.mountVolume || []).map(v => JSON.stringify(v)).join('\n');
  "); do
    VOL_ID=$(resolve_volume_id $(echo "$volume" | node -p "
      const volume = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
      volume.volumeName;
    ") $(echo "$volume" | node -p "
      const volume = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
      volume.containerPath;
    "))
    UPDATED_VOLUME=$(echo "$volume" | node -p "
      const volume = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
      volume.volumeId = '$VOL_ID';
      JSON.stringify(volume);
    ")
    MOUNT_VOLUMES=$(echo "$MOUNT_VOLUMES" | node -p "
      const volumes = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
      volumes.push(JSON.parse('$UPDATED_VOLUME'));
      JSON.stringify(volumes);
    ")
  done

  REGISTRY=$(echo "$service" | node -p "
    const service = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    JSON.stringify(service.privateRegistry);
  ")
  REG_ID=$(resolve_registry_id $(echo "$REGISTRY" | node -p "
    const registry = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    registry.name;
  ") $(echo "$REGISTRY" | node -p "
    const registry = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    registry.host;
  ") $(echo "$REGISTRY" | node -p "
    const registry = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    registry.username;
  ") $(echo "$REGISTRY" | node -p "
    const registry = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    registry.accessToken;
  "))

  [[ -z "$REG_ID" || "$REG_ID" == "null" ]] && IS_PRIVATE_REGISTRY=false || IS_PRIVATE_REGISTRY=true
  [[ "$REG_ID" == "null" ]] || REG_ID="\"$REG_ID\""

  # Add resolved volume and registry information to the service configuration
  UPDATED_SERVICE=$(echo "$service" | node -p "
    const service = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    const mountVolumes = JSON.parse('$MOUNT_VOLUMES');
    const isPrivateRegistry = $IS_PRIVATE_REGISTRY;
    const containerRegistryId = $REG_ID;
    service.mountVolume = mountVolumes;
    service.isPrivateRegistry = isPrivateRegistry;
    service.containerRegistryId = containerRegistryId;
    JSON.stringify(service);
  ")

  SERVICES=$(echo "$SERVICES" | node -p "
    const services = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    const updatedService = JSON.parse('$UPDATED_SERVICE');
    services.push(updatedService);
    JSON.stringify(services);
  ")
done < <(echo "$SERVICES_JSON" | node -p "
  const services = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
  services.map(service => JSON.stringify(service)).join('\n');
")


# Prepare stack input and check if the stack already exists
STACK_INPUT=$(echo "$INPUT_JSON" | node -p "
  const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
  const services = JSON.parse(process.argv[1]);
  input.services = services;
  JSON.stringify(input);
" -- "$SERVICES")


STACK_ID=$(graphql_request '{"query":"query ContainerList($subscriptionId: String!){container_listStack(subscriptionId:$subscriptionId){stacks{id stackName}}}","variables":{"subscriptionId":"'$SUBSCRIPTION_ID'"}}' | node -p "
  const response = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
  const stack = response.data.container_listStack.stacks.find(s => s.stackName === '$STACK_NAME');
  stack ? stack.id : '' ;
")

# Check if the stack ID is empty '' will create , else update (cant be null will update but error)
 echo -e "Stack ID: $STACK_ID" 

# Update the stack if it exists, else create a new stack
if [[ -n "$STACK_ID" ]]; then

  echo -e "🔄 \033[1;33mUpdating stack... Please wait.\033[0m"
  STACK_INPUT=$(echo "$STACK_INPUT" | node -p "
    const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    input.stackId = '$STACK_ID';
    delete input.stackName;
    input.services = input.services.map(service => {
      delete service.privateRegistry;
      service.mountVolume = service.mountVolume.map(volume => {
        delete volume.volumeName;
        return volume;
      });
      return service;
    });
    JSON.stringify(input, null, 2);
  ")
  GRAPHQL_QUERY=$(echo "$STACK_INPUT" | node -p "
    const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    const subscriptionId = '${SUBSCRIPTION_ID}';
    JSON.stringify({
      query: 'mutation UpdateStack(\$subscriptionId: String!, \$input: container_UpdateStackInput!) { container_updateStack(subscriptionId: \$subscriptionId, input: \$input) { message success }}',
      variables: { subscriptionId, input }
    }, null, 2);
  ")

  # Execute the GraphQL query for stack update
  RESPONSE=$(graphql_request "$GRAPHQL_QUERY")
  check_graphql_response "$RESPONSE"

  # Check if the stack update was successful
  SUCCESS=$(echo "$RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_updateStack?.success")
  MESSAGE=$(echo "$RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_updateStack?.message")

  if [[ -z "$SUCCESS" || "$SUCCESS" == "false" || "$SUCCESS" == "null" ]]; then
    echo -e "❌ \033[1;31mFailed to update stack: $MESSAGE\033[0m"
    exit 1
  fi

  # Deploy the stack after update
  DEPLOY_QUERY=$(node -e '
    const subscriptionId = process.env.SUBSCRIPTION_ID || "'"$SUBSCRIPTION_ID"'";
    const stackId = process.env.STACK_ID || "'"$STACK_ID"'";
    console.log(JSON.stringify({
      query: `mutation Container_deployStackById($subscriptionId: String!, $stackId: String!) { container_deployStackById(subscriptionId: $subscriptionId, stackId: $stackId) { message success } }`,
      variables: { subscriptionId, stackId }
    }));
  ')
  DEPLOY_RESPONSE=$(graphql_request "$DEPLOY_QUERY")
  check_graphql_response "$DEPLOY_RESPONSE"
  DEPLOY_SUCCESS=$(echo "$DEPLOY_RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_deployStackById?.success")
  DEPLOY_MESSAGE=$(echo "$DEPLOY_RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_deployStackById?.message")
  if [[ -z "$DEPLOY_SUCCESS" || "$DEPLOY_SUCCESS" == "false" || "$DEPLOY_SUCCESS" == "null" ]]; then
    echo -e "❌ \033[1;31mFailed to deploy stack: $DEPLOY_MESSAGE\033[0m"
    exit 1
  fi
  echo -e "🚀 \033[1;32mStack deployment triggered: $DEPLOY_MESSAGE\033[0m"



else
  echo -e "🔄 \033[1;33mCreating new stack... Please wait.\033[0m"
  STACK_INPUT=$(echo "$STACK_INPUT" | node -p "
    const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
    input.services = input.services.map(service => {
      delete service.privateRegistry;
      service.mountVolume = service.mountVolume.map(volume => {
        delete volume.volumeName;
        return volume;
      });
      return service;
    });
    JSON.stringify(input);
  ")

GRAPHQL_QUERY=$(echo "$STACK_INPUT" | node -p "
  const input = JSON.parse(require('fs').readFileSync(0, 'utf-8'));
  const subscriptionId = '${SUBSCRIPTION_ID}';
  JSON.stringify({
    query: 'mutation Container_createStack(\$subscriptionId: String!, \$input: container_CreateStackInput!) { container_createStack(subscriptionId: \$subscriptionId, input: \$input) { id }}',
    variables: { subscriptionId, input }
  }, null, 2);
")
fi

# Execute the GraphQL query for stack creation or update
RESPONSE=$(graphql_request "$GRAPHQL_QUERY")
check_graphql_response "$RESPONSE"

# Check if the stack creation or update was successful
SUCCESS=$(echo "$RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_updateStack?.success ?? res.data?.container_createStack?.id")
MESSAGE=$(echo "$RESPONSE" | node -p "const res = JSON.parse(require('fs').readFileSync(0, 'utf-8')); res.data?.container_updateStack?.message ?? res.data?.container_createStack?.id")

if [[ -z "$SUCCESS" || "$SUCCESS" == "false" || "$SUCCESS" == "null" ]]; then
  echo -e "❌ \033[1;31mFailed to deploy stack: $MESSAGE\033[0m"
  exit 1
fi

# Successfully deployed or updated the stack
echo -e "✅ \033[1;32mStack Deploy: $MESSAGE\033[0m"
