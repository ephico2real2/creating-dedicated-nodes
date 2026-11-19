#!/usr/bin/env bash
#
# label-taint-nodes.sh [node ...]
# Run after `oc login`. Applies to each target node, in order:
#   1. labels   2. annotations   3. taints
# Prefilled from the IIOT node spec (node-role.kubernetes.io/iiot).
#
# Pick target nodes any of these ways:
#   ./label-taint-nodes.sh node1 node2 node3           # explicit args
#   ./label-taint-nodes.sh $(oc get nodes -l <sel> -o name)   # by selector
#   # or edit NODES[] below and run with no args
#
set -euo pipefail

# ---------- what to apply (edit as needed) ----------
# NODES=( node1 node2 node3 )   # optional default; pass nodes as args instead

LABELS=(
  "node-role.kubernetes.io/iiot=true"
)

ANNOTATIONS=(
  # "example.com/owner=kcs"      # add real node annotations here, or leave empty
)

# Eviction toggle -- SET IT HERE.
#   true  = apply NoExecute (evicts running pods that do not tolerate this key)
#   false = NoSchedule only (no eviction)
EVICT="${EVICT:-true}"

# How to handle an existing NoSchedule taint when EVICT=true:
#   false = keep BOTH NoSchedule + NoExecute on the node (default, safe)
#   true  = REPLACE it -> remove NoSchedule, leave only NoExecute
# (NoExecute already blocks new non-tolerating pods, so replacing loses nothing.)
REPLACE_NOSCHEDULE="${REPLACE_NOSCHEDULE:-false}"

TAINT_KEY="node-role.kubernetes.io/iiot"

# Build the apply list and the removal list.
TAINTS=( "${TAINT_KEY}:NoSchedule" )
TAINT_REMOVALS=()
if [[ "${EVICT}" == "true" ]]; then
  TAINTS+=( "${TAINT_KEY}:NoExecute" )
  echo ">> EVICT=true -> applying NoExecute (running non-tolerating pods will be evicted)"
  if [[ "${REPLACE_NOSCHEDULE}" == "true" ]]; then
    TAINTS=( "${TAINT_KEY}:NoExecute" )          # don't re-add NoSchedule
    TAINT_REMOVALS=( "${TAINT_KEY}:NoSchedule-" ) # strip any existing NoSchedule
    echo ">> REPLACE_NOSCHEDULE=true -> node will keep ONLY NoExecute"
  fi
fi
# ----------------------------------------------------

# args override the NODES[] array; strip a leading "node/" if piped from -o name
if [[ $# -gt 0 ]]; then NODES=( "$@" ); fi
NODES=( "${NODES[@]:-}" )          # tolerate NODES[] being commented out
NODES=( "${NODES[@]#node/}" )
# drop any empty element left behind
TMP=(); for n in "${NODES[@]}"; do [[ -n "$n" ]] && TMP+=( "$n" ); done; NODES=( "${TMP[@]:-}" )
if [[ ${#NODES[@]} -eq 0 || -z "${NODES[0]:-}" ]]; then
  echo "usage: $0 <node ...>   (or uncomment NODES[] in the script)"; exit 1
fi

echo ">> cluster: $(oc whoami --show-server)"
echo ">> nodes:   ${NODES[*]}"

for NODE in "${NODES[@]}"; do
  echo "== $NODE =="
  if ! oc get node "$NODE" >/dev/null 2>&1; then
    echo "!! $NODE not found — skipping"; continue
  fi

  # 1. labels first
  if [[ ${#LABELS[@]} -gt 0 ]]; then
    for L in "${LABELS[@]}"; do
      [[ -z "$L" ]] && continue
      oc label node "$NODE" "$L" --overwrite >/dev/null
      echo "   label   $L"
    done
  fi

  # 2. annotations second
  if [[ ${#ANNOTATIONS[@]} -gt 0 ]]; then
    for A in "${ANNOTATIONS[@]}"; do
      [[ -z "$A" ]] && continue
      oc annotate node "$NODE" "$A" --overwrite >/dev/null
      echo "   annot   $A"
    done
  fi

  # 3. taints last -- apply
  if [[ ${#TAINTS[@]} -gt 0 ]]; then
    for T in "${TAINTS[@]}"; do
      [[ -z "$T" ]] && continue
      oc adm taint node "$NODE" "$T" --overwrite >/dev/null
      echo "   taint   $T"
    done
  fi

  # 3b. taint removals (e.g. strip NoSchedule when REPLACE_NOSCHEDULE=true).
  #     A removal errors if the taint isn't present; that's fine.
  if [[ ${#TAINT_REMOVALS[@]} -gt 0 ]]; then
    for R in "${TAINT_REMOVALS[@]}"; do
      [[ -z "$R" ]] && continue
      if oc adm taint node "$NODE" "$R" >/dev/null 2>&1; then
        echo "   untaint $R"
      else
        echo "   untaint $R (none present)"
      fi
    done
  fi
done

echo ">> verify labels: oc get nodes -l node-role.kubernetes.io/iiot=true -L node-role.kubernetes.io/iiot"
echo ">> verify taints: oc describe node <node> | grep -i -A1 taint"
