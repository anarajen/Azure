# Deployment Steps for Migrating App Services/Function Apps to ASEv3
# Pre-requisites:
## 1 Verify and create virtual network/subnet required
- Create subnet (minimum /26(64 -5 - IPs), recommendation is double the IP of the maximum scale)
- Create NAT gateway and attach to subnet 
## 2 Create Resource group and App Service Plan

## 3 Create deployment resource 
Example: 
```bash
# For app services
az deployment group create \
  --resource-group "UAT-ASE-PREM-RG" \
  --template-file templates/app-services-migration.bicep \
  --parameters @parameters/uat-app-service.parameters.json
# For function apps
az deployment group create \
  --resource-group "UAT-ASE-PREM-RG" \
  --template-file templates/function-apps-migration.bicep \
  --parameters @parameters/uat-function-app.parameters.json
```

## 4 Verify deployment status

## 5 Create hostname binding 
NO DNS CHANGE SHOULD HAPPEN AT THIS STAGE
Example:
```bash
  ./scripts/add-hostname-bindings.sh -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -c ABC123THUMBPRINT
  ```

## 6 Copy environment variable from old app service to new app service
Example:
```bash
# For app services
./scripts/migrate-app-settings.sh -f config/app-service-name-mapping.json -t app-service -e stg
# For function apps
 ./scripts/migrate-app-settings.sh -f config/function-app-name-mapping.json -t function-app  -e stg
```
### For temp slots, use the following script
```bash
  ./scripts/copy-slot-settings.sh -r DEV-ASE-PREM-RG
```


## 7 Extract and add new Azure RBAC permission from old to new service

Example:
```bash
# For app services
./scripts/migrate-role-assignments.sh -f config/app-service-name-mapping.json -t app-service -e dev 
# For function apps
./scripts/migrate-role-assignments.sh -f config/function-app-name-mapping.json -t function-app  -e dev 
```

## 8 Migrate healthcheck settings from old to new service

Example:
```bash
# For app services
./scripts/migrate-healthcheck.sh -f config/app-service-name-mapping.json -e dev -t app-service
# For function apps
./scripts/migrate-healthcheck.sh -f config/function-app-name-mapping.json -e dev -t function-app
```

## 9 For azure function apps only - Verify storage account related for trigger accept connection from outbound subnet

## 10 Migrate diagnostic settings from old to new service

Example:
```bash
# For app services
./scripts/migrate-diagnostic-settings.sh -f config/app-service-name-mapping.json -e dev -t app-service
# For function apps
./scripts/migrate-diagnostic-settings.sh -f config/function-app-name-mapping.json -e dev -t function-app
```

## 11 Create new backend pools for application gateway

## 12 Create new azure alerts base on the existing ones

## 13 Update deployment pipelines to point to new app services (new stage)

## 14 Deploy application AND stop the application (prevent listeners to handle messages)

## 15 Add other custom domain links (current deployment only add one as adding multiple at once is failing)
You will need to add the DNS validation records first in the DNS zone.
Example:
```bash
 ./scripts/add-dns-records.sh <parameter_file> <dns_zone_name> <resource_group> <verification_id> <app_type>
 ./scripts/add-dns-records.sh ./parameters/uat-app-service.parameters.json nonprod-krispay.com DEVUAT-ASE-RG 8CC27549A4FA33B749B26106EA73FFD896818391 appService
```

Then create the hostname bindings using the script below.
Example:
```bash
./scripts/add-hostname-bindings.sh -f <parameters-file> -r <resource-group> -t <type> [-s <subscription-id>] [-c <certificate-thumbprint>]
./scripts/add-hostname-bindings.sh -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -t webapp -c 8CC27549A4FA33B749B26106EA73FFD896818391
```

# CUT-OVER STEPS
## 16 Start new application
## 17 Update DNS to point to new ASEv3 application gateway
## 18 Update application gateway rules to point to new backend pools (If needed, not all applications have an application gateway rule)
## 19 Stop old applications
