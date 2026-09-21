# Rancher Lab — Production Patterns on a Single Laptop

A hands-on platform engineering lab that builds a multi-cluster Kubernetes environment on one laptop (~11 GB free RAM) and runs PostgreSQL the way it is run in production: operator-managed, spread across failure domains, continuously archived, and recoverable to any point in time.

Every step is documented together with **how it differs from a real on-prem deployment**, so the lab doubles as a reference for production design decisions.

---

## Architecture

```
Laptop (Ubuntu 24.04)
 │
 ├── dummy0: stable lab IP  ← independent of Wi-Fi / VPN (lab equivalent of a VIP)
 │
 └── Docker network: lab-net
      │
      ├── mgmt cluster (k3s, 1 node)
      │    ├── cert-manager
      │    └── Rancher              https://rancher.<LAB_IP>.sslip.io
      │
      ├── work cluster (k3s, 3 nodes) — imported into Rancher
      │    ├── server-0   control-plane (tainted: no workloads)
      │    ├── agent-0    topology.kubernetes.io/zone=zone-a
      │    ├── agent-1    topology.kubernetes.io/zone=zone-b
      │    ├── CoreDNS    local records for Rancher and S3 (no public DNS dependency)
      │    ├── CloudNativePG operator
      │    └── Todo app (Vikunja)   http://todo.<LAB_IP>.sslip.io:8081
      │
      └── s3 container (outside both clusters)
           S3-compatible object storage for backups and WAL archive
           TLS with a lab CA, least-privilege backup user
```

**Why two clusters?** In production the management plane never lives on the cluster it manages — if that cluster fails, the tool to fix it fails with it.

**Why is object storage outside Kubernetes?** Backups must live in a different failure domain than the database. This allows a real disaster-recovery drill later: delete the whole work cluster, rebuild it, restore Postgres from backup.

---

## Stack

| Component | Version | Role |
|---|---|---|
| k3d / k3s | k3s v1.35.8 | Kubernetes clusters as Docker containers |
| Rancher | 2.15.1 | Multi-cluster management |
| cert-manager | v1.21.2 | Certificate issuance and renewal |
| Traefik | bundled with k3s | Ingress controller |
| CloudNativePG | 1.29.x | PostgreSQL operator |
| pgBackRest (Dalibo CNPG-I plugin) | experimental | WAL archiving, backups, PITR |
| PgBouncer (CNPG `Pooler`) | — | Connection pooling |
| pgsty/minio | pinned in `versions.env` | S3-compatible object storage |
| Vikunja | 2.6.0 | Sample stateful application (Todo) |
| Prometheus + Grafana | — | Observability |

All versions are pinned in [`versions.env`](versions.env) — the lab's Bill of Materials.

---

## Progress

- [x] **Part 1 — Clusters and Rancher:** version selection against the support matrix, mgmt cluster, cert-manager, Rancher, work cluster with zones, cluster import
- [x] **Part 2 — Todo application:** Deployment, Service, Ingress, probes, resource requests/limits, and a pod-death experiment showing why state must leave the pod
- [x] **Part 3.1 — Persistent volumes:** StorageClass/PVC/PV behaviour under pod death, node death and PVC deletion
- [x] **Part 3.2 — Object storage:** TLS with a private CA, dedicated bucket, least-privilege IAM policy, in-cluster DNS
- [ ] **Part 3.3–3.4 — CloudNativePG operator and pgBackRest plugin** *(in progress)*
- [ ] **Part 4 — PostgreSQL:** primary + standby across zones, WAL archiving designed for PITR, PgBouncer, Todo migrated to Postgres
- [ ] **Part 5 — Delayed replica (10 min) and recovery drills:** recovering from an accidental `DELETE`
- [ ] **Part 6 — Prometheus and Grafana:** cluster, PostgreSQL and backup monitoring

---

## Key Design Decisions

| Decision | Reasoning |
|---|---|
| **k3s v1.35 instead of the newest supported release** | N-1 principle: inside Rancher's support matrix (1.34–1.36) but leaves headroom for other components' compatibility matrices (CNPG, backup plugin, monitoring). Upgrade path to 1.36 stays open. |
| **Stable IP on a dummy interface** | Rancher's server URL is baked into every downstream agent. An IP tied to Wi-Fi or VPN breaks every cluster when it changes. |
| **Local DNS records in CoreDNS** | A downstream agent once failed after a routine redeploy because the in-cluster resolver could not reach the public wildcard DNS service. Internal services must not depend on public DNS. |
| **Control-plane taint** | Workloads run only on agent nodes, matching production control-plane isolation. |
| **Zone labels on agent nodes** | Lets CloudNativePG place primary and standby in different failure domains; the same manifests work unchanged on real racks or data centres. |
| **pgsty/minio instead of MinIO** | Upstream MinIO community edition stopped publishing images in late 2025 and was archived in 2026. The fork is maintained by a PostgreSQL-focused team that uses the same MinIO + pgBackRest combination. Lesson: evaluate licence, maintainer and exit path before depending on infrastructure software. |
| **Dalibo pgBackRest plugin** | The only CNPG-I pgBackRest plugin supporting PITR and log-shipping secondaries, which the delayed-replica design needs. It is experimental; for production today, CNPG's Barman Cloud plugin or Crunchy PGO (native pgBackRest) are the safer choices. The backup design is identical in all three. |
| **TLS with a private CA, not `--insecure`** | pgBackRest requires HTTPS for S3. Clients trust only the lab CA, mirroring an internal enterprise CA. |
| **Least-privilege backup user** | The backup user can read, write and delete objects in one bucket only — no bucket creation, no admin API. Verified by testing what must fail, not only what must succeed. |
| **Templated manifests** | No IPs or secrets in the repository. Manifests use `${VARIABLES}` rendered by a restricted `envsubst`; secrets go to the cluster via `kubectl create secret`, never into YAML files. |

---

## Repository Layout

```
.
├── versions.env                  # Pinned versions (Bill of Materials)
├── config/
│   └── lab.env.example           # IPs and hostnames — copy to config/lab.env (git-ignored)
├── scripts/
│   ├── lab.sh                    # Source me: loads config, defines render/kapply/kdiff/mcl
│   └── fix-images.sh             # Pull stuck images on the host and import into k3d nodes
├── manifests/
│   ├── cluster/                  # Cluster-level config (CoreDNS custom records)
│   ├── lab/                      # Experiments (PV behaviour)
│   └── todo/                     # Namespace, Deployment, Service, Ingress
└── object-storage/
    ├── ca/ca.crt                 # Lab CA public certificate
    ├── mc-config/pgbackrest-policy.json
    └── *.env.example             # Credential templates (real files are git-ignored)
```

---

## Getting Started

**Prerequisites:** Docker, k3d, kubectl, helm, jq, envsubst, and a stable local IP (for example a dummy interface).

```bash
git clone git@github.com:<USERNAME>/rancher-lab.git ~/rancher-lab
cd ~/rancher-lab

cp config/lab.env.example config/lab.env                                  # set LAB_IP
cp object-storage/s3.env.example object-storage/s3.env                     # set credentials
cp object-storage/pgbackrest-s3.env.example object-storage/pgbackrest-s3.env

source scripts/lab.sh
```

**Helpers provided by `scripts/lab.sh`:**

```bash
render manifests/todo/30-ingress.yaml        # print a rendered template
kdiff  work manifests/todo/*.yaml            # show what would change in the cluster
kapply work manifests/todo/*.yaml            # render and apply to cluster k3d-work
mcl    ls lab                                # S3 client (containerised)
```

Only variables defined in `versions.env` and `config/lab.env` are substituted — never secrets, never any other `$`.

---

## Lessons Learned

Real problems hit while building the lab, and what they teach about production:

| Problem | Root cause | Takeaway |
|---|---|---|
| Image pulls never finished | Slow link + parallel layer downloads each timing out | High concurrency on a thin link means nothing completes. Pre-pull images; in production, use an internal registry. |
| Docker's download limit was ignored | Docker's containerd image store ignores `max-concurrent-downloads` | Know your runtime; switching image stores hides existing containers and images. |
| Cluster "disappeared" | The image-store switch above | Changing the container runtime is destructive — decide before building clusters. |
| Nodes couldn't see host images | Each k3d node runs its own containerd | `docker pull` + `k3d image import` is a miniature air-gapped workflow. |
| `helm install` reported failure, but pods came up | Helm's wait timeout expired; Kubernetes kept reconciling | A timeout is not a failure. Check pods before uninstalling. |
| Dozens of failing `helm-operation` pods | Rancher retrying installs while images were missing | Reconciliation in action — the system retries until desired state is reached. |
| Downstream cluster went `Unavailable` after a taint | Rancher redeployed its agent; the new pod couldn't resolve Rancher's hostname | The taint only *revealed* a hidden DNS dependency. Systems can look healthy until the first restart. |
| All Todo data lost after deleting a pod | SQLite on an `emptyDir` volume | Pods are disposable. Separate state from the application. |
| Pod stuck `Pending` after its node stopped | `local-path` PVs have node affinity | Local storage survives pod death, not node death — CNPG compensates with Postgres-level replication across nodes. |
| A secret appeared in shared terminal output | Secret scanner run without `--redact` | Leaks usually come from logs, tickets and chat, not attacks. Any exposed secret gets rotated. |

---

## Lab vs. On-Prem

| Topic | This lab | Production on-prem |
|---|---|---|
| Nodes | Containers on one laptop | Separate VMs or bare metal |
| Control plane | 1 node, tainted | 3 nodes, tainted, etcd quorum |
| Load balancer | k3d's nginx proxy | HAProxy + keepalived, or F5 |
| `LoadBalancer` Services | klipper | MetalLB or kube-vip |
| Addresses | sslip.io on a dummy interface | Internal DNS on a VIP; wildcard for apps |
| Certificates | Self-signed / lab CA | Enterprise CA (Vault, AD CS) |
| Images | `k3d image import` | Harbor: pre-loaded, scanned, signed, pinned by digest |
| Deployment | `kapply` | GitOps (Fleet / Argo CD) |
| Downstream clusters | Imported | Provisioned from Rancher (RKE2) |
| Object storage | One container | Erasure-coded cluster or Ceph RGW in a separate site, with Object Lock |
| Secrets | Git-ignored files | Vault / External Secrets / SOPS, with rotation |
| Access | Local admin | LDAP/AD, RBAC, MFA, audit logging |

---

## Security

- No secrets or IPs are committed; see [`.gitignore`](.gitignore).
- Before each commit, staged content is scanned with [gitleaks](https://github.com/gitleaks/gitleaks):

```bash
git add -A
docker run --rm -v "$PWD:/repo" -w /repo \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  zricethezav/gitleaks:latest git --pre-commit --staged --redact --verbose /repo
```

---

## Roadmap

- Migrate templating from `envsubst` to Kustomize overlays
- Deploy manifests from this repository with Rancher Fleet (GitOps)
- Full disaster-recovery drill: destroy the work cluster, rebuild, restore PostgreSQL from object storage
- Pre-commit hook for secret scanning
