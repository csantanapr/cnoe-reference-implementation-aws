#!/bin/bash
set -e -o pipefail

if [[ -z "${DOMAIN_NAME}" ]]; then
    read -p "Enter base domain name. For example, entering cnoe.io will set hostname to be keycloak.cnoe.io : " DOMAIN_NAME
fi

if [[ -z "${GITHUB_URL}" ]]; then
    read -p "Enter GitHub repository URL e.g. https://github.com/cnoe-io/reference-implementation-aws : " GITHUB_URL
    export GITHUB_URL
fi

export KEYCLOAK_DOMAIN_NAME="keycloak.${DOMAIN_NAME}"
export ADMIN_PASSWORD=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 48 | head -n 1)
export POSTGRES_PASSWORD=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 48 | head -n 1)
export USER1_PASSWORD=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 48 | head -n 1)

kubectl create ns keycloak || true
envsubst < secrets.yaml | kubectl apply -f -

envsubst < argo-app.yaml | kubectl apply -f -

echo "waiting for keycloak to be ready. may take a few minutes"
kubectl wait --for=jsonpath=.status.health.status=Healthy  --timeout=600s -f argo-app.yaml
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak  --timeout=120s

# Configure keycloak. Might be better to just import
kubectl port-forward -n keycloak svc/keycloak 8080:8080 > /dev/null 2>&1 &
pid=$!

envsubst < config-payloads/user-password.json > config-payloads/user-password-to-be-applied.json

# ensure port-forward is killed
trap '{
    rm config-payloads/user-password-to-be-applied.json || true
    kill $pid
}' EXIT

echo "waiting for port forward to be ready"
while ! nc -vz localhost 8080 > /dev/null 2>&1 ; do
    sleep 2
done

# Default token expires in one minute. May need to extend. very ugly
KEYCLOAK_TOKEN=$(curl -sS  --fail-with-body -X POST -H "Content-Type: application/x-www-form-urlencoded"\
  --data-urlencode "username=cnoe-admin" \
  --data-urlencode "password=${ADMIN_PASSWORD}" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  localhost:8080/realms/master/protocol/openid-connect/token | jq -e -r '.access_token')
echo "creating cnoe realm and groups"
curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/realm-payload.json \
  localhost:8080/admin/realms

# Create scope mapper
CLIENT_SCOPE_GROUPS_ID=$(curl -sS -H "Content-Type: application/json" -H "Authorization: bearer ${KEYCLOAK_TOKEN}" -X GET  localhost:8080/admin/realms/cnoe/client-scopes | jq -e -r  '.[] | select(.name == "groups") | .id')

curl -sS -H "Content-Type: application/json" -H "Authorization: bearer ${KEYCLOAK_TOKEN}" -X PUT  localhost:8080/admin/realms/cnoe/clients/${CLIENT_ID}/default-client-scopes/${CLIENT_SCOPE_GROUPS_ID}

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/group-mapper-payload.json \
  localhost:8080/admin/realms/cnoe/client-scopes/${CLIENT_SCOPE_GROUPS_ID}/protocol-mappers/models

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/client-scope-groups-payload.json \
  localhost:8080/admin/realms/cnoe/client-scopes

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/group-admin-payload.json \
  localhost:8080/admin/realms/cnoe/groups

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/group-base-user-payload.json \
  localhost:8080/admin/realms/cnoe/groups

echo "creating test users"
curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/user-user1.json \
  localhost:8080/admin/realms/cnoe/users

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X POST --data @config-payloads/user-user2.json \
  localhost:8080/admin/realms/cnoe/users

USER1ID=$(curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" 'localhost:8080/admin/realms/cnoe/users?lastName=one' | jq -r '.[0].id')
USER2ID=$(curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" 'localhost:8080/admin/realms/cnoe/users?lastName=two' | jq -r '.[0].id')

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X PUT --data @config-payloads/user-password-to-be-applied.json \
  localhost:8080/admin/realms/cnoe/users/${USER1ID}/reset-password

curl -sS -H "Content-Type: application/json" \
  -H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
  -X PUT --data @config-payloads/user-password-to-be-applied.json \
  localhost:8080/admin/realms/cnoe/users/${USER2ID}/reset-password

envsubst < ingress.yaml | kubectl apply -f -

echo "Your keycloak's realm will be avaialbe at: https://${KEYCLOAK_DOMAIN_NAME}/realms/cnoe"
