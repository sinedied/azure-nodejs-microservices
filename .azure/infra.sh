#!/usr/bin/env bash
##############################################################################
# Usage: ./infra.sh <command> <project_name> [environment_name] [location]
# Creates or deletes the Azure infrastructure for this project.
##############################################################################
# Dependencies: Azure CLI, jq, perl
##############################################################################

set -e
cd $(dirname ${BASH_SOURCE[0]})
if [ -f ".settings" ]; then
  source .settings
fi

subcommand="${1}"
project_name="${2:-$project_name}"
environment="${environment:-prod}"
environment="${3:-$environment}"
location="${location:-eastus2}"
location="${4:-$location}"
resource_group_name=rg-${project_name}-${environment}

showUsage() {
  script_name="$(basename "$0")"
  echo "Usage: ./$script_name <command> <project_name> [environment_name] [location]"
  echo "Manages the Azure infrastructure for this project."
  echo
  echo "Commands:"
  echo "  create   Creates the infrastructure for this project."
  echo "  delete   Deletes the infrastructure for this project."
  echo "  cancel   Cancels the last infrastructure deployment."
  echo "  env      Retrieve settings for the target environment."
  echo
}

toLowerSnakeCase() {
  echo ${1} |
    perl -pe 's/([a-z\d])([A-Z]+)/$1_$2/g' |
    perl -pe 's/[ _-]+/_/g' |
    perl -ne 'print lc'
}

createSettings() {
  env_file=".${environment}.env"

  echo "# Generated settings for environment '${environment}'" > ${env_file}
  echo "# Do not edit this file manually!" >> ${env_file}
  echo >> ${env_file}
  echo $1 | jq -c '. | to_entries[] | [.key, .value.value, .value.type]' |

  # For each output, export the value to the env file and convert the key to
  # lower snake case.
  while IFS=$"\n" read -r output; do
    ouput_name=$(toLowerSnakeCase $(echo "$output" | jq -r '.[0]'))
    output_value=$(echo "$output" | jq -r '.[1] | @sh')
    if [ $(echo "$output" | jq -r '.[2]') == "Array" ]; then
      echo "${ouput_name}=(${output_value})" >> ${env_file}
    else
      echo "${ouput_name}=${output_value}" >> ${env_file}
    fi
  done
  echo "Settings for environment '${environment}' saved to '${env_file}'."
}

createInfrastructure() {
  echo "Preparing environment '${environment}' of project '${project_name}'..."
  az group create \
    --name ${resource_group_name} \
    --location ${location} \
    --tags project=${project_name} environment=${environment} managedBy=blue \
    --output none
  echo "Resource group '${resource_group_name}' ready."
  outputs=$( \
    az deployment group create \
      --resource-group ${resource_group_name} \
      --template-file infra/main.bicep \
      --name "deployment-${project_name}-${environment}-${location}" \
      --parameters projectName=${project_name} \
          environment=${environment} \
          location=${location} \
      --query properties.outputs \
      --mode Complete \
      --verbose
  )
  createSettings "${outputs}"
  retrieveSecrets
  # echo "${outputs}" > outputs.json
  echo "Environment '${environment}' of project '${project_name}' ready."
}

deleteInfrastructure() {
  echo "Deleting environment '${environment}' of project '${project_name}'..."
  az group delete --yes --name "rg-${project_name}-${environment}"
  echo "Environment '${environment}' of project '${project_name}' deleted."
}

cancelInfrastructureDeployment() {
  echo "Cancelling preparation of environment '${environment}' of project '${project_name}'..."
  az deployment group cancel \
    --resource-group ${resource_group_name} \
    --name "deployment-${project_name}-${environment}-${location}"
    --verbose
  echo "Preparation of '${environment}' of project '${project_name}' cancelled."
}

retrieveEnvironmentSettings() {
  echo "Retrieving settings for environment '${environment}' of project '${project_name}'..." 
  outputs=$( \
    az deployment group show \
      --resource-group ${resource_group_name} \
      --name "deployment-${project_name}-${environment}-${location}" \
      --query properties.outputs \
  )
  createSettings "${outputs}"
}

retrieveSecrets() {
  secrets_sep="### Secrets ###"
  source ".${environment}.env"

  echo "Retrieving secrets for environment '${environment}' of project '${project_name}'..."

  env_file=".${environment}.env"
  echo -e "\n${secrets_sep}\n" >> ${env_file}

  # Get registry credentials
  if [ ! -z "$registry_name" ]; then
    registry_username=$( \
      az acr credential show \
        --name ${registry_name} \
        --query "username" \
        --output tsv \
      )
    echo "registry_username=${registry_username}" >> ${env_file}

    registry_password=$( \
      az acr credential show \
        --name ${registry_name} \
        --query "passwords[0].value" \
        --output tsv \
      )
    echo "registry_password=${registry_password}" >> ${env_file}
  fi

  # TODO: retrieve other secrets (swa tokens, connection strings, etc.)

  echo "Secrets for environment '${environment}' saved to '${env_file}'."
}

if [ -z "$project_name" ]; then
  showUsage
  echo "Error: project name is required."
  exit 1
fi

case "$subcommand" in
  create)
    createInfrastructure
    ;;
  delete)
    deleteInfrastructure
    ;;
  cancel)
    cancelInfrastructureDeployment
    ;;
  env)
    retrieveEnvironmentSettings
    retrieveSecrets
    ;;
  *)
    showUsage
    echo "Error: unknown command '$subcommand'."
    exit 1
    ;;
esac
