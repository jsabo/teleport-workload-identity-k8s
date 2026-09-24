# teleport-workload-identity-k8s

Give every pod in a Kubernetes cluster a cryptographic identity, issued by Teleport, with
no per-workload configuration and no stored secret. One `tbot` DaemonSet turns the cluster
into a SPIFFE issuer; one `workload_identity` resource on the Teleport side says what the
identity looks like: `spiffe://<your-teleport-cluster>/svc/<namespace>/<serviceaccount>`,
computed at issuance from facts the node's kubelet attested. The same manifests and the
same resource serve your second cluster and your hundredth.

Verified against Teleport 18.11.1 (Enterprise Cloud) on k3s, Talos 1.13 and Amazon EKS
1.35 with identical manifests. Issuer join: 2 s. First identity for a new pod: under 1 s.

## What you will see

A pod that mounted one socket and asked, and got this back:

```
token(spiffe://example.teleport.sh/svc/payments/processor):
        eyJhbGciOiJSUzI1NiIs…            ← a 15-minute JWT: sub = the SPIFFE ID, aud = sts.amazonaws.com,
hint(spiffe://example.teleport.sh/svc/payments/processor):        kube.cluster/namespace/pod as extra claims
        k8s-prod                          ← which cluster's issuer minted it
```

Three facts carry the value:
- **Nothing named this identity.** The pod's manifest has no identity in it. The
  namespace and ServiceAccount were attested by the kubelet and rendered into the ID.
- **No secret exists anywhere.** Not in the pod, not in the issuer, not in Teleport's
  join token (which is a public key). Certificates last an hour, tokens fifteen minutes,
  both renewed automatically.
- **One resource, every cluster.** Adding a cluster is a bot and a token. Changing the ID
  structure is one edit on the Teleport side.

For the six terms this depends on (trust domain, SPIFFE ID, SVID, trust bundle, Workload
API, attestation), read [docs/concepts.md](docs/concepts.md); ten minutes.

## Before you start

- Teleport Enterprise 18.x (Cloud or self-hosted). Workload Identity is an Enterprise feature.
- `tsh` and `tctl` logged in with the `editor` preset (creates roles, bots, tokens).
- `kubectl` with cluster-admin on the cluster, once: the issuer needs a namespace, RBAC,
  and two privileged DaemonSets (see [Security posture](#security-posture)).
- Kubernetes 1.21+ with projected ServiceAccount tokens (every current distribution).
- Outbound HTTPS from your machine to the Teleport proxy (the render script asks it which
  tbot version to use; set `TBOT_VERSION=` to skip that).

## Quick start

Replace `example.teleport.sh` with your proxy and `k8s-prod` with a name for this
Kubernetes cluster. Everything else is as written. Point `kubectl` at the cluster first.

```bash
tsh login --proxy=example.teleport.sh:443

# 1. Once per Teleport cluster: the identity template and the issuer role (safe to re-run)
tctl create --force -f teleport/workload-identity-svc.yaml
tctl create --force -f teleport/role-workload-identity-issuer.yaml

# 2. Once per Kubernetes cluster: a bot named after the cluster, and its join token
#    (make-token.sh reads the cluster's signing keys from your current kubectl context)
scripts/make-token.sh k8s-prod | tctl create --force -f -
tctl bots add k8s-prod --roles=workload-identity-issuer --token=k8s-prod-issuer   # once; errors if it exists

# 3. The issuer: tbot + the SPIFFE CSI driver, one pod each per node
PROXY_ADDR=example.teleport.sh:443 TOKEN_NAME=k8s-prod-issuer scripts/render.sh | kubectl apply -f -
scripts/check.sh k8s-prod
```

`check.sh` prints one line per check; the last two lines should say the bot has one healthy
instance per node and the token matches the cluster's current signing keys.

## Walkthrough

### 1. The template is the whole identity policy

```bash
tctl get workload_identity/svc
```

```yaml
spec:
  spiffe:
    id: /svc/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}
    hint: "{{ user.bot_name }}"
    x509: { maximum_ttl: 3600s }
    jwt:
      maximum_ttl: 900s
      extra_claims:
        kube: { cluster: "{{ user.bot_name }}", namespace: "{{ workload.kubernetes.namespace }}", pod: "{{ workload.kubernetes.pod_name }}" }
  rules:
    allow:
      - conditions: [{ attribute: workload.kubernetes.attested, eq: { value: "true" } }]
```

Nothing is issued yet. A `workload_identity` is inert until a bot whose role carries the
matching label (`tier: svc`) asks for it on behalf of an attested workload. Why the ID has
this shape and not another (no team, no cluster in the path) is
[docs/spiffe-id-structure.md](docs/spiffe-id-structure.md).

### 2. The issuer is a bot that proves what it is

```bash
tctl get token/k8s-prod-issuer          # a public key, safe to read on screen
tctl bots instances ls                  # one k8s-prod instance per node, Join Method: kubernetes
kubectl -n teleport-wi logs ds/tbot | grep -E 'Fetched new bot identity|Listener opened'
```

```
Fetched new bot identity ... identity: k8s-prod, id=... | valid: ... duration=1h1m0s
Listener opened for Workload API endpoint  addr=/run/spire/agent-sockets/spiffe.sock
```

The DaemonSet joined Teleport with its own projected ServiceAccount token, verified
against the signing keys in the join token. Nothing was distributed to the node. Its
role allows exactly one thing: issuing identities labelled `tier: svc`.

### 3. A pod asks for its identity

Any pod that mounts the Workload API socket can ask. The socket arrives as an ephemeral
`csi` volume from the SPIFFE CSI driver that renders alongside tbot, so the pod's
namespace needs no special Pod Security level. A throwaway client using the SPIRE CLI:

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
  containers:
    - name: probe
      image: ghcr.io/spiffe/spire-agent:1.12.4
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

What you should see is the block under "What you will see": a token for
`spiffe://example.teleport.sh/svc/payments/processor` and the hint `k8s-prod`. Decode the
token's middle segment and the claims read `"sub": "spiffe://…/svc/payments/processor"`
and `"kube": {"cluster": "k8s-prod", "namespace": "payments", "pod": "probe"}`.

On the issuer side, the log line for that request shows what the kubelet attested:

```bash
kubectl -n teleport-wi logs ds/tbot | grep FetchJWTSVID | tail -1
# ... kubernetes:{attested:true namespace:"payments" service_account:"processor" pod_name:"probe" ...}
```

### 4. The same manifest, another project

```bash
kubectl -n payments delete pod probe
kubectl create namespace analytics
kubectl -n analytics create serviceaccount processor
# apply the identical Pod in analytics, then:
kubectl -n analytics logs probe
```

```
token(spiffe://example.teleport.sh/svc/analytics/processor):
```

A different identity from the same resource, and nobody wrote a line of configuration
for it. That is what a policy written against `spiffe://…/svc/payments/*` protects: a
pod in `analytics` cannot become `payments` by editing its own manifest, because the
namespace is not the pod's to choose.

To see the identity *used* (AWS via OIDC federation, mutual TLS between pods), deploy
[spiffe-whoami](https://github.com/jsabo/spiffe-whoami), which was written for that.

## How it works

```
 pod (payments/processor)              node                       Teleport (trust domain example.teleport.sh)
 ┌──────────────────────┐  csi volume  ┌──────────────────────┐  bot cert  ┌──────────────────────────────┐
 │ SPIFFE client asks   │ ───────────► │ tbot DaemonSet        │ ─────────► │ Auth Service:                 │
 │ "who am I?"          │  (socket)    │  1. who is calling?   │  attested  │  match workload_identity by   │
 │                      │ ◄─────────── │     PID → cgroup → pod│  facts     │  the bot's role labels,       │
 │ gets SVID + bundle   │ X.509 / JWT  │     via this kubelet  │ ◄───────── │  evaluate rules, render the   │
 └──────────────────────┘              │  2. forward the facts │  SVIDs     │  template, sign               │
                                       └──────────────────────┘            └──────────────────────────────┘
                                       spiffe-csi-driver DaemonSet: bind-mounts the socket dir into pods
```

- **The issuer is a bot.** It joins with the `kubernetes` method: its own projected
  ServiceAccount token, verified by the Auth Service against the cluster's signing keys
  (`static_jwks`, so it also works when the Auth Service cannot reach your cluster, which
  is always the case on Teleport Cloud). No secret is stored; a restarted pod re-joins.
- **Attestation is local.** The Workload API is a Unix socket, so only pods on the same
  node can reach it. tbot resolves the caller's process ID to a pod through its cgroup and
  asks this node's kubelet for the pod's namespace, ServiceAccount, name, labels and image.
  That is why tbot is a DaemonSet with `hostPID`.
- **The Auth Service decides and signs.** tbot forwards the attested facts. The Auth
  Service finds the `workload_identity` resources the bot's role allows, evaluates each
  one's rules against the facts, renders the templates, and signs. tbot never holds a
  signing key, and a compromised node cannot mint an identity for a pod it does not run.
- **The CSI driver delivers the socket.** tbot writes it to a hostPath on the node; the
  SPIFFE CSI driver bind-mounts that directory into any pod declaring a `csi.spiffe.io`
  volume. hostPath volumes are forbidden by Pod Security `baseline`, which Talos and
  hardened clusters enforce, so without the driver every tenant namespace would have to
  be privileged. With it, only `teleport-wi` is.

## 5-minute demo script

1. `kubectl -n payments get pod probe -o yaml | grep -ci secret` → "Zero. This pod holds no
   credential of any kind."
2. `kubectl -n payments logs probe` → "It asked a socket who it is and got a signed
   identity naming its namespace and ServiceAccount. Nothing in its manifest says that."
3. `tctl get workload_identity/svc` → "This one template is the policy for every pod in
   every cluster. The ID is computed from what the kubelet attested."
4. Apply the same pod in `analytics`, show the log → "Different project, different
   identity, no configuration. It cannot claim to be payments."
5. `tctl bots instances ls` → "The issuer itself is a Teleport identity: one per node, joined
   with the pod's own ServiceAccount token, no secret ever distributed."
6. `tctl lock --user=bot-k8s-prod --ttl=5m` → "Kill switch. Issuance on this cluster stops
   within one renewal; what is already out expires in an hour."

## Security posture

Read this before installing on a cluster you care about.

| What | Why | Scope |
|---|---|---|
| `tbot` DaemonSet: `hostPID`, `hostNetwork`, privileged, root | resolving a connecting process to its pod means reading that process's cgroup, and querying this node's kubelet | namespace `teleport-wi` only |
| `spiffe-csi-driver` DaemonSet: privileged, `mountPropagation: Bidirectional` into `/var/lib/kubelet/pods` | standard for any CSI node plugin: it creates bind mounts the kubelet must see | `teleport-wi` only |
| `kubelet.skip_verify: true` | the attestor connects to the kubelet's secure port (10250); most distributions sign that serving cert from a CA the pod cannot see. The kubelet still authenticates tbot by its ServiceAccount token (RBAC `nodes/proxy`), and tbot only reads pod metadata. Set to `false` and supply `ca_path` if your kubelets carry verifiable certs | attestor only |
| Issuer role: `workload_identity_labels: {tier: [svc]}` + read on `workload_identity` | the bot can issue exactly the identities carrying that label, and nothing else in Teleport | one role, all issuer bots |
| `teleport-wi` namespace labelled `pod-security.kubernetes.io/enforce: privileged` | the two DaemonSets above | this namespace only; workload namespaces stay `baseline` or `restricted` |

The trust model in one sentence: the node attests, Teleport decides and signs, and a
compromised node can at most mint identities for pods that really run on it.

## Distribution notes

The manifests are identical on every distribution; these are the facts that differ.

| Distribution | Verified | Notes |
|---|---|---|
| k3s | 1.31 | Runs as-is. If k3s itself runs in a container (k3d, Docker), `/var/lib/kubelet` must be a shared mount for the CSI driver: `mount --make-rshared` or a bind mount with `propagation: rshared`, otherwise the driver pod fails with "is mounted on /var/lib/kubelet but it is not a shared mount" |
| Talos | 1.13 | Enforces Pod Security `baseline` on every namespace. Only `teleport-wi` needs the `privileged` label, which the namespace manifest carries. Control planes are `NoSchedule`; the issuer lands on workers |
| Amazon EKS | 1.35 | Runs as-is. The cluster publishes many signing keys (14 measured); `make-token.sh` pins all of them |

## Troubleshooting

- `access denied to perform action "readnosecrets" on "workload_identity"` in the tbot log
  on every request: the issuer role lacks `rules: [{resources: [workload_identity], verbs:
  [list, read]}]`. `teleport/role-workload-identity-issuer.yaml` has it; re-apply.
- `violates PodSecurity "baseline:latest": hostPath volumes` when a workload pod is
  created: the pod uses a hostPath for the socket. Use the `csi.spiffe.io` volume.
- `is mounted on /var/lib/kubelet but it is not a shared mount` on the CSI driver pod:
  see the k3s row above.
- `invalid google.protobuf.Duration value "1h"` from `tctl create`: durations in
  `workload_identity` are seconds with an `s` suffix (`3600s`).
- Issuer pods `CrashLoopBackOff` after a cluster rebuild: the cluster's signing keys
  changed. `scripts/jwks.sh --check k8s-prod-issuer`, then
  `scripts/make-token.sh k8s-prod | tctl create --force -f -`.
- A pod gets two SVIDs: it matches two `workload_identity` resources. The shipped design
  has one; if you enabled the optional location identity, select by ID or hint in your
  client.

## Day two

- **Adding a cluster**: steps 2 and 3 of the quick start with a new name. No change to
  the identity resource or the role.
- **Rotation**: nothing to do. X.509 SVIDs renew at half life inside SPIFFE clients; JWTs
  are fetched per use; Teleport CA rotation reaches clients as an updated trust bundle
  over the Workload API stream.
- **Revoking an issuer**: `tctl lock --user=bot-<cluster>`. Issuance stops within one
  renewal; existing SVIDs run out at their TTL.
- **Changing the ID structure**: edit `teleport/workload-identity-svc.yaml`, `tctl create
  --force`. Every issuer follows on its next request; no tbot config changes.
- **Location-bound identities**: `teleport/workload-identity-k8s-optional.yaml` adds
  `/k8s/<cluster>/<ns>/<sa>` for policies that depend on where a workload runs. Off by
  default; see its header.
- **Versions**: tbot follows your cluster (`render.sh` reads `server_version`; override
  with `TBOT_VERSION`). CSI driver 0.2.13 and registrar v2.18.0 are pinned in `render.sh`
  (`CSI_DRIVER_VERSION`, `CSI_REGISTRAR_VERSION`). `WITH_CSI=0` renders without the driver;
  not recommended, since consumers then need hostPath and a privileged namespace.

## Layout

```
teleport/workload-identity-svc.yaml           the identity every pod gets, templated
teleport/workload-identity-k8s-optional.yaml  optional location-bound identity, off by default
teleport/role-workload-identity-issuer.yaml   the issuer bots' one permission
teleport/bot-token-example.yaml               what make-token.sh generates, annotated
k8s/namespace.yaml  k8s/rbac.yaml             ns teleport-wi (PSA privileged), SA, kubelet read RBAC
k8s/configmap.yaml  k8s/daemonset.yaml        tbot config (Workload API + Kubernetes attestor), DaemonSet
k8s/csi-driver.yaml                           SPIFFE CSI driver DaemonSet + CSIDriver
scripts/make-token.sh                         join token with the cluster's signing keys filled in
scripts/render.sh                             fill proxy/token/cluster/versions into k8s/*.yaml
scripts/check.sh                              post-install / pre-demo health check
scripts/jwks.sh                               the cluster's signing keys; --check compares with a token
docs/concepts.md                              ten-minute primer
docs/spiffe-id-structure.md                   why /svc/<namespace>/<serviceaccount>
```

## License

Apache-2.0. The CSI driver manifest is adapted from
[spiffe/spiffe-csi](https://github.com/spiffe/spiffe-csi); the rest follows the Teleport
Workload Identity documentation.
