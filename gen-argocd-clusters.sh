#!/usr/bin/env bash
#
# gen-argocd-clusters.sh
# Run AFTER `oc login` to a target OCP cluster.
# For every i21-* namespace it:
#   1. creates ServiceAccount argocd-deployer
#   2. binds it namespace-admin
#   3. creates a NON-EXPIRING token secret
#   4. writes an ArgoCD cluster Secret (server + token + caData) to ./argocd-clusters/
#
# Run it once per cluster (4 logins). Output files accumulate, then you apply
# them all to your external ArgoCD cluster.
#
set -euo pipefail

SA_NAME="argocd-deployer"
# Discovery: the same label setup-tenant-namespaces.sh stamps on each tenant NS.
# TENANT_SELECTOR is passed straight to `oc get ns -l`.
TENANT_SELECTOR="node-role.kubernetes.io/iiot=true"
ARGOCD_NS="argocd"
OUT_DIR="./argocd-clusters"
mkdir -p "$OUT_DIR"

b64d() { openssl base64 -d -A; }   # portable base64 decode (Linux + macOS)

# --- current cluster ---
SERVER="$(oc whoami --show-server)"
# derive a short id from the api hostname:
#   https://api.gp1.nonprod-clt.k8s.boeing.com:6443 -> gp1-nonprod-clt
CLUSTER_ID="$(echo "$SERVER" | sed -E 's#https?://api\.##; s#\.k8s\.boeing\.com(:[0-9]+)?##; s#[.:]#-#g')"
echo ">> cluster=$CLUSTER_ID  server=$SERVER"

# --- CA that validates THIS endpoint: prefer the kubeconfig you logged in with ---
KUBECONFIG_CA_B64="$(oc config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
if [[ -z "$KUBECONFIG_CA_B64" ]]; then
  echo "!! kubeconfig has no embedded CA (system-trust login?)."
  echo "   Falling back to each SA secret's ca.crt — may NOT match a corporate-signed"
  echo "   external API cert. Verification step below will catch it."
fi

# --- discover tenant namespaces by label (same key as the node-selector) ---
NAMESPACES="$(oc get ns -l "$TENANT_SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)"
if [[ -z "$NAMESPACES" ]]; then
  echo "!! no namespaces matched selector '-l $TENANT_SELECTOR' on $CLUSTER_ID"; exit 1
fi
echo ">> namespaces (-l $TENANT_SELECTOR): $(echo "$NAMESPACES" | tr '\n' ' ')"

for NS in $NAMESPACES; do
  echo ">> [$NS] provisioning"

  # 1. ServiceAccount (idempotent)
  oc create sa "$SA_NAME" -n "$NS" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  # 2. RBAC — namespace admin. If the tenant's apps carry CLUSTER-SCOPED
  #    resources (CRDs/ClusterRoles), swap for a ClusterRoleBinding instead.
  oc create rolebinding "${SA_NAME}-admin" \
    --clusterrole=admin --serviceaccount="${NS}:${SA_NAME}" -n "$NS" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null

  # 3. Non-expiring token secret
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

  # wait for the token controller to populate .data.token
  TOKEN_B64=""
  for _ in $(seq 1 30); do
    TOKEN_B64="$(oc get secret "${SA_NAME}-token" -n "$NS" \
      -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [[ -n "$TOKEN_B64" ]] && break
    sleep 1
  done
  if [[ -z "$TOKEN_B64" ]]; then
    echo "!! [$NS] token not populated after 30s — skipping"; continue
  fi
  TOKEN="$(echo "$TOKEN_B64" | b64d)"

  # 4. choose caData: kubeconfig CA first, else SA secret ca.crt
  if [[ -n "$KUBECONFIG_CA_B64" ]]; then
    CA_B64="$KUBECONFIG_CA_B64"
  else
    CA_B64="$(oc get secret "${SA_NAME}-token" -n "$NS" -o jsonpath='{.data.ca\.crt}')"
  fi

  # verify token + CA actually authenticate to the EXTERNAL server
  if oc --server="$SERVER" --token="$TOKEN" \
        --certificate-authority=<(echo "$CA_B64" | b64d) \
        get ns "$NS" >/dev/null 2>&1; then
    echo "   [$NS] verified against $SERVER"
  else
    echo "!! [$NS] token/CA did NOT validate against $SERVER"
    echo "   (likely corporate CA mismatch — supply the right CA bundle manually)"
  fi

  # write the ArgoCD cluster Secret
  SECRET_NAME="${CLUSTER_ID}-${NS}"
  CONFIG_JSON="$(printf '{"bearerToken":"%s","tlsClientConfig":{"caData":"%s"}}' "$TOKEN" "$CA_B64")"
  cat > "${OUT_DIR}/${SECRET_NAME}.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: ${SECRET_NAME}
  server: ${SERVER}
  namespaces: ${NS}
  clusterResources: "false"
  config: |
    ${CONFIG_JSON}
EOF
  echo "   wrote ${OUT_DIR}/${SECRET_NAME}.yaml"
done

echo ">> done for $CLUSTER_ID. Files in ${OUT_DIR}/"
