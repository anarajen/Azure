#!/bin/bash

# This script adds TXT verification records to an Azure DNS zone for custom domains.

# Usage: ./add-dns-records.sh <parameter_file> <dns_zone_name> <resource_group>

PARAMETER_FILE=$1
DNS_ZONE_NAME=$2
RESOURCE_GROUP=$3
VERIFICATION_ID=$4
APP_TYPE=$5  # "appService" or "functionApp"

if [ -z "$PARAMETER_FILE" ] || [ -z "$DNS_ZONE_NAME" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$VERIFICATION_ID" ] || [ -z "$APP_TYPE" ]; then
    echo "Usage: ./add-dns-records.sh <parameter_file> <dns_zone_name> <resource_group> <verification_id> <app_type>"
    exit 1
fi

if [ "$APP_TYPE" != "appService" ] && [ "$APP_TYPE" != "functionApp" ]; then
    echo "Error: app_type must be either 'appService' or 'functionApp'"
    exit 1
fi


# Extract custom domains from the parameter file
if [ "$APP_TYPE" == "appService" ]; then
  CUSTOM_DOMAINS=$(jq -r '.parameters.appServices.value[].customDomains[] // [] ' $PARAMETER_FILE)
elif [ "$APP_TYPE" == "functionApp" ]; then
  CUSTOM_DOMAINS=$(jq -r '.parameters.functionApps.value[].customDomains[] // [] ' $PARAMETER_FILE)
else
  echo "Invalid APP_TYPE specified. Use 'appService' or 'functionApp'."
  exit 1
fi

for domain in $CUSTOM_DOMAINS; do
  # Remove the DNS zone suffix from the domain to get the subdomain
  subdomain=$(echo "$domain" | sed "s/.$DNS_ZONE_NAME//")

  # Get the verification ID from the app service
  # Note: This assumes the app service name can be derived from the domain, which may not be the case.
  # You may need to adjust this logic based on your naming conventions.
  APP_NAME=$(echo $domain | cut -d. -f1)

  if [ -z "$VERIFICATION_ID" ]; then
    echo "Could not get verification ID for app $APP_NAME"
    continue
  fi

  echo "Adding TXT record for $domain"
  az network dns record-set txt add-record \
    --resource-group $RESOURCE_GROUP \
    --zone-name $DNS_ZONE_NAME \
    --record-set-name "asuid.$subdomain" \
    --value "$VERIFICATION_ID"
done
