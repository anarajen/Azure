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

# Validate resource type and set commands
if [ "$RESOURCE_TYPE" == "app-service" ]; then
    RESOURCE_PROVIDER="Microsoft.Web/sites"
    SETTINGS_CMD="webapp"
elif [ "$RESOURCE_TYPE" == "function-app" ]; then
    RESOURCE_PROVIDER="Microsoft.Web/sites"
    SETTINGS_CMD="functionapp"
else
    echo "Error: Invalid resource type. Must be 'app-service' or 'function-app'."
    exit 1
fi

# Read the mapping file and iterate through the mappings for the specified environment
jq -r ".${ENVIRONMENT} | to_entries[] | \"\(.key) \(.value)\"" "$MAPPING_FILE" | while read -r original_name new_name; do
  echo "Processing settings migration from '$original_name' to '$new_name'..."

  # Get the original resource ID and resource group
  original_resource_id=$(az resource list --name "$original_name" --resource-type "$RESOURCE_PROVIDER" --query "[0].id" -o tsv)
  if [ -z "$original_resource_id" ]; then
    echo "  Warning: Original resource '$original_name' not found. Skipping."
    continue
  fi
  original_resource_group=$(az resource show --ids "$original_resource_id" --query "resourceGroup" -o tsv)

  # Get the new resource ID and resource group
  new_resource_id=$(az resource list --name "$new_name" --resource-type "$RESOURCE_PROVIDER" --query "[0].id" -o tsv)
  if [ -z "$new_resource_id" ]; then
    echo "  Warning: New resource '$new_name' not found. Skipping."
    continue
  fi
  new_resource_group=$(az resource show --ids "$new_resource_id" --query "resourceGroup" -o tsv)

  # Get app settings from the original resource
  echo "  Fetching settings from '$original_name'..."
  app_settings=$(az "$SETTINGS_CMD" config appsettings list --name "$original_name" --resource-group "$original_resource_group" -o json)

  if [ -z "$app_settings" ] || [ "$(echo "$app_settings" | jq 'length')" -eq 0 ]; then
    echo "  No app settings found for '$original_name'."
    continue
  fi

  # Get existing settings from the new resource to check for specific keys
  echo "  Fetching existing settings from '$new_name' to check for Application Insights keys..."
  new_app_settings=$(az "$SETTINGS_CMD" config appsettings list --name "$new_name" --resource-group "$new_resource_group" --query "[].name" -o json)

  # Prepare settings for the new resource, excluding certain keys if they already exist.
  settings_to_apply=()
  while IFS= read -r setting_json; do
      name=$(echo "$setting_json" | jq -r '.name')
      value=$(echo "$setting_json" | jq -r '.value')

      # Check if the setting is one of the protected keys
      if [[ "$name" == "APPLICATIONINSIGHTS_CONNECTION_STRING" || "$name" == "APPINSIGHTS_INSTRUMENTATIONKEY" ]]; then
          # Check if the key exists in the new app's settings
          if echo "$new_app_settings" | jq -e --arg KEY "$name" '.[] | select(. == $KEY)' > /dev/null; then
              echo "    Skipping existing setting: $name"
              continue
          fi
      fi
      
      # Add the setting to the list to be applied
      settings_to_apply+=("$name=$value")
  done < <(echo "$app_settings" | jq -c '.[]')

  if [ ${#settings_to_apply[@]} -eq 0 ]; then
      echo "  No settings to apply."
      continue
  fi

  echo "  Applying settings to '$new_name'..."
  
  # Set the app settings on the new resource
  az "$SETTINGS_CMD" config appsettings set --name "$new_name" --resource-group "$new_resource_group" --settings "${settings_to_apply[@]}"

  if [ $? -eq 0 ]; then
      echo "  Successfully migrated settings."
  else
      echo "  Error: Failed to migrate settings."
  fi
  
  echo "-----------------------------------------------------"
done

echo "App settings migration completed."
