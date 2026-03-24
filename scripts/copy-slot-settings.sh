#!/bin/bash

# Script to copy environment variables from production slot to temp slot
# for all Azure Function Apps and Web Apps in a resource group

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -r <resource-group> [-s <subscription-id>] [-t <target-slot>]

Options:
    -r    Resource group name (required)
    -s    Azure subscription ID (optional, uses current subscription if not specified)
    -t    Target slot name (optional, defaults to "temp")
    -h    Display this help message

Example:
    $0 -r DEV-ASE-PREM-RG
    $0 -r DEV-ASE-PREM-RG -t staging
    $0 -r DEV-ASE-PREM-RG -s 12345678-1234-1234-1234-123456789012

EOF
    exit 1
}

# Parse command line arguments
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
TARGET_SLOT="temp"

while getopts "r:s:t:h" opt; do
    case $opt in
        r) RESOURCE_GROUP="$OPTARG" ;;
        s) SUBSCRIPTION_ID="$OPTARG" ;;
        t) TARGET_SLOT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" ]]; then
    print_error "Resource group (-r) is required"
    usage
fi

# Set subscription if provided
if [[ -n "$SUBSCRIPTION_ID" ]]; then
    print_info "Setting subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
fi

# Get current subscription
CURRENT_SUB=$(az account show --query name -o tsv)
print_info "Using subscription: $CURRENT_SUB"
print_info "Resource group: $RESOURCE_GROUP"
print_info "Target slot: $TARGET_SLOT"
print_info "========================================"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed. Please install jq first."
    print_info "macOS: brew install jq"
    print_info "Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

# Function to copy settings from production to target slot
copy_slot_settings() {
    local app_name="$1"
    local app_type="$2"  # "webapp" or "functionapp"

    print_info "Processing $app_type: $app_name"

    # Check if the target slot exists
    print_info "  Checking if slot '$TARGET_SLOT' exists..."
    if ! az "$app_type" deployment slot list \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?name=='$TARGET_SLOT'].name" -o tsv 2>/dev/null | grep -q "$TARGET_SLOT"; then
        print_warning "  Slot '$TARGET_SLOT' does not exist for $app_name. Skipping..."
        return 0
    fi
    print_success "  Slot '$TARGET_SLOT' found"

    # Get settings from production slot
    print_info "  Fetching settings from production slot..."
    production_settings=$(az "$app_type" config appsettings list \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        -o json 2>/dev/null)

    if [ -z "$production_settings" ] || [ "$(echo "$production_settings" | jq 'length')" -eq 0 ]; then
        print_warning "  No settings found in production slot"
        return 0
    fi

    setting_count=$(echo "$production_settings" | jq 'length')
    print_info "  Found $setting_count settings in production slot"

    # Get existing settings from target slot
    print_info "  Fetching existing settings from '$TARGET_SLOT' slot..."
    target_settings=$(az "$app_type" config appsettings list \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --slot "$TARGET_SLOT" \
        --query "[].name" \
        -o json 2>/dev/null)

    # Prepare settings to apply
    settings_to_apply=()
    skipped_count=0

    while IFS= read -r setting_json; do
        name=$(echo "$setting_json" | jq -r '.name')
        value=$(echo "$setting_json" | jq -r '.value')

        # Skip slot-specific settings that shouldn't be copied
        if [[ "$name" == "WEBSITE_HOSTNAME" || "$name" == "WEBSITE_SLOT_NAME" ]]; then
            ((skipped_count++))
            continue
        fi

        # Add the setting to the list
        settings_to_apply+=("$name=$value")
    done < <(echo "$production_settings" | jq -c '.[]')

    if [ ${#settings_to_apply[@]} -eq 0 ]; then
        print_warning "  No settings to copy"
        return 0
    fi

    applied_count=${#settings_to_apply[@]}
    print_info "  Copying $applied_count settings to '$TARGET_SLOT' slot (skipped $skipped_count slot-specific settings)..."

    # Apply settings to target slot
    if az "$app_type" config appsettings set \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --slot "$TARGET_SLOT" \
        --settings "${settings_to_apply[@]}" \
        --output none 2>/dev/null; then
        print_success "  Successfully copied settings to '$TARGET_SLOT' slot"
        return 0
    else
        print_error "  Failed to copy settings to '$TARGET_SLOT' slot"
        return 1
    fi
}

# Initialize counters
total_apps=0
successful_apps=0
failed_apps=0
skipped_apps=0

# Process Web Apps
print_info ""
print_info "Searching for Web Apps in resource group '$RESOURCE_GROUP'..."
web_apps=$(az webapp list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null)

if [ -n "$web_apps" ]; then
    web_app_count=$(echo "$web_apps" | wc -l | xargs)
    print_info "Found $web_app_count Web App(s)"

    while IFS= read -r app_name; do
        if [ -n "$app_name" ]; then
            echo ""
            print_info "========================================"
            ((total_apps++))
            if copy_slot_settings "$app_name" "webapp"; then
                ((successful_apps++))
            else
                ((failed_apps++))
            fi
            print_info "========================================"
        fi
    done <<< "$web_apps"
else
    print_info "No Web Apps found in resource group"
fi

# Process Function Apps
print_info ""
print_info "Searching for Function Apps in resource group '$RESOURCE_GROUP'..."
function_apps=$(az functionapp list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null)

if [ -n "$function_apps" ]; then
    function_app_count=$(echo "$function_apps" | wc -l | xargs)
    print_info "Found $function_app_count Function App(s)"

    while IFS= read -r app_name; do
        if [ -n "$app_name" ]; then
            echo ""
            print_info "========================================"
            ((total_apps++))
            if copy_slot_settings "$app_name" "functionapp"; then
                ((successful_apps++))
            else
                ((failed_apps++))
            fi
            print_info "========================================"
        fi
    done <<< "$function_apps"
else
    print_info "No Function Apps found in resource group"
fi

# Print summary
echo ""
print_info "========================================"
print_info "SUMMARY"
print_info "========================================"
print_info "Total apps processed: $total_apps"
print_success "Successful: $successful_apps"
if [ $failed_apps -gt 0 ]; then
    print_error "Failed: $failed_apps"
fi
print_info "========================================"

if [ $failed_apps -eq 0 ] && [ $total_apps -gt 0 ]; then
    print_success "All slot settings copied successfully!"
    exit 0
elif [ $total_apps -eq 0 ]; then
    print_warning "No apps found to process"
    exit 0
else
    print_error "Some operations failed. Please review the output above."
    exit 1
fi
