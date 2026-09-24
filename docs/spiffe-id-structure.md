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

- **Trust domain** is the Teleport cluster. It is also the environment boundary in most
  estates: production and non-production are different Teleport clusters, so the path
  does not need an environment segment.
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
available to policy that genuinely needs it. A location-bound identity template is
provided separately (`teleport/workload-identity-k8s-optional.yaml`) for that case.

**Pod labels as the source of the name** (`app.kubernetes.io/name` and friends). Labels
are attested too, and Teleport can template on them (`{{ workload.kubernetes.labels["app"] }}`).
But labels are set by whoever writes the pod spec, so any deployer in a namespace could
claim any name. Namespace and ServiceAccount are set by the platform; labels are set by
the tenant. Use labels for hints and extra claims, not for the identity.

**Environment in the path** (`/production/payments/processor`, the doc's own example).
Right when several environments share one Teleport cluster. Here they do not, so the
segment would carry no information. If you need it, derive it from a namespace naming
convention with `regexp.replace` rather than typing it, so it stays computed.

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
so the question never arises. If you add the optional location identity, make sure your
consumers select by SPIFFE ID or hint.
