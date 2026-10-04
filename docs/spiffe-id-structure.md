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
  boundary: many organizations run development, staging and production in one Teleport cluster
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

Scopes are a Teleport 18 feature for large organizations. A scope is a path such as
`/prod/payments`. A team can be given the right to manage roles, bots and workload
identities inside its own scope, with no cluster-wide privilege.

When a workload identity is created inside a scope, Teleport requires its SPIFFE ID to
start with the scope path, then a separator segment `_`, then the segments the team
chooses:

```
spiffe://example.teleport.sh/prod/payments/_/svc/payments/processor
```

Teleport checks this every time it issues an identity, so a team's template can only ever
produce identities under its own scope. For the structure in this repository, the
environment and the owning team are supplied by the scope and enforced by Teleport, and
`/svc/<namespace>/<serviceaccount>` is what follows the separator.

Scopes are new in Teleport 18 and still being documented. Check the Teleport
documentation for your version before building policy on them.

## What the template can and cannot do

Templates can lowercase, uppercase, replace, split and pattern-rewrite text, and read a
pod's labels: `strings.lower`, `strings.upper`, `strings.replaceall`, `strings.split`,
`regexp.replace`, and `workload.kubernetes.labels["name"]`. Two limits: an expression
cannot contain curly braces, so regular expressions cannot use `{n}` counts, and there is
no "starts with" or "contains" function, so a test like "the namespace begins with
`prod-`" is written as a `regexp.replace`.

Lifetimes are written in seconds with an `s` suffix (`3600s`), not `1h`.

## One identity per pod

A pod that matches several `workload_identity` resources receives several SVIDs. That is
legal SPIFFE, but clients treat the first one returned as the default and it is not
specified which comes first. The design here keeps exactly one resource matching any pod,
so the question never arises. If you add a second identity, make sure your consumers
select by SPIFFE ID or hint.
