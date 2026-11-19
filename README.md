# creating-dedicated-nodes

Scripts to give a team its own **dedicated node pool inside a shared OpenShift
cluster**, pin that team's namespaces to it, and wire each namespace into an
external Argo CD.

Everything keys off a single label/taint: **`node-role.kubernetes.io/iiot`**
(swap `iiot` for any team name to reuse the pattern).

| Piece | Where | Value |
|-------|-------|-------|
| Node label | nodes | `node-role.kubernetes.io/iiot=true` |
| Node taint | nodes | `node-role.kubernetes.io/iiot:NoSchedule` (+ `:NoExecute`) |
| Namespace label (discovery) | namespaces | `node-role.kubernetes.io/iiot=true` |
| Namespace node-selector | namespaces | `node-role.kubernetes.io/iiot=true` |
| Namespace tolerations | namespaces | key `node-role.kubernetes.io/iiot`, `Exists`, NoSchedule + NoExecute |

The node-selector pins tenant pods **onto** the pool; the taint keeps everyone
else **off**; the tolerations let tenant pods survive the taint.

---

## Scenario: dedicated nodes for a team in a shared cluster

We run **one shared OpenShift cluster** for many teams. The **iiot** team needs
guaranteed, isolated capacity — but standing up a separate cluster (another
control plane, more ops, more cost) is overkill. Instead we carve out a
**dedicated node pool** for iiot *inside* the shared cluster.

The arrangement:

- A subset of worker nodes is labeled + tainted as the iiot pool
  (`node-role.kubernetes.io/iiot`).
- iiot's namespaces are pinned to that pool and tolerate its taint.
- No other team's workloads can schedule on those nodes; iiot's workloads
  schedule **nowhere else**.

### What this gives the iiot team

- **Guaranteed capacity** — their nodes aren't shared, so no noisy-neighbor
  CPU/memory contention from other teams.
- **Predictable placement** — everything in their namespaces lands on their
  hardware (useful for licensing, data locality, or specialized nodes).
- **Blast-radius containment** — a workload storm in iiot can't starve other
  teams, and vice versa.

### What it does NOT give (it's still a shared cluster)

- **Not a security boundary.** Same control plane, API server, and
  cluster-scoped resources. Node dedication is a *scheduling* boundary only —
  enforce the rest with RBAC, NetworkPolicy, ResourceQuota, and your compliance
  profiles.
- **Not kernel/tenant isolation** the way a separate cluster or VMs would give.

### Scaling to more teams

Repeat the pattern with a different key per pool
(`node-role.kubernetes.io/<team>`). Each team gets its own label + taint, its own
pinned namespaces, and its own Argo CD credentials — the same three scripts with
the key changed.

---

## Prerequisites

- `oc` logged in to the target cluster as cluster-admin.
- `openssl` and `jq` on PATH (used for token decode / previews).
- Run the whole flow **once per cluster**.

## Order of operations (per cluster)

```bash
oc login https://api.<cluster>.example.com:6443

# 0. scale the pool to the desired node count, then get the node names
oc scale machineset <machineset> -n openshift-machine-api --replicas=<N>
oc get nodes

# 1. prepare the node pool (label + taint)
./label-taint-nodes.sh <node1> <node2> ...

# 2. pin + tolerate the tenant namespaces
./setup-tenant-namespaces.sh <ns...> | <tenants-file>

# 3. generate one Argo CD cluster Secret per namespace
./gen-argocd-clusters.sh
```

Each step is idempotent (`--overwrite` everywhere) — safe to re-run.

---

## 0. Scale up the pool and get node names

First scale the MachineSet(s) backing the dedicated pool to the desired node
count. Find the MachineSets, then scale:

```bash
oc get machineset -n openshift-machine-api
oc scale machineset <machineset-name> -n openshift-machine-api --replicas=<N>
```

Wait for the new machines to join as nodes, then capture their names — these feed
step 1:

```bash
oc get machines -n openshift-machine-api -w     # watch them come up
oc get nodes                                    # node names once Ready
```

> Prefer scaling an existing/new MachineSet over adding nodes by hand so the pool
> is reproducible and the MachineSet can later carry the label + taint durably
> (see the note in step 1).

---

## Concepts: taints, tolerations, selectors — and why at the namespace level

### The three primitives

- **Taint** — a property on a **node** that *repels* pods. Format
  `key=value:effect` (value optional). Three effects:
  - `NoSchedule` — the scheduler won't place a non-tolerating pod here. Pods
    already running are left alone.
  - `PreferNoSchedule` — soft version; avoid if possible, but allowed.
  - `NoExecute` — **evicts** running non-tolerating pods *and* blocks new ones.
- **Toleration** — a property on a **pod** that lets it be placed on a node
  with a matching taint. It matches on `key` + `effect`, with an `operator`:
  - `Exists` — matches the key regardless of value (what we use, since our taint
    has no value).
  - `Equal` — key *and* `value` must match.
  - Optional `tolerationSeconds` (NoExecute only) = grace period before eviction;
    **omitted = tolerate forever**, which is what tenant pods want.
- **Node-selector** — pins a pod *onto* nodes that carry a matching **label**.

### Taint ≠ pinning — you need both

A taint only *repels* non-tolerating pods; it does **not** force your pods onto
the pool. A toleration only *permits* a pod on tainted nodes; it doesn't pull it
there either. The **node-selector** is what pins tenant pods onto the IIOT
nodes. So the dedicated-pool guarantee is the combination:

| Goal | Mechanism |
|------|-----------|
| Keep *other* workloads OFF the pool | **taint** on the nodes |
| Let tenant pods survive the taint | **toleration** on the pods |
| Force tenant pods ONTO the pool | **node-selector** on the pods |

### Why we apply this at the NAMESPACE level (not per pod)

OpenShift lets you set a project-wide node-selector and default tolerations as
**namespace annotations**:

- `openshift.io/node-selector` → injected into every pod in the namespace
- `scheduler.alpha.kubernetes.io/defaultTolerations` → ditto

Admission plugins (`PodNodeSelector`, `PodTolerationRestriction`) stamp these
onto every pod created in the namespace automatically. Doing it here instead of
in each workload means:

1. **Tenants don't change their manifests.** Deployments/Helm charts work as-is —
   no per-pod `nodeSelector`/`tolerations` edits across dozens of workloads.
2. **It can't be forgotten or bypassed.** Every pod — Deployments, Jobs, operator
   pods, one-off debug pods — is covered. The namespace node-selector is a hard
   override: a pod can further *narrow* it but can't escape the pool.
3. **Consistency + auditability.** One place to see and enforce where a tenant
   runs; `oc get ns -l node-role.kubernetes.io/iiot=true` is the inventory.
4. **Isolation in a shared cluster.** Combined with the node taint, tenant
   workloads land only on their pool and nothing else lands there.

The cost: tolerations are namespace-wide, so every pod in the namespace tolerates
the pool taint — which is exactly the intent (the whole namespace is dedicated to
that pool).

---

## 1. `label-taint-nodes.sh` — prepare the node pool

Labels and taints the nodes from step 0, in order:
**labels → annotations → taints**.

### Run

```bash
./label-taint-nodes.sh node1 node2 node3
# or target by selector:
./label-taint-nodes.sh $(oc get nodes -l node-role.kubernetes.io/worker -o name)
```

Nodes come from args. (You can also uncomment the `NODES=(...)` default inside.)

### Config knobs (top of script)

| Var | Default | Effect |
|-----|---------|--------|
| `EVICT` | `true` | Also apply **`NoExecute`** — evicts running pods that don't tolerate the key. `false` = NoSchedule only (no eviction). |
| `REPLACE_NOSCHEDULE` | `false` | `true` = strip the NoSchedule taint, leave **only** NoExecute. `false` = keep both. |

Override per run: `EVICT=false ./label-taint-nodes.sh node1`

### ⚠ Before running with `EVICT=true`

NoExecute evicts **immediately**. Preview what would be removed first:

```bash
oc adm drain <node> --dry-run=client --ignore-daemonsets --delete-emptydir-data
```

If that list is only the pods you mean to clear, proceed. Make sure tenant
namespaces are already set up (step 2) **or** that no tenant pods are on the
node yet, or they'll be evicted too.

### Verify

```bash
oc get nodes -l node-role.kubernetes.io/iiot=true -L node-role.kubernetes.io/iiot
oc describe node <node> | grep -i -A1 taint
```

> **Durability:** labels/taints set with `oc` are **lost when a node is
> reprovisioned**. For permanence, set the same label + taint on the
> **MachineSet** (`spec.template.spec.metadata.labels` and
> `spec.template.spec.taints`). This script is for existing nodes / quick fixes.

---

## 2. `setup-tenant-namespaces.sh` — pin + tolerate namespaces

For each namespace, applies the discovery **label**, the **node-selector**
annotation, and **tolerations** for both taint effects.

### Run

```bash
./setup-tenant-namespaces.sh i21-dev i21-stage            # inline
./setup-tenant-namespaces.sh tenants-nonprod-clt.ns       # from a file
./setup-tenant-namespaces.sh tenants.ns i21-extra         # mix both
```

Each argument that is a **file** is read line-by-line (blank lines and `#`
comments ignored); anything else is treated as a literal namespace. The list is
de-duplicated.

Tenant file format (one per line):

```
# tenants-nonprod-clt.ns
i21-dev
i21-stage
```

### Config knobs

| Var | Default | Effect |
|-----|---------|--------|
| `NODE_ROLE_KEY` | `node-role.kubernetes.io/iiot` | Must equal the node taint/label key from step 1. |
| `NODE_ROLE_VALUE` | `true` | Node label value the node-selector matches. |
| `CREATE_IF_MISSING` | `true` | Create the namespace if it doesn't exist. |

Tolerations use **`operator: Exists`** (the node taint has no value) and cover
**both** NoSchedule and NoExecute, with **no `tolerationSeconds`** — so tenant
pods tolerate the pool forever and are never evicted by the taint.

### Verify

```bash
oc get ns -l node-role.kubernetes.io/iiot=true
oc get ns i21-dev -o jsonpath='{.metadata.annotations}' | jq
```

---

## 3. `gen-argocd-clusters.sh` — Argo CD secrets per namespace

Discovers the tenant namespaces (`-l node-role.kubernetes.io/iiot=true`) and,
**for each namespace**, creates:

1. ServiceAccount `argocd-deployer`
2. RoleBinding → `admin` (namespace-scoped)
3. A **non-expiring** token Secret (`kubernetes.io/service-account-token`)

then writes an Argo CD **cluster Secret** per namespace to `./argocd-clusters/`:

```
argocd-clusters/<cluster-id>-<namespace>.yaml
```

### Run

```bash
./gen-argocd-clusters.sh                          # argocd namespace defaults to "argocd"
./gen-argocd-clusters.sh -n openshift-gitops      # override the Argo CD namespace
ARGOCD_NS=openshift-gitops ./gen-argocd-clusters.sh   # ...or via env
```

Overridable inputs (flag or env): `-n/--argocd-ns` (`ARGOCD_NS`),
`-s/--selector` (`TENANT_SELECTOR`), `-o/--out-dir` (`OUT_DIR`).

`server` and the cluster-id are **auto-detected** from `oc whoami --show-server`
— you don't type the URL. Each namespace's token + CA is **verified against the
server** before its file is written. CA for `caData` is taken from the kubeconfig
you logged in with, falling back to the SA secret's `ca.crt`.

### Output: one Secret per namespace

Each Secret has a unique `name` (`<cluster>-<ns>`), the same `server`, that
namespace's own token, and is scoped with `namespaces: <ns>` +
`clusterResources: "false"` — so one tenant's credential can't touch another's.

### Argo CD cluster Secret — format & label (official)

Argo CD registers an external cluster declaratively as a Kubernetes **Secret** in
the `argocd` namespace, identified by the label
`argocd.argoproj.io/secret-type: cluster`. This is what the generated files use
(`name` and `server` are **auto-filled by the script — not edited by hand**):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <cluster>-i21-dev               # auto-filled: <cluster-id>-<namespace>
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster   # <-- required label
stringData:
  name: <cluster>-i21-dev               # auto-filled (display name in the UI)
  server: https://api.<cluster>.example.com:6443   # auto-detected from oc login
  namespaces: i21-dev                   # scope: only this namespace
  clusterResources: "false"             # no cluster-scoped access
  config: |
    {
      "bearerToken": "<SA token>",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64 CA>"
      }
    }
```

Field reference:

| Field | Purpose |
|-------|---------|
| `metadata.labels[argocd.argoproj.io/secret-type]` | Must be `cluster` — how Argo CD recognizes it as a cluster. |
| `stringData.name` | Human-readable cluster name in the UI. |
| `stringData.server` | Target API server URL. |
| `stringData.config.bearerToken` | The ServiceAccount token (from step 3). |
| `stringData.config.tlsClientConfig.caData` | Base64 CA that validates `server`. |
| `stringData.namespaces` | Comma-separated namespaces this credential may manage (scoping). |
| `stringData.clusterResources` | `"false"` to deny cluster-scoped resource access. |

Docs:
- Declarative clusters: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters
- External cluster credentials: https://argo-cd.readthedocs.io/en/stable/operator-manual/security/#external-cluster-credentials

### Apply to Argo CD

Pointed at your external Argo CD cluster:

```bash
oc apply -f ./argocd-clusters/ -n argocd

# confirm Argo CD picked them up (lists cluster secrets):
oc get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
```

> **Tokens never expire.** OpenShift caps `oc create token` at 1 year, so these
> use the legacy Secret-based token, which has no `exp`. Store them only in Argo
> CD's secret store, never in git. Rotate by deleting + recreating the token
> Secret, then re-applying the cluster Secret.
>
> **RBAC scope:** binds namespace `admin`. If a tenant's apps carry
> cluster-scoped resources (CRDs/ClusterRoles), that namespace needs a
> ClusterRoleBinding instead.
>
> **Reachability:** the external Argo CD must be able to reach the cluster API.

---

## Full example — one cluster

```bash
oc login https://api.<cluster>.example.com:6443

# 0. scale the pool and grab node names
oc scale machineset <machineset> -n openshift-machine-api --replicas=2
oc get nodes

# 1. pool: label + taint (NoSchedule + NoExecute) the dedicated nodes
./label-taint-nodes.sh worker-iiot-0 worker-iiot-1

# 2. namespaces: pin to the pool + tolerate the taint
./setup-tenant-namespaces.sh tenants-nonprod-clt.ns

# 3. Argo CD: one scoped cluster Secret per namespace
./gen-argocd-clusters.sh

# then, against the Argo CD cluster:
oc apply -f ./argocd-clusters/ -n argocd
```

Repeat for each cluster (new `oc login`, its own tenants file).
