#!/usr/bin/env bash
#
# setup-tenant-namespaces.sh <namespace ...> | <tenants-file> ...
#   ./setup-tenant-namespaces.sh i21-dev i21-stage          # namespaces inline
#   ./setup-tenant-namespaces.sh tenants-gp1-nonprod-clt.ns # from a file
#   ./setup-tenant-namespaces.sh tenants.ns i21-extra       # mix both
# Run AFTER `oc login` to the target OCP cluster. Runs BEFORE gen-argocd-clusters.sh.
#
# Pins each tenant namespace to the dedicated IIOT node pool and makes it
# discoverable by label. Per namespace it applies:
#   - label      node-role.kubernetes.io/iiot=true        (discovery + marker)
#   - annotation openshift.io/node-selector=node-role.kubernetes.io/iiot=true
#   - annotation scheduler.alpha.kubernetes.io/defaultTolerations
#                (key node-role.kubernetes.io/iiot, Exists, NoSchedule + NoExecute)
#
# These MATCH what label-taint-nodes.sh puts on the nodes:
#   label  node-role.kubernetes.io/iiot=true
#   taint  node-role.kubernetes.io/iiot:NoSchedule  (and :NoExecute when EVICT=true)
#
# tenants-file format: one namespace per line (blank lines + # comments ignored)
#   i21-dev
#   i21-stage
#   i21-prod
#
set -euo pipefail

# ---- must match the node label/taint key set by label-taint-nodes.sh ----
NODE_ROLE_KEY="node-role.kubernetes.io/iiot"
NODE_ROLE_VALUE="true"          # node LABEL value; the node-selector matches this
CREATE_IF_MISSING="true"        # create the namespace if it doesn't exist yet
# ------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <namespace ...> | <tenants-file> ...   (args and files can be mixed)"
  echo "  e.g. $0 i21-dev i21-stage"
  echo "       $0 tenants-gp1-nonprod-clt.ns"
  echo "       $0 tenants-gp1-nonprod-clt.ns i21-extra"
  exit 1
fi

# Gather namespaces: a file arg is read line-by-line, anything else is a literal ns.
NS_LIST=()
for arg in "$@"; do
  if [[ -f "$arg" ]]; then
    while read -r line _rest; do
      [[ -z "${line:-}" || "${line:0:1}" == "#" ]] && continue   # skip blanks/comments
      NS_LIST+=( "$line" )
    done < "$arg"
  else
    NS_LIST+=( "$arg" )
  fi
done

# de-duplicate, preserve order
DEDUP=()
for n in "${NS_LIST[@]}"; do
  seen=""
  for d in "${DEDUP[@]:-}"; do [[ "$d" == "$n" ]] && seen=1 && break; done
  [[ -z "$seen" ]] && DEDUP+=( "$n" )
done
NS_LIST=( "${DEDUP[@]}" )
[[ ${#NS_LIST[@]} -eq 0 ]] && { echo "no namespaces supplied"; exit 1; }

SELECTOR="${NODE_ROLE_KEY}=${NODE_ROLE_VALUE}"

# Tolerations use operator Exists because the node taint carries no value
# (node-role.kubernetes.io/iiot:NoSchedule). Covers BOTH effects so tenant pods
# survive a NoExecute (eviction) taint as well as NoSchedule.
TOL="[\
{\"key\":\"${NODE_ROLE_KEY}\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"},\
{\"key\":\"${NODE_ROLE_KEY}\",\"operator\":\"Exists\",\"effect\":\"NoExecute\"}]"

echo ">> cluster: $(oc whoami --show-server)"
echo ">> pinning tenants to pool: ${SELECTOR}"

for NS in "${NS_LIST[@]}"; do
  [[ -z "${NS:-}" ]] && continue

  # ensure the namespace exists
  if ! oc get ns "$NS" >/dev/null 2>&1; then
    if [[ "$CREATE_IF_MISSING" == "true" ]]; then
      oc create ns "$NS" >/dev/null && echo ">> [$NS] created"
    else
      echo "!! [$NS] missing and CREATE_IF_MISSING=false — skipping"; continue
    fi
  fi

  # 1. discovery/marker label (what gen-argocd-clusters.sh selects on)
  oc label ns "$NS" "${SELECTOR}" --overwrite >/dev/null

  # 2. project-wide node-selector -> pins this namespace's pods to the IIOT pool
  oc annotate ns "$NS" \
    "openshift.io/node-selector=${SELECTOR}" --overwrite >/dev/null

  # 3. default tolerations -> tolerate the pool taint, BOTH effects
  oc annotate ns "$NS" \
    "scheduler.alpha.kubernetes.io/defaultTolerations=${TOL}" --overwrite >/dev/null

  echo ">> [$NS] label+selector ${SELECTOR}  tolerations NoSchedule+NoExecute"
done

echo ">> done. Inventory: oc get ns -l ${SELECTOR}"
echo ">> nodes must carry label ${SELECTOR} and taint ${NODE_ROLE_KEY}:NoSchedule[/NoExecute]"
echo "   (set via label-taint-nodes.sh, or on the MachineSet for durability)."
