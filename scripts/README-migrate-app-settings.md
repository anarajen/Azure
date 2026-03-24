# App Settings Migration Script

This script migrates Azure App Settings (environment variables) from a set of source resources to a set of target resources based on a name mapping file.

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [jq](https://stedolan.github.io/jq/download/)

You must be logged in to Azure via `az login` and have selected the subscription containing the resources.

## Usage

```bash
./migrate-app-settings.sh -f <mapping_file> -e <environment> -t <resource_type>
```

### Parameters

- `-f <mapping_file>`: (Required) Path to the JSON file containing the name mapping between old and new resources.
- `-e <environment>`: (Required) The environment to use from the mapping file (e.g., `dev`, `uat`, `prod`).
- `-t <resource_type>`: (Required) The type of Azure resource. Supported values are `app-service` and `function-app`.

### Examples

**Migrating App Service settings for the 'dev' environment:**

```bash
./migrate-app-settings.sh -f ../config/app-service-name-mapping.json -e dev -t app-service
```

**Migrating Function App settings for the 'uat' environment:**

```bash
./migrate-app-settings.sh -f ../config/function-app-name-mapping.json -e uat -t function-app
```
