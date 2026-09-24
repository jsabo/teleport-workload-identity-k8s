# Concepts in ten minutes

Six terms carry everything in this repo. Each gets its full name, what it does in
ordinary words, and where it shows up here.

## Trust domain

The name of the authority that vouches for identities: for Teleport Workload Identity it
is your Teleport cluster name, `example.teleport.sh`. Every identity it issues starts
with `spiffe://example.teleport.sh/`. A second Teleport cluster is a second trust domain.
Two trust domains can be made to trust each other (federation), but this repo uses one.

## SPIFFE ID

A URI that names a workload: `spiffe://<trust domain>/<path>`. SPIFFE is the Secure
Production Identity Framework For Everyone, an open standard, and the ID is the part
policies are written against. Here the path is `/svc/<namespace>/<serviceaccount>`,
computed from the pod at issuance time. Why that shape and not another is
[spiffe-id-structure.md](spiffe-id-structure.md).

## SVID

A SPIFFE Verifiable Identity Document: the SPIFFE ID made into a credential a peer can
check. Two kinds:

- **X.509 SVID**: a short-lived certificate with the SPIFFE ID as its URI Subject
  Alternative Name. Used for mutual TLS between workloads. Here: one hour.
- **JWT SVID**: a signed token with the SPIFFE ID as `sub` and the receiving party as
  `aud`. Used to talk to things that speak OpenID Connect, like AWS STS. Here: fifteen
  minutes, with extra claims that record the cluster, namespace and pod.

Both are minted by the Teleport Auth Service and renewed automatically. Neither is
stored anywhere by anyone.

## Trust bundle

The public keys a peer needs to verify SVIDs from a trust domain. Delivered to
workloads over the Workload API alongside their SVID, and kept current through
Teleport CA rotations. For OIDC consumers it is the JSON Web Key Set at
`https://example.teleport.sh/workload-identity/jwt-jwks.json`.

## Workload API

The standard SPIFFE interface a workload uses to get its SVIDs and bundle: a gRPC
service on a Unix socket. Client libraries exist for Go, Java, Python, Rust and C, and
tools like Envoy and spiffe-helper speak it natively. Here `tbot` serves it on every
node at `/run/spire/agent-sockets/spiffe.sock` (SPIRE's conventional location, so tools
find it without configuration). A pod mounts that directory and asks; it does not
present any credential to ask.

## Workload attestation

How the issuer knows who is asking, given that the caller presented nothing. The
Workload API server sees the connecting process's PID, reads its cgroup to find the
container and pod, and asks the node's kubelet for that pod's namespace, ServiceAccount,
name, labels and container image. Those attested facts are forwarded to the Auth
Service, which evaluates the `workload_identity` resource's rules against them and
fills its templates from them. Only a process actually running in that pod can obtain
that pod's identity, and the identity says only what the platform can vouch for.

## How they fit together

A pod in namespace `payments` under ServiceAccount `processor` connects to the socket.
tbot attests it and forwards `{namespace: payments, service_account: processor, ...}`.
The Auth Service finds the `svc` resource (labelled `tier: svc`, which the issuer's role
allows), checks the rule `workload.kubernetes.attested == true`, renders
`/svc/payments/processor`, and signs an X.509 SVID and, on request, a JWT SVID with
`aud: sts.amazonaws.com`. The pod uses the X.509 SVID to talk to its peers over mTLS and
the JWT to assume an AWS role whose trust policy names exactly that SPIFFE ID.
