# teleport-workload-identity-k8s

Give every pod in your Kubernetes clusters an identity it can prove to AWS, to databases
and to other services, without handing a credential to any of them. Teleport issues the
identity when the pod asks for it, computed from facts the node's kubelet attests about
that pod, and renews it automatically:

```
spiffe://<your-teleport-cluster>/svc/<namespace>/<serviceaccount>
```

Nothing is configured per workload and no secret is stored. One Teleport resource defines
the identity for every cluster you own. Installing on a cluster takes four `tctl` commands
and one `kubectl apply`, about ten minutes. Verified on k3s, Talos and Amazon EKS against
Teleport 18.11.2 (Enterprise).

## Why this matters

- **Identity is computed, not configured.** The pod's manifest names no identity. The
  node's kubelet attests the namespace and ServiceAccount, and Teleport renders them into
  the ID. A pod cannot claim to be `payments` from inside `analytics`, because the
  namespace is not the pod's to choose.
- **No long-lived secret anywhere.** The issuer joins Teleport with its own pod's
  ServiceAccount token, which Kubernetes issues and expires after ten minutes. X.509
  certificates last one hour, JWTs fifteen minutes, and both renew automatically.
- **One resource governs every cluster.** Adding a cluster is one bot and one token.
  Changing the shape of the ID is one edit on the Teleport side, and every issuer follows
  on its next request.

## How it works

### The components

| Component | Where it runs | What it does | File |
|---|---|---|---|
| `workload_identity` resource | Teleport | The identity template: the ID path, the lifetimes, the extra JWT claims, and the rule that the caller must be attested by a kubelet. One per Teleport cluster. | `teleport/workload-identity-svc.yaml` |
| Issuer role | Teleport | Lets a bot issue identities carrying the label `tier: svc`, and nothing else in Teleport. | `teleport/role-workload-identity-issuer.yaml` |
| Bot and join token | Teleport | One bot per Kubernetes cluster, named after it. The token holds the cluster's public signing keys, so the issuer pods join with their own ServiceAccount token and nothing is distributed to the node. | `scripts/make-token.sh` |
| `tbot` DaemonSet | every node, namespace `teleport-wi` | The issuer. Serves the SPIFFE Workload API on a Unix socket, works out which pod is calling, and asks Teleport to sign that pod's identity. | `k8s/daemonset.yaml`, `k8s/configmap.yaml` |
| SPIFFE CSI driver | every node, namespace `teleport-wi` | Mounts the socket into any pod that declares a `csi.spiffe.io` volume, so workload namespaces need no special privileges. | `k8s/csi-driver.yaml` |
| Your pod | any namespace | Mounts the volume and asks the socket, using any SPIFFE client library or the SPIRE command line. | `examples/whoami.yaml` shows the minimum |

Three terms, defined once. **SPIFFE** (Secure Production Identity Framework For Everyone)
is the open standard for workload identity. An **SVID** (SPIFFE Verifiable Identity
Document) is the identity as a credential: an X.509 certificate for mutual TLS, or a JWT
for systems that speak OpenID Connect such as AWS. The **Workload API** is the socket a
pod asks for its SVIDs. Six more terms in ten minutes: [docs/concepts.md](docs/concepts.md).

### How an identity is issued

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

The heart of the template (`teleport/workload-identity-svc.yaml` has the lifetimes and
the JWT claims as well):

```yaml
spec:
  spiffe:
    id: /svc/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}
    hint: "{{ user.bot_name }}"          # which cluster's issuer minted it
  rules:
    allow:
      - conditions: [{ attribute: workload.kubernetes.attested, eq: { value: "true" } }]
```

Why the path is `/svc/<namespace>/<serviceaccount>`, with the cluster as a hint and a JWT
claim rather than part of the ID: [docs/spiffe-id-structure.md](docs/spiffe-id-structure.md).

## Install

You need Teleport Enterprise 18.x with `tsh` and `tctl` logged in as `editor`, `kubectl`
with cluster-admin on the target cluster, and `jq` and `curl` on your machine. Replace
`example.teleport.sh` with your proxy and `k8s-prod` with a name for this Kubernetes
cluster.

```bash
tsh login --proxy=example.teleport.sh:443

# Once per Teleport cluster: the identity template and the issuer role
tctl create -f teleport/workload-identity-svc.yaml
tctl create -f teleport/role-workload-identity-issuer.yaml

# Once per Kubernetes cluster: a join token built from the cluster's signing keys
# (read from your current kubectl context), and a bot named after the cluster
scripts/make-token.sh k8s-prod | tctl create --force
tctl bots add k8s-prod --roles=workload-identity-issuer --token=k8s-prod-issuer

# The issuer: tbot and the CSI driver, one pod each per node
scripts/render.sh k8s-prod | kubectl apply -f -
scripts/check.sh k8s-prod
```

`render.sh` takes the proxy address and cluster name from your `tsh` login and the tbot
version from the proxy. `check.sh` prints one line per check: every node runs a ready
issuer, the bot has one healthy instance per node, and the token still matches the
cluster's signing keys.

## Prove it: a pod with no credentials gets its identity

`examples/whoami.yaml` is a ServiceAccount and a pod that runs the SPIRE command-line
client once. The pod asks the Workload API socket for a JWT, prints what it received, and
exits. Nothing in the file names an identity; these are the lines that matter:

```yaml
spec:
  serviceAccountName: processor
  containers:
    - image: ghcr.io/spiffe/spire-agent:1.12.4
      command: [/opt/spire/bin/spire-agent, api, fetch, jwt, -audience, sts.amazonaws.com, -socketPath, /spiffe-workload-api/spiffe.sock]
  volumes:
    - name: spiffe-workload-api
      csi: { driver: csi.spiffe.io, readOnly: true }
```

```bash
kubectl create namespace payments
kubectl -n payments apply -f examples/whoami.yaml
kubectl -n payments wait --for=jsonpath='{.status.phase}'=Succeeded pod/whoami --timeout=60s
kubectl -n payments logs whoami
```

```
token(spiffe://example.teleport.sh/svc/payments/processor):
        eyJhbGciOiJSUzI1NiIs…
hint(spiffe://example.teleport.sh/svc/payments/processor):
        k8s-prod
bundle(spiffe://example.teleport.sh):
        {"keys":[{"kty":"RSA","kid":"…
```

The token is the pod's JWT SVID. The hint says which cluster's issuer minted it. The
bundle is the set of public keys a receiving service uses to verify the token. Decode the
token's claims:

```bash
kubectl -n payments logs whoami | sed -n 2p | tr -d '\t' | jq -R 'split(".")[1] | @base64d | fromjson'
```

```json
{
  "aud": "sts.amazonaws.com",
  "iss": "https://example.teleport.sh/workload-identity",
  "sub": "spiffe://example.teleport.sh/svc/payments/processor",
  "kube": { "cluster": "k8s-prod", "namespace": "payments", "pod": "whoami" },
  "exp": 1791075174, "iat": 1791074274, "jti": "…"
}
```

On the issuer side, every issuance is logged with the facts the kubelet attested:

```bash
kubectl -n teleport-wi logs -l app.kubernetes.io/name=teleport-wi --tail=-1 --since=10m | grep '"jwt-svid"' | tail -1 | jq -r .workload
```

```
unix:{attested:true  pid:310839  uid:65532  gid:65532  binary_path:"/opt/spire/bin/spire-agent"  …}
kubernetes:{attested:true  namespace:"payments"  pod_name:"whoami"  service_account:"processor"  …
container:{name:"whoami"  image:"ghcr.io/spiffe/spire-agent:1.12.4"  image_digest:"sha256:…"}}
```

Now the identical file in a second namespace:

```bash
kubectl create namespace analytics
kubectl -n analytics apply -f examples/whoami.yaml
kubectl -n analytics wait --for=jsonpath='{.status.phase}'=Succeeded pod/whoami --timeout=60s
kubectl -n analytics logs whoami | head -1
```

```
token(spiffe://example.teleport.sh/svc/analytics/processor):
```

What this shows:

- **The manifest holds no credential.** `kubectl -n payments get pod whoami -o json | jq -r '.spec.volumes[] | del(.name) | keys[]'`
  prints `csi` and `projected`: the Workload API socket, and the ServiceAccount token every
  pod gets. No Secret, no key file.
- **Same file, two identities, nothing configured.** The namespace is attested by the
  kubelet, so a pod in `analytics` cannot obtain the `payments` identity.
- **The issuer is itself a Teleport identity.** `tctl bots instances ls` lists one instance
  per node, and `tctl lock --user=bot-k8s-prod --ttl=5m` stops issuance on that cluster
  within one renewal.

From here any SPIFFE-aware client library (go-spiffe, java-spiffe, spiffe-helper, Envoy's
SDS) consumes the socket the same way: an X.509 SVID for mutual TLS between pods, or a
JWT SVID for anything that speaks OpenID Connect, such as AWS `AssumeRoleWithWebIdentity`.

Clean up:

```bash
kubectl delete namespace payments analytics
```

## Security posture

What runs privileged, and why.

| What | Why | Scope |
|---|---|---|
| `tbot` DaemonSet runs privileged with `hostPID` and `hostNetwork` | resolving a caller to its pod means reading that process's cgroup and querying this node's kubelet | namespace `teleport-wi` only |
| CSI driver DaemonSet runs privileged with `mountPropagation: Bidirectional` | standard for any CSI node plugin: it creates bind mounts the kubelet must see | `teleport-wi` only |
| `kubelet.skip_verify: true` | most distributions sign the kubelet's serving certificate from a CA the pod cannot see. The kubelet still authenticates tbot by its ServiceAccount token, and tbot only reads pod metadata. Set `false` and supply `ca_path` if your kubelets carry verifiable certificates | attestor only |
| Issuer role: label selector plus read on `workload_identity` | the bot can issue exactly the identities carrying `tier: svc` | one role, all issuer bots |
| `teleport-wi` labelled Pod Security `privileged` | the two DaemonSets above | workload namespaces stay `baseline` or `restricted`; `examples/whoami.yaml` passes `restricted` |

## Distributions

The manifests are identical everywhere.

| Distribution | Verified | Notes |
|---|---|---|
| k3s | 1.31 | Runs as-is. k3s running inside a container needs the kubelet directory to be a shared mount; see Troubleshooting, "not a shared mount" |
| Talos | 1.13 | Runs as-is. Talos enforces Pod Security `baseline` on every namespace; the CSI volume is what lets consumer pods stay there, and only `teleport-wi` carries the `privileged` label |
| Amazon EKS | 1.35 | Runs as-is. EKS rotates its signing keys on its own schedule; `check.sh` reports when the token must be re-pinned (see Troubleshooting, `CrashLoopBackOff`) |

## Troubleshooting

- `access denied to perform action "readnosecrets" on "workload_identity"` in the tbot log:
  the issuer role lacks `rules: [{resources: [workload_identity], verbs: [list, read]}]`.
  Re-apply `teleport/role-workload-identity-issuer.yaml`.
- `bot "k8s-prod" already exists` from `tctl bots add`: the bot was registered on an
  earlier run. Continue with `render.sh`.
- `render.sh: could not read server_version`: your machine has no HTTPS route to the
  proxy. Set `TBOT_VERSION` to your cluster's version, for example `TBOT_VERSION=18.11.2`.
- `violates PodSecurity "baseline:latest": hostPath volumes` on a workload pod: use the
  `csi.spiffe.io` volume, not a hostPath.
- `is mounted on /var/lib/kubelet but it is not a shared mount` on the CSI driver pod: the
  kubelet directory must be a shared mount on the host. Run `mount --make-rshared
  /var/lib/kubelet` on the node, or, for k3s in Docker Compose, give the bind mount
  `propagation: rshared`.
- `invalid google.protobuf.Duration value "1h"` from `tctl create`: lifetimes are seconds
  with an `s` suffix (`3600s`).
- Issuer pods in `CrashLoopBackOff` and the tbot log ends with `reviewing kubernetes
  token with static_jwks … validating jwt signature … go-jose/go-jose: unsupported key
  type/format`: the cluster's signing keys changed and the token no longer pins the key
  that signed the pod's ServiceAccount token. A cluster rebuild does this; so does routine
  key rotation on EKS. `scripts/jwks.sh --check k8s-prod-issuer` confirms it, then
  `scripts/make-token.sh k8s-prod | tctl create --force` and
  `kubectl -n teleport-wi rollout restart ds/tbot`.

## Day two

- **Add a cluster**: the two "once per Kubernetes cluster" steps and the render, with a
  new name. Nothing changes on the Teleport side.
- **Rotate**: nothing to do. SVIDs renew inside the client; a Teleport CA rotation reaches
  clients as an updated trust bundle over the Workload API.
- **Pause or revoke an issuer**: `tctl lock --user=bot-<cluster> --ttl=5m` pauses issuance
  on one cluster; without `--ttl` the lock holds until `tctl rm lock/<name>`. Issuance
  stops within one renewal; existing SVIDs run out at their lifetime.
- **Change the ID shape**: edit `teleport/workload-identity-svc.yaml` and `tctl create -f`
  it again. No tbot changes.
- **Location-bound identities**: `teleport/workload-identity-k8s-optional.yaml` adds a
  second identity, `/k8s/<cluster>/<namespace>/<serviceaccount>`, for policies that depend
  on where a workload runs. Off by default.
- **Versions**: tbot follows your Teleport cluster; `render.sh` reads the version from the
  proxy. The CSI driver (0.2.13) and its registrar (v2.18.0) are pinned in `scripts/render.sh`.

## License

Apache-2.0. The CSI driver manifest is adapted from
[spiffe/spiffe-csi](https://github.com/spiffe/spiffe-csi).
