#!/bin/bash

# This script creates or updates CNAME records for custom domains containing "intern".
# It points the custom domain to the default hostname of an Azure App Service or Function App.

# Usage: ./update-cname-records.sh <parameter_file> <dns_zone_name> <dns_resource_group> <app_resource_group> <app_type>

PARAMETER_FILE=$1
DNS_ZONE_NAME=$2
DNS_RESOURCE_GROUP=$3
APP_RESOURCE_GROUP=$4
APP_TYPE=$5  # "appService" or "functionApp"

if [ -z "$PARAMETER_FILE" ] || [ -z "$DNS_ZONE_NAME" ] || [ -z "$DNS_RESOURCE_GROUP" ] || [ -z "$APP_RESOURCE_GROUP" ] || [ -z "$APP_TYPE" ]; then
    echo "Usage: ./update-cname-records.sh <parameter_file> <dns_zone_name> <dns_resource_group> <app_resource_group> <app_type>"
    exit 1
fi

if [ "$APP_TYPE" != "appService" ] && [ "$APP_TYPE" != "functionApp" ]; then
    echo "Error: app_type must be either 'appService' or 'functionApp'"
    exit 1
fi

# Function to process domains for a given app
process_app() {
  local app_info=$1
  local app_name=$(echo "$app_info" | jq -r '.name')
  
  # Get the default hostname using Azure CLI
  local default_hostname=""
  if [ "$APP_TYPE" == "appService" ]; then
    echo "Fetching default hostname for App Service: $app_name"
    default_hostname=$(az webapp show --name "$app_name" --resource-group "$APP_RESOURCE_GROUP" --query "defaultHostName" -o tsv)
  elif [ "$APP_TYPE" == "functionApp" ]; then
    echo "Fetching default hostname for Function App: $app_name"
    default_hostname=$(az functionapp show --name "$app_name" --resource-group "$APP_RESOURCE_GROUP" --query "defaultHostName" -o tsv)
  fi

  if [ -z "$default_hostname" ]; then
    echo "Error: Could not retrieve default hostname for $app_name. Skipping."
    return
  fi

  # Extract custom domains for the app
  local custom_domains=$(echo "$app_info" | jq -r '.customDomains[]')

  for domain in $custom_domains; do
    if [[ "$domain" == *intern* ]]; then
      echo "Processing domain: $domain"
      
      # Remove the DNS zone suffix from the domain to get the subdomain
      subdomain=$(echo "$domain" | sed "s/.$DNS_ZONE_NAME//")

      # Check for and delete existing A record
      echo "Checking for existing A record for $subdomain..."
      a_record=$(az network dns record-set a show --resource-group "$DNS_RESOURCE_GROUP" --zone-name "$DNS_ZONE_NAME" --name "$subdomain" --query "name" -o tsv 2>/dev/null)

      if [ -n "$a_record" ]; then
        echo "Found and deleting existing A record for $subdomain"
        az network dns record-set a delete \
          --resource-group "$DNS_RESOURCE_GROUP" \
          --zone-name "$DNS_ZONE_NAME" \
          --name "$subdomain" \
          --yes
      else
        echo "No existing A record found for $subdomain."
      fi

      echo "Creating/Updating CNAME record for $subdomain -> $default_hostname"
      az network dns record-set cname set-record \
        --resource-group "$DNS_RESOURCE_GROUP" \
        --zone-name "$DNS_ZONE_NAME" \
        --record-set-name "$subdomain" \
        --cname "$default_hostname"
    else
      echo "Skipping domain (does not contain 'intern'): $domain"
    fi
  done
}

# Extract app services or function apps from the parameter file
if [ "$APP_TYPE" == "appService" ]; then
  APPS=$(jq -c '.parameters.appServices.value[]' "$PARAMETER_FILE")
elif [ "$APP_TYPE" == "functionApp" ]; then
  APPS=$(jq -c '.parameters.functionApps.value[]' "$PARAMETER_FILE")
else
  echo "Invalid APP_TYPE specified. Use 'appService' or 'functionApp'."
  exit 1
fi

# Process each app
for app in $APPS; do
  process_app "$app"
done
