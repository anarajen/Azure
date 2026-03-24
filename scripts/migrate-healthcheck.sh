#!/bin/bash

# Script to migrate healthcheck settings from source to target App Services/Function Apps
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
elif [ "$RESOURCE_TYPE" == "function-app" ]; then
    CLI_CMD="functionapp"
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
echo "Migrating Healthcheck Settings"
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
    
    # Get source resource group
    SOURCE_RG=$(az $CLI_CMD list --query "[?name=='$SOURCE_NAME'].resourceGroup | [0]" -o tsv 2>/dev/null)
    
    if [ -z "$SOURCE_RG" ] || [ "$SOURCE_RG" == "null" ]; then
        echo "  ⚠️  Source not found: $SOURCE_NAME"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Get target resource group
    TARGET_RG=$(az $CLI_CMD list --query "[?name=='$TARGET_NAME'].resourceGroup | [0]" -o tsv 2>/dev/null)
    
    if [ -z "$TARGET_RG" ] || [ "$TARGET_RG" == "null" ]; then
        echo "  ⚠️  Target not found: $TARGET_NAME"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Get healthcheck path from source
    HEALTHCHECK_PATH=$(az $CLI_CMD config show --name "$SOURCE_NAME" --resource-group "$SOURCE_RG" --query "healthCheckPath" -o tsv 2>/dev/null)
    
    if [ -z "$HEALTHCHECK_PATH" ] || [ "$HEALTHCHECK_PATH" == "null" ] || [ "$HEALTHCHECK_PATH" == "" ]; then
        echo "  ℹ️  No healthcheck configured on source, skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    echo "  Source RG: $SOURCE_RG"
    echo "  Target RG: $TARGET_RG"
    echo "  Healthcheck Path: $HEALTHCHECK_PATH"
    
    # Set healthcheck path on target
    echo "  Setting healthcheck on target..."
    
    RESULT=$(az $CLI_CMD config set --name "$TARGET_NAME" --resource-group "$TARGET_RG" --generic-configurations "{\"healthCheckPath\": \"$HEALTHCHECK_PATH\"}" 2>&1)
    
    if [ $? -eq 0 ]; then
        echo "  ✅ Successfully migrated healthcheck setting"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ❌ Failed to set healthcheck"
        echo "  Error: $RESULT"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    echo ""
done

echo "======================================"
echo "Migration Summary"
echo "======================================"
echo "Total Mappings: $TOTAL_COUNT"
echo "Successfully Migrated: $SUCCESS_COUNT"
echo "Skipped (no healthcheck or not found): $SKIP_COUNT"
echo "Errors: $ERROR_COUNT"
echo ""
echo "Migration completed!"
