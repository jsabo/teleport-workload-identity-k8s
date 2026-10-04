# Why the SPIFFE ID is `/svc/<namespace>/<serviceaccount>`

The SPIFFE ID is what every policy is written against: the AWS trust policy, a peer's
allowlist, a database's certificate mapping. Its structure is therefore a long-lived
decision, and Teleport's best-practices guidance is only that it should be hierarchical,
most general first, so that rules can match prefixes. This page records the structure
chosen here and the alternatives that were rejected, so the next person does not have to
rediscover the reasoning.

## The structure

```
spiffe://<trust domain>/svc/<namespace>/<serviceaccount>
```

- **Trust domain** is the Teleport cluster, one to one. It is not an environment
  boundary: many estates run development, staging and production in one Teleport cluster
  and separate them with labels and roles, and Teleport 18 adds scopes for a harder
  separation. Whatever separation your policies need has to be in the path. See
  "Environment in the path" and "Scopes" below.
- **`svc/`** is a namespace prefix so that other identity families (VMs, CI jobs,
  location-bound identities) can be added later without colliding.
- **`<namespace>`** is the project. In a platform where Kubernetes namespaces are assigned
  to teams or applications, the namespace is the stable name for "what this belongs to",
  and it is admission-controlled: a workload cannot choose its namespace.
- **`<serviceaccount>`** is the service. One ServiceAccount per service is standard
  Kubernetes practice, and again the workload cannot choose it.

Both segments are attested by the kubelet at issuance. The ID is computed, not declared:
one `workload_identity` resource covers every pod in every cluster, and adding a service
means creating a ServiceAccount, which teams already do.

## What was rejected, and why

**Team in the path** (`/svc/<team>/<service>`). Teams reorganise. An identity that an AWS
trust policy has pinned for two years cannot be renamed because a team was renamed, and
namespaces move between teams more often than services change what they are. Team
ownership belongs in the systems that decide who may deploy into a namespace, not in the
name of what runs there.

**Cluster in the path** (`/svc/<cluster>/<namespace>/<serviceaccount>`). The same
service running in three clusters would have three identities and every policy would
have to name all three, then change when a cluster is rebuilt or renamed. An identity
should survive a move. The cluster is a fact about the deployment; it is carried as the
SVID `hint` and as the JWT claim `kube.cluster`, where it is visible for audit and
available to JWT consumers that genuinely need it. The one case this does not cover is a
mutual TLS peer that must accept one cluster and refuse another, because an X.509 SVID
carries only the SPIFFE ID. If you have that case, add a second `workload_identity` whose
path starts with `/k8s/{{ user.bot_name }}/` and accept the per-cluster policy names.

**Pod labels as the source of the name** (`app.kubernetes.io/name` and friends). Labels
are attested too, and Teleport can template on them (`{{ workload.kubernetes.labels["app"] }}`).
But labels are set by whoever writes the pod spec, so any deployer in a namespace could
claim any name. Namespace and ServiceAccount are set by the platform; labels are set by
the tenant. Use labels for hints and extra claims, not for the identity.

**Environment in the path** (`/production/payments/processor`, the example in Teleport's
documentation). Right whenever several environments share one Teleport cluster, which is
common. It is left out of the template shipped here only because the shipped template is
the smallest one that works; add it if your policies must tell environments apart. The
rule is the same as for every other segment: derive it from something attested, never
type it. Two sources work. A namespace naming convention, `prod-payments` becoming
`/prod/payments/processor` through `regexp.replace` on the attested namespace. Or, when
each environment has its own Kubernetes clusters, a separate `workload_identity` per
environment (`id: /prod/{{ workload.kubernetes.namespace }}/…`, labelled `env: prod`)
that only the issuer bots in that environment's clusters are allowed to issue.

## Scopes

Teleport 18 introduces scopes: a tree of paths such as `/prod/payments` under which
roles, join tokens, bots and `workload_identity` resources can be defined, so a team can
administer its own branch without cluster-wide privilege. A `workload_identity` created
inside a scope must produce a SPIFFE ID whose path begins with the scope, followed by the
separator segment `_`, followed by the administrator's own segments:

```
spiffe://example.teleport.sh/prod/payments/_/svc/payments/processor
```

The Auth Service re-validates the rendered ID against the scope on every issuance, so a
scoped template cannot escape its branch (`lib/services/workload_identity.go:215` at
v18.11.2; design in RFD 0229c). In a scoped estate the environment and the owning team
therefore come from the scope, enforced by Teleport, and the `/svc/<namespace>/<serviceaccount>`
shape here is what goes after the separator. At 18.11 the scopes code is present but the
documentation and the RFD are not yet final; treat it as a preview and verify against your
version before building policy on it.

## What the template can and cannot do

Templates use Teleport's predicate language. Available in 18.11: `strings.lower`,
`strings.upper`, `strings.replaceall`, `strings.split`, `regexp.replace`, map indexing
on labels. Two limits: a template cannot contain curly braces inside an expression (so no
`{n}` regex quantifiers), and there is no prefix or contains function for strings, so
"if the namespace starts with X" has to be written as a `regexp.replace`.

Durations in the resource are protobuf Durations: write `3600s`, not `1h`.

## One identity per pod

A pod that matches several `workload_identity` resources receives several SVIDs. That is
legal SPIFFE, but clients treat the first one returned as the default and it is not
specified which comes first. The design here keeps exactly one resource matching any pod,
so the question never arises. If you add a second identity, make sure your consumers
select by SPIFFE ID or hint.
