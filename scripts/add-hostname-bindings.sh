#!/bin/bash

# Script to add hostname bindings to Azure App Services and Function Apps
# This script adds custom domain bindings to existing App Services or Function Apps
# Can read from a parameters JSON file or use command-line arguments

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
Usage: $0 -f <parameters-file> -r <resource-group> -t <type> [-s <subscription-id>] [-c <certificate-thumbprint>]

Options:
    -f    Parameters JSON file path (e.g., parameters/uat-app-service.parameters.json) (required)
    -r    Resource group name (required)
    -t    App type: webapp or functionapp (required)
    -s    Azure subscription ID (optional, uses current subscription if not specified)
    -c    Certificate thumbprint for SSL binding (optional)
    -h    Display this help message

Example:
    $0 -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -t webapp
    $0 -f parameters/dev-function-app.parameters.json -r DEV-ASE-PREM-RG -t functionapp
    $0 -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -t webapp -c ABC123... -s 12345678-1234-1234-1234-123456789012

EOF
    exit 1
}

# Parse command line arguments
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
CERTIFICATE_THUMBPRINT=""
PARAMETERS_FILE=""
APP_TYPE=""

while getopts "f:r:s:c:t:h" opt; do
    case $opt in
        f) PARAMETERS_FILE="$OPTARG" ;;
        r) RESOURCE_GROUP="$OPTARG" ;;
        s) SUBSCRIPTION_ID="$OPTARG" ;;
        c) CERTIFICATE_THUMBPRINT="$OPTARG" ;;
        t) APP_TYPE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [[ -z "$PARAMETERS_FILE" ]] || [[ -z "$RESOURCE_GROUP" ]] || [[ -z "$APP_TYPE" ]]; then
    print_error "Parameters -f (parameters file), -r (resource group), and -t (app type) are required"
    usage
fi

# Validate app type
if [[ "$APP_TYPE" != "webapp" ]] && [[ "$APP_TYPE" != "functionapp" ]]; then
    print_error "App type must be either 'webapp' or 'functionapp'"
    usage
fi

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    print_error "Parameters file not found: $PARAMETERS_FILE"
    exit 1
fi

# Set subscription if provided
if [[ -n "$SUBSCRIPTION_ID" ]]; then
    print_info "Setting subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
fi

# Get current subscription
CURRENT_SUB=$(az account show --query name -o tsv)
print_info "Using subscription: $CURRENT_SUB"

# Function to process a single app service or function app with domains
process_app_service() {
    local app_name="$1"
    local domains="$2"

    # Set the appropriate Azure CLI command prefix and parameter name based on app type
    local AZ_CMD
    local APP_TYPE_DISPLAY
    local NAME_PARAM
    if [[ "$APP_TYPE" == "functionapp" ]]; then
        AZ_CMD="functionapp"
        APP_TYPE_DISPLAY="Function App"
        NAME_PARAM="--name"
    else
        AZ_CMD="webapp"
        APP_TYPE_DISPLAY="App Service"
        NAME_PARAM="--webapp-name"
    fi

    print_info "========================================"
    print_info "Processing $APP_TYPE_DISPLAY: $app_name"
    print_info "========================================"

    # Verify the App Service/Function App exists
    print_info "Verifying $APP_TYPE_DISPLAY exists: $app_name"
    if ! az $AZ_CMD show --name "$app_name" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
        print_error "$APP_TYPE_DISPLAY '$app_name' not found in resource group '$RESOURCE_GROUP'"
        return 1
    fi
    print_success "$APP_TYPE_DISPLAY found: $app_name"
    
    # Convert comma-separated domains to array
    IFS=',' read -ra DOMAIN_ARRAY <<< "$domains"
    
    print_info "Processing ${#DOMAIN_ARRAY[@]} domain(s)"
    
    # Process each domain
    for domain in "${DOMAIN_ARRAY[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | xargs)
        
        print_info "Processing domain: $domain"
        
        # Check if hostname binding already exists
        print_info "Checking if hostname binding already exists..."
        EXISTING_BINDING=$(az $AZ_CMD config hostname list \
            --webapp-name "$app_name" \
            --resource-group "$RESOURCE_GROUP" \
            --query "[?name=='$domain'].name" -o tsv)

        if [[ -n "$EXISTING_BINDING" ]]; then
            print_warning "Hostname binding for '$domain' already exists, skipping..."
            continue
        fi

        # Add hostname binding
        print_info "Adding hostname binding for: $domain"
        if az $AZ_CMD config hostname add \
            $NAME_PARAM "$app_name" \
            --resource-group "$RESOURCE_GROUP" \
            --hostname "$domain" 2>&1 | tee /tmp/binding_output.txt; then
            print_success "Successfully added hostname binding for: $domain"
        else
            if grep -q "already exists" /tmp/binding_output.txt; then
                print_warning "Hostname binding for '$domain' already exists (detected from error)"
            else
                print_error "Failed to add hostname binding for: $domain"
                cat /tmp/binding_output.txt
                continue
            fi
        fi

        # Add SSL binding if certificate thumbprint is provided
        if [[ -n "$CERTIFICATE_THUMBPRINT" ]]; then
            print_info "Adding SSL binding for: $domain"
            if az $AZ_CMD config ssl bind \
                --certificate-thumbprint "$CERTIFICATE_THUMBPRINT" \
                --ssl-type SNI \
                --name "$app_name" \
                --resource-group "$RESOURCE_GROUP" 2>&1; then
                print_success "Successfully added SSL binding for: $domain"
            else
                print_error "Failed to add SSL binding for: $domain"
            fi
        fi
        
        # Add a small delay between operations to avoid throttling
        sleep 2
    done
    
    # Display final hostname configuration for this app service
    print_info "Current hostname configuration for $app_name:"
    az $AZ_CMD config hostname list \
        --webapp-name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --output table

    print_success "Completed processing: $app_name"
    echo ""
}

# Main processing logic
if [[ "$APP_TYPE" == "functionapp" ]]; then
    print_info "Reading function apps from: $PARAMETERS_FILE"
    PARAM_KEY="functionApps"
else
    print_info "Reading app services from: $PARAMETERS_FILE"
    PARAM_KEY="appServices"
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed. Please install jq first."
    print_info "macOS: brew install jq"
    print_info "Ubuntu/Debian: sudo apt-get install jq"
    exit 1
fi

# Extract app services or function apps array from the parameters file
APP_SERVICES_JSON=$(jq -r ".parameters.$PARAM_KEY.value" "$PARAMETERS_FILE")

if [[ "$APP_SERVICES_JSON" == "null" ]]; then
    print_error "Could not find $PARAM_KEY in parameters file"
    exit 1
fi

# Get the count of app services
APP_SERVICE_COUNT=$(echo "$APP_SERVICES_JSON" | jq 'length')
if [[ "$APP_TYPE" == "functionapp" ]]; then
    print_info "Found $APP_SERVICE_COUNT function app(s) to process"
else
    print_info "Found $APP_SERVICE_COUNT app service(s) to process"
fi

# Process each app service
for ((i=0; i<APP_SERVICE_COUNT; i++)); do
    APP_NAME=$(echo "$APP_SERVICES_JSON" | jq -r ".[$i].name")
    CUSTOM_DOMAINS=$(echo "$APP_SERVICES_JSON" | jq -r ".[$i].customDomains // [] | join(\",\")")

    if [[ -z "$CUSTOM_DOMAINS" ]] || [[ "$CUSTOM_DOMAINS" == "" ]] || [[ "$CUSTOM_DOMAINS" == "null" ]]; then
        print_warning "No custom domains found for $APP_NAME, skipping..."
        continue
    fi

    process_app_service "$APP_NAME" "$CUSTOM_DOMAINS"
    
    # Add delay between apps
    if [[ $i -lt $((APP_SERVICE_COUNT - 1)) ]]; then
        if [[ "$APP_TYPE" == "functionapp" ]]; then
            print_info "Waiting 5 seconds before processing next function app..."
        else
            print_info "Waiting 5 seconds before processing next app service..."
        fi
        sleep 5
    fi
done

if [[ "$APP_TYPE" == "functionapp" ]]; then
    print_success "All function apps processed!"
else
    print_success "All app services processed!"
fi

# Cleanup
rm -f /tmp/binding_output.txt
