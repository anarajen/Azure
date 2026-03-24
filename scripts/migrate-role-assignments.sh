#!/bin/bash

# Function to display usage information
usage() {
  echo "Usage: $0 -f <mapping_file> -e <environment> -t <resource_type>"
  echo "  -f <mapping_file>    : Path to the name mapping JSON file."
  echo "  -e <environment>     : Environment (e.g., dev, uat)."
  echo "  -t <resource_type>   : Resource type ('app-service' or 'function-app')."
  exit 1
}

# Parse command-line arguments
while getopts ":f:e:t:" opt; do
  case ${opt} in
    f )
      MAPPING_FILE=$OPTARG
      ;;
    e )
      ENVIRONMENT=$OPTARG
      ;;
    t )
      RESOURCE_TYPE=$OPTARG
      ;;
    \? )
      usage
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      usage
      ;;
  esac
done
shift $((OPTIND -1))

# Validate required arguments
if [ -z "$MAPPING_FILE" ] || [ -z "$ENVIRONMENT" ] || [ -z "$RESOURCE_TYPE" ]; then
  usage
fi

# Validate resource type
if [ "$RESOURCE_TYPE" != "app-service" ] && [ "$RESOURCE_TYPE" != "function-app" ]; then
    echo "Error: Invalid resource type. Must be 'app-service' or 'function-app'."
    exit 1
fi

output_file_name="$ENVIRONMENT-$RESOURCE_TYPE-role-assignment.json"

# Read the mapping file and iterate through the mappings for the specified environment
jq -r ".${ENVIRONMENT} | to_entries[] | \"\(.key) \(.value)\"" "$MAPPING_FILE" | while read -r original_name new_name; do
  echo "Processing migration from '$original_name' to '$new_name'..."

  # Determine the resource group and resource type for the az commands
  if [ "$RESOURCE_TYPE" == "app-service" ]; then
    RESOURCE_PROVIDER="Microsoft.Web/sites"
  elif [ "$RESOURCE_TYPE" == "function-app" ]; then
    RESOURCE_PROVIDER="Microsoft.Web/sites"
  fi

  # Get the resource IDs
  original_resource_id=$(az resource list --name "$original_name" --resource-type "$RESOURCE_PROVIDER" --query "[0].id" -o tsv)
  new_resource_id=$(az resource list --name "$new_name" --resource-type "$RESOURCE_PROVIDER" --query "[0].id" -o tsv)

  # Get the managed identity of the original app service
  original_principal_id=$(az resource show --ids "$original_resource_id" --query "identity.principalId" -o tsv)
  if [ -z "$original_principal_id" ]; then
    echo "  Warning: Could not find managed identity for '$original_name'. Skipping."
    continue
  fi

  # Get role assignments for the original resource's managed identity
  role_assignments=$(az role assignment list --all --assignee "$original_principal_id" --query "[].{role:roleDefinitionName, scope:scope}" -o json)

  if [ -z "$role_assignments" ] || [ "$(echo "$role_assignments" | jq 'length')" -eq 0 ]; then
    echo "  No role assignments found for the managed identity of '$original_name'."
    continue
  fi

  echo "  Found role assignments for '$original_name's managed identity:"
  echo "$role_assignments" | jq -r '.[] | "    - Role: \(.role), Scope: \(.scope)"' 

  # Get the new resource's managed identity
  new_principal_id=$(az resource show --ids "$new_resource_id" --query "identity.principalId" -o tsv)
  if [ -z "$new_principal_id" ]; then
    echo "  Warning: Could not find managed identity for new resource '$new_name'. Skipping role assignment."
    continue
  fi

  # Create the same role assignments for the new resource's managed identity
  echo "$role_assignments" | jq -c '.[]' | while read -r role_assignment; do
    role=$(echo "$role_assignment" | jq -r '.role')
    scope=$(echo "$role_assignment" | jq -r '.scope')

    echo "  Assigning role '$role' to '$new_name' on scope '$scope'..."

    # Check if the role assignment already exists
    existing_assignment=$(az role assignment list --assignee "$new_principal_id" --role "$role" --scope "$scope" -o json | jq '.[0]')

    if [ "$existing_assignment" != "null" ]; then
        echo "    Role assignment already exists. Skipping."
    else
        az role assignment create --assignee-object-id "$new_principal_id" --assignee-principal-type "ServicePrincipal" --role "$role" --scope "$scope" 
        if [ $? -eq 0 ]; then
            echo "    Successfully assigned role."
        else
            echo "    Error: Failed to assign role."
        fi
    fi
  done
  echo "-----------------------------------------------------"
done

echo "Role assignment migration completed."
