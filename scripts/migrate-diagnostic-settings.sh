#!/bin/bash

# Script to migrate diagnostic settings from source to target App Services/Function Apps
# Uses the mapping file to identify source and target resources

# Function to display usage information
usage() {
  echo "Usage: $0 -f <mapping_file> -e <environment> -t <resource_type>"
  echo "  -f <mapping_file>    : Path to the name mapping JSON file."
  echo "  -e <environment>     : Environment (e.g., dev, uat)."
  echo "  -t <resource_type>   : Resource type ('app-service' or 'function-app')."
  echo ""
  echo "Example:"
  echo "  $0 -f config/app-service-name-mapping.json -e dev -t app-service"
  echo "  $0 -f config/function-app-name-mapping.json -e uat -t function-app"
  exit 1
}

# Parse command-line arguments
while getopts ":f:e:t:h" opt; do
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
    h )
      usage
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
  echo "Error: Missing required arguments."
  usage
fi

# Validate resource type
if [ "$RESOURCE_TYPE" == "app-service" ]; then
    CLI_CMD="webapp"
    RESOURCE_TYPE_FULL="Microsoft.Web/sites"
elif [ "$RESOURCE_TYPE" == "function-app" ]; then
    CLI_CMD="functionapp"
    RESOURCE_TYPE_FULL="Microsoft.Web/sites"
else
    echo "Error: Invalid resource type. Must be 'app-service' or 'function-app'."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to use this script."
    echo "  macOS: brew install jq"
    echo "  Ubuntu/Debian: apt-get install jq"
    exit 1
fi

# Check if mapping file exists
if [ ! -f "$MAPPING_FILE" ]; then
    echo "Error: Mapping file not found: $MAPPING_FILE"
    exit 1
fi

# Extract the mapping for the specified environment
MAPPINGS=$(jq -r ".${ENVIRONMENT} // {}" "$MAPPING_FILE")

if [ "$MAPPINGS" == "{}" ]; then
    echo "Error: No mappings found for environment: $ENVIRONMENT"
    exit 1
fi

echo "======================================"
echo "Migrating Diagnostic Settings"
echo "======================================"
echo "Environment: $ENVIRONMENT"
echo "Resource Type: $RESOURCE_TYPE"
echo "Mapping File: $MAPPING_FILE"
echo ""

# Counter for statistics
TOTAL_COUNT=0
SUCCESS_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

# Iterate through each mapping
echo "$MAPPINGS" | jq -r 'to_entries[] | "\(.key)|\(.value)"' | while IFS='|' read -r SOURCE_NAME TARGET_NAME; do
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    
    echo "----------------------------------------"
    echo "Processing: $SOURCE_NAME -> $TARGET_NAME"
    
    # Get source resource ID
    SOURCE_ID=$(az $CLI_CMD list --query "[?name=='$SOURCE_NAME'].id | [0]" -o tsv 2>/dev/null)
    
    if [ -z "$SOURCE_ID" ] || [ "$SOURCE_ID" == "null" ]; then
        echo "  ⚠️  Source not found: $SOURCE_NAME"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Get target resource ID
    TARGET_ID=$(az $CLI_CMD list --query "[?name=='$TARGET_NAME'].id | [0]" -o tsv 2>/dev/null)
    
    if [ -z "$TARGET_ID" ] || [ "$TARGET_ID" == "null" ]; then
        echo "  ⚠️  Target not found: $TARGET_NAME"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Get diagnostic settings from source
    DIAG_SETTINGS=$(az monitor diagnostic-settings list --resource "$SOURCE_ID" 2>/dev/null)
    
    if [ -z "$DIAG_SETTINGS" ] || [ "$DIAG_SETTINGS" == "[]" ]; then
        echo "  ℹ️  No diagnostic settings found on source, skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Count how many diagnostic settings exist
    SETTING_COUNT=$(echo "$DIAG_SETTINGS" | jq 'length')
    echo "  Found $SETTING_COUNT diagnostic setting(s) on source"
    
    # Process each diagnostic setting
    for i in $(seq 0 $((SETTING_COUNT - 1))); do
        SETTING=$(echo "$DIAG_SETTINGS" | jq ".[$i]")
        SETTING_NAME=$(echo "$SETTING" | jq -r '.name')
        
        echo "  Processing diagnostic setting: $SETTING_NAME"
        
        # Extract configuration
        LOGS=$(echo "$SETTING" | jq -c '.logs // []')
        METRICS=$(echo "$SETTING" | jq -c '.metrics // []')
        WORKSPACE_ID=$(echo "$SETTING" | jq -r '.workspaceId // empty')
        STORAGE_ACCOUNT_ID=$(echo "$SETTING" | jq -r '.storageAccountId // empty')
        EVENT_HUB_AUTH_RULE_ID=$(echo "$SETTING" | jq -r '.eventHubAuthorizationRuleId // empty')
        EVENT_HUB_NAME=$(echo "$SETTING" | jq -r '.eventHubName // empty')
        
        # Build the create command
        CMD="az monitor diagnostic-settings create --name \"$SETTING_NAME\" --resource \"$TARGET_ID\""
        
        # Add logs if present
        if [ "$LOGS" != "[]" ] && [ "$LOGS" != "null" ]; then
            # Filter and format logs
            LOGS_FORMATTED=$(echo "$LOGS" | jq -c '[.[] | {category: .category, enabled: .enabled, retentionPolicy: {enabled: .retentionPolicy.enabled, days: .retentionPolicy.days}}]')
            CMD="$CMD --logs '$LOGS_FORMATTED'"
        fi
        
        # Add metrics if present
        if [ "$METRICS" != "[]" ] && [ "$METRICS" != "null" ]; then
            # Filter and format metrics
            METRICS_FORMATTED=$(echo "$METRICS" | jq -c '[.[] | {category: .category, enabled: .enabled, retentionPolicy: {enabled: .retentionPolicy.enabled, days: .retentionPolicy.days}}]')
            CMD="$CMD --metrics '$METRICS_FORMATTED'"
        fi
        
        # Add destinations
        if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
            CMD="$CMD --workspace \"$WORKSPACE_ID\""
        fi
        
        if [ -n "$STORAGE_ACCOUNT_ID" ] && [ "$STORAGE_ACCOUNT_ID" != "null" ]; then
            CMD="$CMD --storage-account \"$STORAGE_ACCOUNT_ID\""
        fi
        
        if [ -n "$EVENT_HUB_AUTH_RULE_ID" ] && [ "$EVENT_HUB_AUTH_RULE_ID" != "null" ]; then
            CMD="$CMD --event-hub-rule \"$EVENT_HUB_AUTH_RULE_ID\""
            
            if [ -n "$EVENT_HUB_NAME" ] && [ "$EVENT_HUB_NAME" != "null" ]; then
                CMD="$CMD --event-hub \"$EVENT_HUB_NAME\""
            fi
        fi
        
        # Execute the command
        echo "  Creating diagnostic setting on target..."
        eval "$CMD" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo "  ✅ Successfully migrated diagnostic setting: $SETTING_NAME"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "  ❌ Failed to create diagnostic setting: $SETTING_NAME"
            echo "  Command: $CMD"
            ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
    done
    
    echo ""
done

echo "======================================"
echo "Migration Summary"
echo "======================================"
echo "Total Mappings: $TOTAL_COUNT"
echo "Successfully Migrated: $SUCCESS_COUNT"
echo "Skipped (no settings or not found): $SKIP_COUNT"
echo "Errors: $ERROR_COUNT"
echo ""
echo "Migration completed!"
