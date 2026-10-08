#!/bin/bash
# Prepares the imported freva realm for the MLflow integration test.
#
# Runs inside the Keycloak container (run.sh pipes it into `bash -s`), so it
# only needs kcadm.sh. The shared realm export in keycloak/import/ is left
# untouched; everything MLflow needs is added here:
#
#   * an audience mapper, so access tokens carry aud=freva
#     (mlflow-oidc-auth only provisions bearer users from aud+iss scoped tokens)
#   * a group membership mapper that writes the groups into "mlflow_roles"
#   * the groups hpc-user (may use MLflow) and mlflow-admin
#   * johndoe -> hpc-user, alicebrown -> mlflow-admin, bobsmith -> none
set -euo pipefail

REALM="${REALM:-freva}"
CLIENT="${CLIENT:-freva}"
KC=/opt/keycloak/bin/kcadm.sh
CFG=(--config /tmp/kcadm.config)

# Wait until the admin API answers and the realm import has finished.
for attempt in $(seq 120); do
    if "$KC" config credentials "${CFG[@]}" --server http://localhost:8080 \
            --realm master --user "${KC_BOOTSTRAP_ADMIN_USERNAME}" \
            --password "${KC_BOOTSTRAP_ADMIN_PASSWORD}" >/dev/null 2>&1 \
       && "$KC" get "realms/${REALM}" "${CFG[@]}" >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 120 ]; then
        echo "Keycloak or realm ${REALM} not ready after 240s" >&2
        exit 1
    fi
    sleep 2
done
echo "Keycloak ready, realm ${REALM} imported"

client_id=$("$KC" get clients -r "$REALM" -q clientId="$CLIENT" \
    --fields id --format csv --noquotes "${CFG[@]}")

"$KC" create "clients/${client_id}/protocol-mappers/models" -r "$REALM" "${CFG[@]}" -f - <<EOF
{
  "name": "mlflow-audience",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "${CLIENT}",
    "access.token.claim": "true",
    "id.token.claim": "false"
  }
}
EOF

"$KC" create "clients/${client_id}/protocol-mappers/models" -r "$REALM" "${CFG[@]}" -f - <<'EOF'
{
  "name": "mlflow-groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "claim.name": "mlflow_roles",
    "full.path": "false",
    "access.token.claim": "true",
    "id.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}
EOF
echo "Added audience and group mappers to client ${CLIENT}"

add_to_group() {
    local user="$1" group_id="$2" user_id
    user_id=$("$KC" get users -r "$REALM" -q username="$user" -q exact=true \
        --fields id --format csv --noquotes "${CFG[@]}")
    "$KC" update "users/${user_id}/groups/${group_id}" -r "$REALM" \
        -s realm="$REALM" -s userId="$user_id" -s groupId="$group_id" -n "${CFG[@]}"
}

users_group=$("$KC" create groups -r "$REALM" -s name=hpc-user -i "${CFG[@]}")
admins_group=$("$KC" create groups -r "$REALM" -s name=mlflow-admin -i "${CFG[@]}")
add_to_group johndoe "$users_group"
add_to_group alicebrown "$admins_group"
echo "johndoe -> hpc-user, alicebrown -> mlflow-admin, bobsmith -> no group"
