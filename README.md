# snaPDF-infra

## Overview
This repository is the infrastructure layer of snaPDF: everything that
exists in AWS is defined here as Terraform, orchestrated by Terragrunt.
It builds the platform the other two repos assume — networking (VPC),
compute (EKS + Karpenter), data (RDS, S3, SQS), identity (IAM/IRSA),
and the in-cluster foundation (ALB controller, nginx, External Secrets,
KEDA, observability, ArgoCD).
Design in one sentence: reusable modules under `modules/` hold all the
logic; thin Terragrunt wrappers under `environments/{dev,prod}/` stamp
them out per environment with isolated state per module, and dependency
blocks wire outputs between states. Two environments, one codebase — dev
(hosting `dev` + `staging` namespaces) and prod differ only in a handful
of values, and either can be built from a fresh AWS account or destroyed
to zero with a single `terragrunt run-all` command.
## Structure

    snaPDF-infra/
    ├── infra/
    │   ├── terragrunt.hcl            # Root config: S3 backend + locking,
    │   │                             #   generated AWS provider — inherited
    │   │                             #   by every wrapper below
    │   ├── modules/                  # Reusable blueprints (pure Terraform,
    │   │   │                         #   environment-agnostic)
    │   │   ├── vpc/                  # VPC, 3 subnet tiers × 2 AZs, IGW/NAT
    │   │   ├── eks/                  # Cluster + managed node group
    │   │   ├── iam/                  # IRSA roles + GitHub OIDC for CI
    │   │   ├── s3/                   # Document bucket
    │   │   ├── sqs/                  # free/signed queue pair per namespace
    │   │   ├── rds/                  # PostgreSQL instance
    │   │   ├── karpenter/            # Node autoscaler (Helm)
    │   │   ├── keda/                 # Queue-depth pod autoscaler (Helm)
    │   │   ├── observability/        # kube-prometheus-stack + custom
    │   │   │   └── charts/           #   dashboards/ServiceMonitors chart
    │   │   ├── argocd/               # ArgoCD + root-app bootstrap (Helm)
    │   │   └── addons/               # ALB controller, nginx, ESO, DNS,
    │   │                             #   LB waiter, staging-DB job
    │   ├── environments/
    │   │   ├── dev/                  # One thin wrapper per module +
    │   │   │   ├── env.hcl           #   env.hcl with the per-env values
    │   │   │   └── <module>/terragrunt.hcl   × 11
    │   │   └── prod/                 # Identical layout, prod values
    │   └── global/                   # One-time, environment-independent
    │                                 #   resources (state bootstrap, ECR…)
    ├── destroy.ps1                   # Ordered full-environment teardown
    ├── fix-locks.ps1                 # Clears stale S3 state locks
    └── .github/                      # PR / issue format conventions

Reading rule: `modules/` answers *what* gets built, `environments/` answers
*where and with which values* — a wrapper is ~15 lines naming a module,
its inputs, and its dependencies. Nothing under `environments/` contains
resource logic, and nothing under `modules/` knows an environment exists.

State mirrors the tree: each wrapper gets its own state file in S3 at its
path (`environments/dev/vpc/terraform.tfstate`, …), so blast radius,
locking, and plan time are scoped per module per environment.
## Diagram
An added PDF.
## Terragrunt
Terraform holds all the resource logic.
Terragrunt exists in this repo to solve exactly four problems Terraform can't solve cleanly on its own:

**1. One backend definition instead of twenty-two.** Terraform forbids
variables in `backend` blocks, so without help, every module × environment
would hardcode its own state config. The root `infra/terragrunt.hcl`
defines it once and *generates* a `backend.tf` into each module at run
time. The state key is derived from the directory path:

    key = "${path_relative_to_include()}/terraform.tfstate"

so running in `environments/dev/vpc/` automatically writes state to
`environments/dev/vpc/terraform.tfstate` — isolated state per module per
environment, with zero per-module configuration. Locking uses S3 native
lockfiles (`use_lockfile = true`, hence `required_version >= 1.10`) — no
DynamoDB table; the entire backend is one bucket. The AWS provider is
generated the same way, so the region lives in one line.

**2. Per-environment values without duplication.** Each environment has
one `env.hcl` (name, cluster name, instance type). Wrappers load it with
`read_terragrunt_config(find_in_parent_folders("env.hcl"))` — so a module
wrapper is identical between dev and prod, and the environments differ
only where env.hcl says they do.

**3. Wiring between isolated states.** Since every module has its own
state, outputs are the only API between them — `dependency` blocks read
another module's outputs at run time:

    dependency "vpc" { config_path = "../vpc" }
    inputs = { vpc_id = dependency.vpc.outputs.vpc_id }

`mock_outputs` (allowed for plan/validate/destroy, never apply) let the
whole dependency graph plan from an empty AWS account, before any real
outputs exist. Where a module needs *ordering* without consuming values
(KEDA must follow observability because of the ServiceMonitor CRD),
`dependencies` blocks express it — cross-state sequencing that Terraform's
`depends_on` cannot do.

**4. Whole-environment operations.** The dependency graph makes
`terragrunt run-all apply` / `run-all destroy` possible: Terragrunt
topologically sorts every module under the current directory and executes
in order (reversed for destroy). Standing up or tearing down a complete
environment is one command from `environments/dev/`.

Anatomy of every wrapper (~15 lines): `include "root"` (inherit backend +
provider) → `read_terragrunt_config` (load env values) → `terraform.source`
(which module) → `dependency`/`dependencies` (wiring) → `inputs` (values).
The same skeleton repeats across all 22 wrappers; only the source and
inputs change.
## Dirs Breakdown
markdown## Dirs Breakdown

**`infra/terragrunt.hcl`** — the root config. Defines the S3 backend (state
path derived from directory path, native S3 locking) and generates the AWS
provider. Every wrapper inherits it via `include "root"` — backend and
provider are written once for the entire repo.

**`infra/modules/`** — the blueprints. Eleven reusable Terraform modules
(vpc, eks, iam, s3, sqs, rds, karpenter, keda, observability, argocd,
addons), each with the same contract: `variables.tf` in, `outputs.tf` out.
Modules are environment-agnostic — nothing in here knows whether it's
building dev or prod.

**`infra/environments/`** — the instantiations. One folder per environment
(`dev/`, `prod/`), each holding an `env.hcl` with the per-environment
values and a thin ~15-line wrapper per module that names the source, the
inputs, and the dependencies. No resource logic lives here. Dev's cluster
hosts both the `dev` and `staging` namespaces; prod is its own cluster.

**`infra/global/`** — resources that belong to the account rather than to
any environment, applied once.
## Modules
## Modules

| Module | What it creates | Design notes |
|---|---|---|
| `vpc` | VPC 10.0.0.0/16, three subnet tiers × 2 AZs (public / private / DB), IGW, single NAT, DB subnet group | Subnets computed with `cidrsubnet` offsets from one supernet; EKS/ALB discovery tags (`kubernetes.io/role/elb`) on the subnet tiers; single NAT is a deliberate cost/availability trade |
| `eks` | EKS cluster (K8s 1.31) + managed node group, via the official `terraform-aws-modules/eks` module | t3.medium nodes as the always-on baseline — Karpenter provides elasticity on top; extra SG rules added as standalone resources for CoreDNS (module shorthand produced the wrong source SG) |
| `iam` | IRSA role+policy pairs per workload: ALB controller, ESO, KEDA, api, workers | Every pod's AWS permissions are its own least-privilege role, trusted via the cluster's OIDC provider — no node-level or static credentials anywhere |
| `s3` | One PDF bucket **per app namespace** (`snapdf-dev-pdfs-…`, `snapdf-staging-pdfs-…`) via `for_each` | All public access blocked at the bucket level; account ID suffix guarantees global name uniqueness |
| `sqs` | free/signed queue pair per app namespace (`for_each`) | Visibility timeout (60s) is the retry mechanism — a crashed worker's message simply reappears; 1h retention because stale conversions are worthless |
| `rds` | PostgreSQL 16 on db.t3.micro, single-AZ, private-only + its security group | Credentials generated and stored in Secrets Manager (consumed by ESO and the staging-DB job); micro/single-AZ is an explicit cost decision for a portfolio system |
| `karpenter` | Karpenter 1.1.1 via Helm — running on a dedicated **Fargate profile** | Fargate breaks the chicken-and-egg (the autoscaler can't depend on nodes it manages); single replica because the chart's default 2-replica anti-affinity can't be satisfied on a small cluster (infra #24); NodePool objects live in gitops |
| `keda` | KEDA 2.13.1 via Helm | IRSA-annotated operator reads SQS queue depth directly; ServiceMonitor emission requires observability first (cross-state `dependencies` ordering) |
| `observability` | EBS CSI addon + gp3 StorageClass, kube-prometheus-stack, plus a local `monitoring-extras` chart | Extras chart carries custom dashboards (business/scaling) and ServiceMonitors; Grafana admin password is generated and stored in Secrets Manager — never the chart default |
| `argocd` | ArgoCD via Helm + GitHub webhook secret + root Application bootstrap | The repo's handoff point: plants the root app pointing at snaPDF-gitops; TLS terminates at the ALB (`server.insecure`), webhook secret makes syncs instant instead of 3-min polls |
| `addons` | ALB controller, nginx (ClusterIP), ESO, LB-hostname waiter, Route 53 records, staging-DB job | The glue layer: waits for the gitops-created ALB, harvests its hostname for DNS (apex = ALIAS record), and carries the ordered-destroy logic for controller-created AWS resources |
| `global` (dir) | GitHub OIDC provider + CI role scoped to the three ECR repos, the ECR repositories, shared secrets | Account-level, applied once — this is what the app repo's CI authenticates against |
## Dependencies Logic
### The graph (per environment)

    s3 ──┐
    sqs ─┤                        ┌─ karpenter ──┐
    vpc ─┼─ eks ── iam ── addons ─┼─ keda ───────┼─ (ordering only)
         │         │              ├─ observability
         └─────────┘              └─ argocd

    global (account-level) ─→ read by observability, argocd, addons

Reading it left to right:

- **Roots:** `vpc`, `s3`, `sqs` depend on nothing (pure AWS primitives) —
  they apply first, in parallel.
- **`eks`** needs only the VPC (subnets to place nodes in).
- **`iam`** reads `eks` (the cluster's OIDC provider — the trust anchor
  every IRSA role points at) plus `sqs` and `s3` (queue/bucket ARNs to
  scope the workload policies to — least-privilege comes from the graph).
- **`rds`** reads `vpc` (DB subnet group) and `eks` (allows Postgres
  ingress from the node security group).
- **`addons`** is the convergence point — five dependencies (vpc, eks,
  iam, global, rds): it needs everything because it is the bridge from
  AWS into the cluster.
- **The Helm layer** (`karpenter`, `keda`, `observability`, `argocd`)
  reads `eks` (endpoint/CA for the provider) and `iam` (role ARNs), and
  lists `addons` as ordering-only — the cluster must be *functional*
  (controllers, ESO) before more software lands on it. `keda`
  additionally waits for `observability` (the CRD story above).



