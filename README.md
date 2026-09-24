# teleport-workload-identity-k8s

Turn a Kubernetes cluster into a SPIFFE identity issuer backed by Teleport. One `tbot`
DaemonSet joins your Teleport cluster with the pod's own ServiceAccount token, serves the
standard SPIFFE Workload API on every node, and attests each caller through the kubelet.
One `workload_identity` resource then gives every pod in the cluster an identity computed
from what was attested: `spiffe://<your-cluster>/svc/<namespace>/<serviceaccount>`. Nothing
is written per workload, no secret is stored anywhere, and the same YAML serves your
second cluster and your hundredth.

Verified against Teleport 18.11.1 (Enterprise Cloud) on k3s. The issuer joined in two
seconds, the first pod was issued a certificate and a JWT within a second of asking, and
the identities matched the pod's namespace and ServiceAccount exactly.

## Start here

1. **Understand** what a trust domain, a SPIFFE ID, an SVID, the Workload API and
   attestation are, in plain words: [docs/concepts.md](docs/concepts.md), ten minutes.
2. **Read why the ID looks the way it does** and what the alternatives cost:
   [docs/spiffe-id-structure.md](docs/spiffe-id-structure.md).
3. **Install it on one cluster** with the quick start below, then point a workload at
   the socket. [spiffe-whoami](https://github.com/jsabo/spiffe-whoami) is a small app
   built for exactly that: it shows the identity it was given and uses it.

## Quick start

Your values: the proxy address, a Kubernetes cluster name to use as the bot name, and
`kubectl` with cluster-admin on that cluster. Everything else is in this repo.

```bash
tsh login --proxy=example.teleport.sh:443

# 1. The identity template and the issuer role — once per Teleport cluster
tctl create -f teleport/workload-identity-svc.yaml
tctl create -f teleport/role-workload-identity-issuer.yaml

# 2. A bot and join token for THIS Kubernetes cluster — once per Kubernetes cluster
scripts/jwks.sh                                     # paste the output into the token file
tctl create -f teleport/bot-token-example.yaml      # after editing name, bot_name, jwks
tctl bots add k8s-prod --roles=workload-identity-issuer --token=k8s-prod-issuer

# 3. The issuer DaemonSet
PROXY_ADDR=example.teleport.sh:443 TOKEN_NAME=k8s-prod-issuer scripts/render.sh | kubectl apply -f -
kubectl -n teleport-wi rollout status ds/tbot
tctl bots instances ls                              # one healthy k8s-prod instance per node
```

### Phase by phase

**The template.** `teleport/workload-identity-svc.yaml` is the whole identity policy:

```yaml
spec:
  spiffe:
    id: /svc/{{ workload.kubernetes.namespace }}/{{ workload.kubernetes.service_account }}
    hint: "{{ user.bot_name }}"
    jwt:
      maximum_ttl: 900s
      extra_claims:
        kube: { cluster: "{{ user.bot_name }}", namespace: "{{ workload.kubernetes.namespace }}", pod: "{{ workload.kubernetes.pod_name }}" }
  rules:
    allow:
      - conditions:
          - attribute: workload.kubernetes.attested
            eq: { value: "true" }
```

What you should see after `tctl create`: `Workload Identity "svc" has been created`.
Nothing is issued yet; an identity is inert until an issuer with a matching role asks for it.

**The issuer.** `scripts/render.sh` fills the proxy address, the token name, the cluster
name (the projected token's audience) and the tbot image tag into `k8s/*.yaml`. The
DaemonSet runs privileged with `hostPID`, because identifying a calling process means
reading its cgroup and asking this node's kubelet which pod owns it. What you should
see in the pod log:

```
Fetched new bot identity ... k8s-prod, id=... | valid: ... duration=1h1m0s
Listener opened for Workload API endpoint  addr=/run/spire/agent-sockets/spiffe.sock
```

**A workload.** Any pod that mounts the socket can ask. The socket arrives as an
ephemeral `csi` volume from the SPIFFE CSI driver that renders alongside tbot, so the
workload's namespace needs no special Pod Security level. With the SPIRE CLI image as a
throwaway client:

```bash
kubectl -n payments create sa processor
kubectl -n payments run probe --restart=Never --serviceaccount=processor \
  --image=ghcr.io/spiffe/spire-agent:1.12.4 \
  --overrides='{"spec":{"volumes":[{"name":"s","csi":{"driver":"csi.spiffe.io","readOnly":true}}],
    "containers":[{"name":"probe","image":"ghcr.io/spiffe/spire-agent:1.12.4",
    "command":["/opt/spire/bin/spire-agent","api","fetch","jwt","-audience","sts.amazonaws.com","-socketPath","/s/spiffe.sock"],
    "volumeMounts":[{"name":"s","mountPath":"/s"}]}]}}'
kubectl -n payments logs probe
```

What you should see: `token(spiffe://example.teleport.sh/svc/payments/processor)` followed
by the JWT, then `hint(...): k8s-prod`. Decode the JWT and the claims carry
`"sub": "spiffe://example.teleport.sh/svc/payments/processor"` and
`"kube": {"cluster": "k8s-prod", "namespace": "payments", "pod": "probe"}`. On the
issuer side the log line for that request shows what was attested:
`kubernetes:{attested:true namespace:"payments" service_account:"processor" ...}`.

Delete the pod, create the same pod in another namespace, and read a different identity
from the same resource. That is the demo.

### What to expect

| Measured on k3s, Teleport 18.11.1 | |
|---|---|
| Issuer join (pod start to Workload API listening) | 2 s |
| First SVID for a new pod | under 1 s |
| X.509 SVID lifetime | 1 h (`x509.maximum_ttl`), renewed in the background by SPIFFE clients |
| JWT SVID lifetime | 15 min (`jwt.maximum_ttl`), fetched per use |
| Issuer footprint | one pod per node, ~40 MB RSS |

### What you need

- Teleport Enterprise (Cloud or self-hosted) 18.x; Workload Identity is an Enterprise feature.
- `tctl` and `tsh` logged in with the `editor` preset, to create the resources and the bot.
- Cluster-admin on the Kubernetes cluster, once, to create the namespace, RBAC and DaemonSet.
- Kubernetes 1.21+ with projected ServiceAccount tokens (every current distribution).
- For Teleport Cloud: the cluster's OIDC discovery must be readable by you
  (`kubectl get --raw /openid/v1/jwks`), since Cloud verifies join tokens against the
  published key rather than calling the cluster.

## How it works

```
 pod (payments/processor)                node                    Teleport (trust domain example.teleport.sh)
 ┌──────────────────────┐   unix socket  ┌────────────────────┐  bot cert  ┌──────────────────────────────┐
 │ SPIFFE client asks   │ ─────────────► │ tbot DaemonSet     │ ─────────► │ Auth: match workload_identity │
 │ "who am I?"          │                │ 1. who is calling? │            │ resources the bot's role      │
 │                      │ ◄───────────── │    PID→cgroup→pod  │ ◄───────── │ allows; evaluate rules;       │
 │ gets SVID + bundle   │  X.509 / JWT   │    via kubelet     │  SVIDs     │ render the template; sign     │
 └──────────────────────┘                │ 2. forward attested│            └──────────────────────────────┘
                                         │    facts to Auth   │
                                         └────────────────────┘
```

- **The issuer is a bot.** It joins with the `kubernetes` join method: its own projected
  ServiceAccount token, verified by the Auth Service against the cluster's signing key.
  No secret is stored; a restarted pod re-joins. The bot's role allows exactly one thing,
  issuing identities labelled `tier=svc`, plus reading those resources.
- **Attestation is local.** The Workload API is a Unix socket, so only pods on the same
  node can reach it, and tbot resolves the caller's PID to a pod through the cgroup and
  the node's kubelet. That is why it must be a DaemonSet with `hostPID`.
- **The socket reaches pods through a CSI driver.** tbot writes the socket to a hostPath
  on the node; the SPIFFE CSI driver (a second DaemonSet in the same namespace)
  bind-mounts that directory into any pod that declares a `csi.spiffe.io` volume. Pods
  could mount the hostPath directly, but hostPath volumes are forbidden by the Pod
  Security `baseline` policy that Talos and hardened clusters enforce, and that would
  force every tenant namespace to be privileged. With the CSI volume only `teleport-wi`
  is privileged. Set `WITH_CSI=0` on `render.sh` to leave the driver out.
- **The Auth Service decides.** tbot forwards the attested facts; the Auth Service matches
  `workload_identity` resources by label, evaluates each one's rules against those facts,
  renders the templates, and signs. tbot never holds a signing key.
- **The template is the policy.** Change the ID structure centrally and every issuer
  follows on its next request. See [docs/spiffe-id-structure.md](docs/spiffe-id-structure.md)
  for why the ID names the namespace and ServiceAccount and nothing else.

## Day two

- **Adding a cluster**: a bot named after the cluster, a token with that cluster's JWKS,
  render and apply. No change to the identity resource or the role.
- **Rotation**: X.509 SVIDs renew at half life; JWTs are fetched per use. Teleport CA
  rotation is picked up by tbot's `ca-rotation` service; SPIFFE clients receive the new
  bundle over the Workload API stream.
- **Cluster rebuilt or signing key rotated**: the join token's pinned JWKS is stale and the
  issuer cannot join. `scripts/jwks.sh --check <token>` tells you; recreate the token.
- **Revoking an issuer**: `tctl lock --user=bot-<cluster>` stops issuance on that cluster
  within one renewal; existing SVIDs run out at their TTL.
- **The optional location identity** (`teleport/workload-identity-k8s-optional.yaml`)
  adds `/k8s/<cluster>/<ns>/<sa>` for policies that genuinely depend on where a workload
  runs. A pod matching both receives two SVIDs; SPIFFE clients treat the first as the
  default, so only enable it when consumers select by ID or hint.
- **Pod Security Admission**: `teleport-wi` carries
  `pod-security.kubernetes.io/enforce: privileged`, which Talos and other PSA-enforcing
  distributions require for the two privileged DaemonSets. Workload namespaces need
  nothing: measured on Talos, a `baseline` namespace rejected a hostPath consumer
  (`violates PodSecurity "baseline:latest": hostPath volumes`) and accepted the same pod
  with the `csi` volume.

## Layout

```
teleport/workload-identity-svc.yaml           the identity every pod gets, templated
teleport/workload-identity-k8s-optional.yaml  optional location-bound identity, off by default
teleport/role-workload-identity-issuer.yaml   the issuer bots' one permission
teleport/bot-token-example.yaml               kubernetes join token, static_jwks, one per cluster
k8s/namespace.yaml  k8s/rbac.yaml             ns teleport-wi (PSA privileged), SA, kubelet read RBAC
k8s/configmap.yaml  k8s/daemonset.yaml        tbot config (Workload API + Kubernetes attestor), DaemonSet
k8s/csi-driver.yaml                           SPIFFE CSI driver DaemonSet + CSIDriver: the socket as a csi volume
scripts/render.sh                             fill proxy/token/cluster/versions into k8s/*.yaml (WITH_CSI=0 to omit the driver)
scripts/jwks.sh                               the cluster's signing keys; --check compares with a token
docs/concepts.md                              ten-minute primer
docs/spiffe-id-structure.md                   why /svc/<namespace>/<serviceaccount>
```

## License

Apache-2.0. Manifests adapted from
[asteroid-earth/teleport-workload-example](https://github.com/asteroid-earth/teleport-workload-example)
and the Teleport Workload Identity documentation.
