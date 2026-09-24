# teleport-workload-identity-k8s

Turn a Kubernetes cluster into a SPIFFE identity issuer backed by Teleport. Any pod can
ask a socket on its node "who am I?" and get back a signed, short-lived identity computed
from its namespace and ServiceAccount:

```
spiffe://<your-teleport-cluster>/svc/<namespace>/<serviceaccount>
```

No per-workload configuration, no stored secret, and the same manifests for every
cluster. Verified on k3s, Talos and Amazon EKS against Teleport 18.11.1 (Enterprise).

## Why this matters

- **Identity is computed, not configured.** The pod's manifest names no identity. The
  node's kubelet attests the namespace and ServiceAccount, and Teleport renders them into
  the ID. A pod cannot claim to be `payments` from inside `analytics`, because the
  namespace is not the pod's to choose.
- **There is no secret to steal or rotate.** The issuer joins Teleport with its own
  Kubernetes ServiceAccount token. X.509 certificates last one hour, JWTs fifteen
  minutes, and both renew automatically.
- **One resource governs every cluster.** Adding a cluster is one bot and one token.
  Changing the shape of the ID is one edit on the Teleport side, and every issuer follows
  on its next request.

## The components

| Component | Where it runs | What it does | File |
|---|---|---|---|
| `workload_identity` resource | Teleport | The identity template: the ID path, the lifetimes, the extra JWT claims, and the rule that the caller must be attested by a kubelet. One per Teleport cluster. | `teleport/workload-identity-svc.yaml` |
| Issuer role | Teleport | Lets a bot issue identities carrying the label `tier: svc`, and nothing else in Teleport. | `teleport/role-workload-identity-issuer.yaml` |
| Bot and join token | Teleport | One bot per Kubernetes cluster, named after it. The token holds the cluster's public signing keys, so the issuer pods join with their own ServiceAccount token and nothing is distributed to the node. | `scripts/make-token.sh` |
| `tbot` DaemonSet | every node, namespace `teleport-wi` | The issuer. Serves the SPIFFE Workload API on a Unix socket, works out which pod is calling, and asks Teleport to sign that pod's identity. | `k8s/daemonset.yaml`, `k8s/configmap.yaml` |
| SPIFFE CSI driver | every node, namespace `teleport-wi` | Mounts the socket into any pod that declares a `csi.spiffe.io` volume, so workload namespaces need no special privileges. | `k8s/csi-driver.yaml` |
| Your pod | any namespace | Mounts the volume and asks the socket, using any SPIFFE client library or the SPIRE command line. | your manifest |

Three terms, defined once. **SPIFFE** (Secure Production Identity Framework For Everyone)
is the open standard for workload identity. An **SVID** (SPIFFE Verifiable Identity
Document) is the identity as a credential: an X.509 certificate for mutual TLS, or a JWT
for systems that speak OpenID Connect such as AWS. The **Workload API** is the socket a
pod asks for its SVIDs. Six more terms in ten minutes: [docs/concepts.md](docs/concepts.md).

## How an identity is issued

```
 pod ──(1) ask──► tbot on the same node ──(3) attested facts──► Teleport Auth ──(4) signed SVIDs──► pod
                        │
                        └─(2) who is calling? process ID → cgroup → pod → this node's kubelet
```

1. The pod connects to the Workload API socket and asks for its SVIDs.
2. tbot resolves the calling process to a pod through its cgroup, then asks this node's
   kubelet for the pod's namespace, ServiceAccount, name and labels. It can only attest
   pods on its own node, which is why it runs as a DaemonSet with `hostPID`.
3. tbot forwards the attested facts to the Teleport Auth Service over its bot certificate.
4. The Auth Service finds the `workload_identity` resources the bot's role allows, checks
   the rule (`workload.kubernetes.attested` is `true`), renders the template, and signs.
   tbot never holds a signing key.
5. The pod receives an X.509 SVID, a JWT SVID on request, and the trust bundle. Its client
   library renews them in the background.

The trust model in one sentence: the node attests, Teleport decides and signs, and a
compromised node can mint identities only for pods that really run on it.

The template, as shipped:

```yaml
spec:
  spiffe:
    id: /svc/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}
    hint: "{{ user.bot_name }}"                       # which cluster's issuer minted it
    x509: { maximum_ttl: 3600s }
    jwt:
      maximum_ttl: 900s
      extra_claims:
        kube: { cluster: "{{ user.bot_name }}", namespace: "{{ workload.kubernetes.namespace }}", pod: "{{ workload.kubernetes.pod_name }}" }
  rules:
    allow:
      - conditions: [{ attribute: workload.kubernetes.attested, eq: { value: "true" } }]
```

Why the path is `/svc/<namespace>/<serviceaccount>`, with the cluster as a hint and a
claim rather than part of the ID: [docs/spiffe-id-structure.md](docs/spiffe-id-structure.md).

## Install

You need Teleport Enterprise 18.x with `tsh` and `tctl` logged in as `editor`, and
`kubectl` with cluster-admin on the target cluster. Replace `example.teleport.sh` with
your proxy and `k8s-prod` with a name for this Kubernetes cluster.

```bash
tsh login --proxy=example.teleport.sh:443

# Once per Teleport cluster: the identity template and the issuer role
tctl create --force -f teleport/workload-identity-svc.yaml
tctl create --force -f teleport/role-workload-identity-issuer.yaml

# Once per Kubernetes cluster: a join token built from the cluster's signing keys
# (read from your current kubectl context), and a bot named after the cluster
scripts/make-token.sh k8s-prod | tctl create --force -f -
tctl bots add k8s-prod --roles=workload-identity-issuer --token=k8s-prod-issuer

# The issuer: tbot and the CSI driver, one pod each per node
PROXY_ADDR=example.teleport.sh:443 TOKEN_NAME=k8s-prod-issuer scripts/render.sh | kubectl apply -f -
scripts/check.sh k8s-prod
```

`check.sh` prints one line per check. Green means every node runs a ready issuer, the
bot has one healthy instance per node, and the token still matches the cluster's
signing keys.

`render.sh` asks the proxy which tbot version to use. Set `TBOT_VERSION=18.11.1` to
skip that when your machine has no route to the proxy.

## Try it

Run a throwaway pod that asks for a JWT with the SPIRE command line. Nothing in this
manifest says who the pod is; only the ServiceAccount it runs as.

```bash
kubectl create namespace payments
kubectl -n payments create serviceaccount processor
kubectl -n payments apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: probe }
spec:
  serviceAccountName: processor
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: ghcr.io/spiffe/spire-agent:1.12.4
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
      command: ["/opt/spire/bin/spire-agent", "api", "fetch", "jwt",
                "-audience", "sts.amazonaws.com", "-socketPath", "/spiffe-workload-api/spiffe.sock"]
      volumeMounts: [{ name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true }]
  volumes:
    - name: spiffe-workload-api
      csi: { driver: csi.spiffe.io, readOnly: true }
EOF
kubectl -n payments wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=60s
kubectl -n payments logs probe
```

```
token(spiffe://example.teleport.sh/svc/payments/processor):
        eyJhbGciOiJSUzI1NiIs…
hint(spiffe://example.teleport.sh/svc/payments/processor):
        k8s-prod
```

Decode the token's middle segment and the claims read `"sub": "spiffe://…/svc/payments/processor"`
and `"kube": {"cluster": "k8s-prod", "namespace": "payments", "pod": "probe"}`. On the
issuer side, the matching log line shows what the kubelet attested:

```bash
kubectl -n teleport-wi logs ds/tbot | grep FetchJWTSVID | tail -1
# ... kubernetes:{attested:true namespace:"payments" service_account:"processor" pod_name:"probe" ...}
```

Now apply the identical pod in a namespace `analytics` with a ServiceAccount `processor`.
The log reads `token(spiffe://example.teleport.sh/svc/analytics/processor)`. Same
manifest, different identity, and nobody configured either one.

To see an identity used, for AWS access without a key and for mutual TLS between pods,
deploy [spiffe-whoami](https://github.com/jsabo/spiffe-whoami).

## 5-minute demo script

1. `kubectl -n payments get pod probe -o yaml | grep -ci secret` → "Zero. This pod holds no
   credential."
2. `kubectl -n payments logs probe` → "It asked a socket who it is and got a signed identity
   naming its namespace and ServiceAccount. Nothing in the manifest says that."
3. `tctl get workload_identity/svc` → "This one template is the policy for every pod in
   every cluster."
4. The same pod in `analytics` → "Different namespace, different identity, no
   configuration. It cannot claim to be payments."
5. `tctl bots instances ls` → "The issuer is itself a Teleport identity: one per node,
   joined with the pod's own ServiceAccount token."
6. `tctl lock --user=bot-k8s-prod --ttl=5m` → "Kill switch. Issuance on this cluster stops
   within one renewal."

## Security posture

Read this before installing on a cluster you care about.

| What | Why | Scope |
|---|---|---|
| `tbot` DaemonSet runs privileged with `hostPID` and `hostNetwork` | resolving a caller to its pod means reading that process's cgroup and querying this node's kubelet | namespace `teleport-wi` only |
| CSI driver DaemonSet runs privileged with `mountPropagation: Bidirectional` | standard for any CSI node plugin: it creates bind mounts the kubelet must see | `teleport-wi` only |
| `kubelet.skip_verify: true` | most distributions sign the kubelet's serving certificate from a CA the pod cannot see. The kubelet still authenticates tbot by its ServiceAccount token, and tbot only reads pod metadata. Set `false` and supply `ca_path` if your kubelets carry verifiable certificates | attestor only |
| Issuer role: label selector plus read on `workload_identity` | the bot can issue exactly the identities carrying `tier: svc` | one role, all issuer bots |
| `teleport-wi` labelled Pod Security `privileged` | the two DaemonSets above | workload namespaces stay `baseline` or `restricted`; the probe above passes `restricted` |

## Distributions

The manifests are identical everywhere. These are the facts that differ.

| Distribution | Verified | Notes |
|---|---|---|
| k3s | 1.31 | Runs as-is. If k3s itself runs in a container, `/var/lib/kubelet` must be a shared mount (`mount --make-rshared`, or a bind mount with `propagation: rshared`) or the CSI driver fails with "is mounted on /var/lib/kubelet but it is not a shared mount" |
| Talos | 1.13 | Enforces Pod Security `baseline` on every namespace, which forbids hostPath volumes. The CSI volume is what makes consumer pods work here; only `teleport-wi` carries the `privileged` label |
| Amazon EKS | 1.35 | Runs as-is. The cluster publishes many signing keys (14 measured); `make-token.sh` pins all of them |

## Troubleshooting

- `access denied to perform action "readnosecrets" on "workload_identity"` in the tbot log:
  the issuer role lacks `rules: [{resources: [workload_identity], verbs: [list, read]}]`.
  Re-apply `teleport/role-workload-identity-issuer.yaml`.
- `violates PodSecurity "baseline:latest": hostPath volumes` on a workload pod: use the
  `csi.spiffe.io` volume, not a hostPath.
- `is mounted on /var/lib/kubelet but it is not a shared mount` on the CSI driver pod: see
  the k3s row above.
- `invalid google.protobuf.Duration value "1h"` from `tctl create`: lifetimes are seconds
  with an `s` suffix (`3600s`).
- Issuer pods in `CrashLoopBackOff` after a cluster rebuild: the signing keys changed.
  `scripts/jwks.sh --check k8s-prod-issuer`, then
  `scripts/make-token.sh k8s-prod | tctl create --force -f -`.

## Day two

- **Add a cluster**: the two "once per Kubernetes cluster" steps and the render, with a
  new name. Nothing changes on the Teleport side.
- **Rotate**: nothing to do. SVIDs renew inside the client; a Teleport CA rotation reaches
  clients as an updated trust bundle over the Workload API.
- **Revoke an issuer**: `tctl lock --user=bot-<cluster>`. Issuance stops within one
  renewal; existing SVIDs run out at their lifetime.
- **Change the ID shape**: edit `teleport/workload-identity-svc.yaml` and `tctl create
  --force`. No tbot changes.
- **Location-bound identities**: `teleport/workload-identity-k8s-optional.yaml` adds a
  second identity, `/k8s/<cluster>/<namespace>/<serviceaccount>`, for policies that depend
  on where a workload runs. Off by default.
- **Versions**: tbot follows your Teleport cluster. The CSI driver (0.2.13) and its
  registrar (v2.18.0) are pinned in `scripts/render.sh`.

## License

Apache-2.0. The CSI driver manifest is adapted from
[spiffe/spiffe-csi](https://github.com/spiffe/spiffe-csi).
