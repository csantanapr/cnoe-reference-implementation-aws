#!/bin/bash
set -e -o pipefail

source ./utils.sh

REPO_ROOT=$(git rev-parse --show-toplevel)
cd ${REPO_ROOT}/setups
env_file=${REPO_ROOT}/setups/config

while IFS='=' read -r key value; do
  [[ $key == \#* ]] && continue
  export "$key"="$value"
done < $env_file

if [[ ! -z "${GITHUB_URL}" ]]; then
    export GITHUB_URL=$(strip_trailing_slash "${GITHUB_URL}")
fi

if [[ ! -z "${DOMAIN_NAME}" ]]; then
    export DOMAIN_NAME=$(get_cleaned_domain_name "${DOMAIN_NAME}")
fi

env_vars=("GITHUB_URL" "DOMAIN_NAME" "BACKSTAGE_SSO_ENABLED" "ARGO_SSO_ENABLED" "CLUSTER_NAME" "REGION" "MANAGED_CERT_DNS" "HOSTEDZONE_ID")

echo -e "${GREEN}Installing with the following options: ${NC}"
for env_var in "${env_vars[@]}"; do
  echo -e "${env_var}: ${!env_var}"
done

echo -e "${PURPLE}\nTargets:${NC}"
echo "Kubernetes cluster: $(kubectl config current-context)"
echo "AWS profile (if set): ${AWS_PROFILE}"
echo "AWS account number: $(aws sts get-caller-identity --query "Account" --output text)"

echo -e "${GREEN}\nAre you sure you want to continue?${NC}"
read -p '(yes/no): ' response
if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
  echo 'exiting.'
  exit 0
fi

if [[ "${MANAGED_CERT_DNS}" == "true" ]]; then
  ./full-install.sh
  exit
fi
