# Azure App Service Premium Migration - ASE Isolated to Premium v3

Infrastructure-as-Code (Bicep) templates and migration scripts to move Azure App Services and Function Apps from App Service Environment (ASE) Isolated plans to **Premium v3** with full VNet integration, private endpoints, and NAT gateway-controlled outbound traffic.

## Why Migrate?

- **Cost Optimization**: Premium v3 is more cost-effective than ASE Isolated plans
- **Simplified Management**: No ASE infrastructure to manage
- **Better Scaling**: Flexible auto-scaling with elastic Premium plans
- **Same Network Isolation**: VNet integration + private endpoints replicate ASE-level isolation

## Network Architecture

The migration preserves network isolation by using VNet integration, private endpoints, and a NAT gateway to fully replace the ASE network boundary.

### VNet Integration and Outbound Traffic

All App Services and Function Apps are integrated into a dedicated **outbound subnet** within the VNet. With `vnetRouteAllEnabled: true`, **all outbound traffic** (including traffic to Azure services) is routed through the VNet instead of Azure's default shared infrastructure IPs.

A **NAT gateway** is attached to the outbound subnet, giving all apps a **static public IP** for outbound connections. This is critical for allowlisting on external services and firewalls.

```
App Service / Function App
        |
        v
  VNet Integration
  (virtualNetworkSubnetId -> OUTBOUND-SUBNET)
        |
        v
  Firewall NAT Gateway (static public IP)
        |
        v
  Internet / External Services / Azure PaaS
```

**Key settings:**
- `vnetRouteAllEnabled: true` -- routes all egress through VNet (not just RFC1918)
- `publicNetworkAccess: 'Disabled'` -- apps are unreachable from the public internet
- Subnet delegation: `Microsoft.Web/serverFarms`
- Subnet sizing: minimum /26 (59 usable IPs), recommended double the maximum scale instance count

### Private Endpoints (Inbound Access)

Since public access is disabled, apps are only reachable through **private endpoints** hosted in a separate subnet. A **private DNS zone** (`privatelink.azurewebsites.net`) resolves app hostnames to their private IPs within the VNet.

```
Client (within VNet / peered VNet)
        |
        v
  Private DNS Zone (privatelink.azurewebsites.net)
        |
        v
  Private Endpoint (in PE-SUBNET) -> App Service
```

Each app and each deployment slot (staging, temp) gets its own private endpoint and DNS registration.

### Network Components Summary

| Component | Example Name | Purpose |
|---|---|---|
| VNet | `DEVUAT-APP-VNET` | Shared infrastructure network |
| Outbound Subnet | `DEVUAT-ASE-OUTBOUND-SUBNET` (/26) | VNet integration for all apps |
| PE Subnet | `DEVUAT-ASE-SUBNET` | Hosts private endpoints |
| Firewall NAT Gateway | Attached to firewall | Static outbound IP for all egress |
| Private DNS Zone | `privatelink.azurewebsites.net` | Resolves app names to private IPs |
| SSL Certificate | Wildcard from Key Vault | Shared across all custom domains |

## Project Structure

```
templates/
  app-services-migration.bicep      # Main orchestrator for web apps
  app-service-module.bicep           # Single web app + PE + slots
  function-apps-migration.bicep      # Main orchestrator for function apps
  function-app-module.bicep          # Single function app + PE + slots
  certificate-import.bicep           # Import wildcard SSL cert from Key Vault
  domain-verification.bicep          # Custom domain hostname binding

parameters/
  {env}-app-service.parameters.json  # Per-environment web app definitions
  {env}-function-app.parameters.json # Per-environment function app definitions

config/
  app-service-name-mapping.json      # Old ASE name -> new Premium name (per env)
  function-app-name-mapping.json     # Same for function apps
  current-app-services-{env}.json    # Current ASE app configurations (reference)
  current-function-app-{env}.json    # Current ASE function app configs (reference)
  dns-current-*.json                 # Current DNS records (reference)

scripts/
  migrate-app-settings.sh           # Copy env vars from old to new apps
  migrate-role-assignments.sh       # Copy RBAC permissions
  migrate-healthcheck.sh            # Copy health check configuration
  migrate-diagnostic-settings.sh    # Copy Log Analytics diagnostic settings
  add-hostname-bindings.sh          # Add custom domain + SSL bindings
  add-dns-records.sh                # Add DNS TXT records for domain verification
  update-cname-records.sh           # Update CNAME records during cutover
  copy-slot-settings.sh             # Copy settings to deployment slots
```

## Deployment Steps

The migration follows a phased approach. Each step is detailed below with the corresponding commands.

### Pre-requisites

#### Step 1 -- Create VNet and Subnet

Create the outbound subnet (minimum /26, 64 IPs) that App Services will integrate with for outbound connectivity. Attach a **NAT gateway** to the subnet so all outbound traffic exits through a static public IP. This replaces the ASE's built-in outbound networking.

#### Step 2 -- Create Resource Group and App Service Plan

Create the target resource group and a **Premium v3** App Service Plan. All migrated apps will be hosted on this plan.

### Infrastructure Deployment

#### Step 3 -- Deploy App Services and Function Apps

Run the Bicep deployment to create the new app services (with VNet integration, private endpoints, deployment slots, and Application Insights) in a single deployment.

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

#### Step 4 -- Verify Deployment Status

Confirm all resources were created successfully. Check the Azure portal or use `az deployment group show` to verify.

#### Step 5 -- Add Hostname Bindings (First Domain)

Bind the primary custom domain with its SSL certificate to each app. **No DNS change should happen at this stage** -- this only prepares the app to accept traffic on the custom domain once DNS is switched later.

```bash
./scripts/add-hostname-bindings.sh -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -c ABC123THUMBPRINT
```

### Configuration Migration

#### Step 6 -- Migrate App Settings (Environment Variables)

Copy all application settings (connection strings, feature flags, secrets) from the old ASE apps to the new Premium v3 apps. The script reads a name-mapping file to match old and new app names. For deployment slots, use the slot copy script.

```bash
# For app services
./scripts/migrate-app-settings.sh -f config/app-service-name-mapping.json -t app-service -e stg

# For function apps
./scripts/migrate-app-settings.sh -f config/function-app-name-mapping.json -t function-app -e stg

# For deployment slots (e.g., temp)
./scripts/copy-slot-settings.sh -r DEV-ASE-PREM-RG
```

#### Step 7 -- Migrate RBAC Role Assignments

Extract all Azure RBAC role assignments from the old apps' managed identities and assign the same roles to the new apps' managed identities. This ensures the new apps have the same access to Key Vaults, storage accounts, databases, and other Azure resources.

```bash
# For app services
./scripts/migrate-role-assignments.sh -f config/app-service-name-mapping.json -t app-service -e dev

# For function apps
./scripts/migrate-role-assignments.sh -f config/function-app-name-mapping.json -t function-app -e dev
```

#### Step 8 -- Migrate Health Check Settings

Copy health check path and configuration from the old apps. App Service health checks monitor instance availability and automatically replace unhealthy instances.

```bash
# For app services
./scripts/migrate-healthcheck.sh -f config/app-service-name-mapping.json -e dev -t app-service

# For function apps
./scripts/migrate-healthcheck.sh -f config/function-app-name-mapping.json -e dev -t function-app
```

#### Step 9 -- Verify Storage Account Network Access (Function Apps Only)

For Azure Function Apps with storage-triggered bindings (Blob, Queue, Table), verify that the storage accounts accept connections from the new outbound subnet. Since all outbound traffic now exits via the NAT gateway / VNet, the storage account firewall must allowlist the outbound subnet or NAT gateway IP.

#### Step 10 -- Migrate Diagnostic Settings

Copy diagnostic settings (log categories, metrics, Log Analytics workspace links) from the old apps. This maintains observability and ensures logs continue flowing to the same workspace.

```bash
# For app services
./scripts/migrate-diagnostic-settings.sh -f config/app-service-name-mapping.json -e dev -t app-service

# For function apps
./scripts/migrate-diagnostic-settings.sh -f config/function-app-name-mapping.json -e dev -t function-app
```

### Pre-Cutover Preparation

#### Step 11 -- Create Application Gateway Backend Pools

Create new backend pools in the Application Gateway pointing to the new Premium v3 apps. These will be activated during cutover.

#### Step 12 -- Create Azure Alerts

Replicate existing Azure Monitor alert rules (availability, error rate, latency, etc.) for the new app services based on the existing ones.

#### Step 13 -- Update Deployment Pipelines

Add a new deployment stage in CI/CD pipelines targeting the new Premium v3 app services. Keep the old stage active until cutover is complete.

#### Step 14 -- Deploy Application and Stop It

Deploy the application code to the new apps but **keep them stopped**. This prevents message listeners, queue triggers, or timer triggers from processing messages before DNS cutover.

#### Step 15 -- Add Additional Custom Domains

If apps have multiple custom domains, add the remaining ones (the Bicep deployment only binds the first domain to avoid deployment conflicts). First add DNS TXT validation records, then create the hostname bindings.

```bash
# Add DNS TXT records for domain verification
./scripts/add-dns-records.sh ./parameters/uat-app-service.parameters.json nonprod-krispay.com DEVUAT-ASE-RG 8CC27549A4FA33B749B26106EA73FFD896818391 appService

# Add hostname bindings for additional domains
./scripts/add-hostname-bindings.sh -f parameters/uat-app-service.parameters.json -r UAT-ASE-PREM-RG -t webapp -c 8CC27549A4FA33B749B26106EA73FFD896818391
```

### Cutover

#### Step 16 -- Start New Applications

Start the new Premium v3 apps so they are ready to serve traffic.

#### Step 17 -- Update DNS

Switch DNS records (CNAME/A records) to point to the new ASEv3 Application Gateway or the new app default hostnames. This is the moment traffic begins flowing to the new infrastructure.

#### Step 18 -- Update Application Gateway Rules

If the apps are fronted by an Application Gateway, update routing rules to direct traffic to the new backend pools. Not all apps require this.

#### Step 19 -- Stop Old Applications

Once traffic is confirmed on the new apps and everything is stable, stop the old ASE-hosted applications.

## Template Parameters

### Main Parameters

| Parameter | Type | Description |
|---|---|---|
| `environment` | string | Environment name (dev, uat, stg, prod) |
| `location` | string | Azure region |
| `appServices` | array | Array of app definitions (name, plan, custom domains, tags) |
| `commonTags` | object | Tags applied to all resources |
| `virtualNetworkSubnetId` | string | Outbound subnet for VNet integration |
| `privateEndpointSubnetId` | string | Subnet hosting private endpoints |
| `privateDnsZoneResourceId` | string | Private DNS zone for `privatelink.azurewebsites.net` |
| `keyVaultResourceId` | string | Key Vault containing the wildcard SSL certificate |
| `certificateSecretName` | string | Name of the certificate secret in Key Vault |
| `appInsightsResourceId` | string | Application Insights instance resource ID |
| `logAnalyticsWorkspaceResourceId` | string | Log Analytics workspace for diagnostics |

## Scripts Reference

| Script | Purpose | Key Flags |
|---|---|---|
| `migrate-app-settings.sh` | Copy env vars from old to new apps | `-f` mapping file, `-e` env, `-t` type |
| `migrate-role-assignments.sh` | Copy RBAC role assignments | `-f` mapping file, `-e` env, `-t` type |
| `migrate-healthcheck.sh` | Copy health check config | `-f` mapping file, `-e` env, `-t` type |
| `migrate-diagnostic-settings.sh` | Copy diagnostic settings | `-f` mapping file, `-e` env, `-t` type |
| `add-hostname-bindings.sh` | Add custom domain + SSL | `-f` params file, `-r` RG, `-c` thumbprint |
| `add-dns-records.sh` | Add DNS TXT validation records | positional: params, zone, RG, verification ID, type |
| `copy-slot-settings.sh` | Copy settings to deployment slots | `-r` RG, `-t` target slot |
| `update-cname-records.sh` | Update DNS CNAME for cutover | -- |

## Troubleshooting

| Issue | Resolution |
|---|---|
| VNet integration fails | Verify subnet has delegation to `Microsoft.Web/serverFarms` and enough free IPs |
| App not reachable | Check private endpoint and DNS zone are correctly linked |
| Outbound connections fail | Verify NAT gateway is attached to outbound subnet and target service allows the NAT IP |
| Function App triggers don't fire | Ensure storage account firewall allows the outbound subnet (Step 9) |
| Multiple domain binding fails | Use the `add-hostname-bindings.sh` script post-deployment instead of Bicep |
| Invalid App Service Plan ID | Ensure the plan exists before deploying apps |

## Validation Commands

```bash
# Check app service status
az webapp show --name "your-app-name" --resource-group "your-resource-group"

# View deployment logs
az deployment group show --name "deployment-name" --resource-group "your-resource-group"

# Verify VNet integration
az webapp vnet-integration list --name "your-app-name" --resource-group "your-resource-group"

# Check private endpoints
az network private-endpoint list --resource-group "your-resource-group" -o table
```
