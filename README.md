# learn-cncf-gitops

Argo CD manages a Postgres platform on EKS, and an app that ships bundled with its own database.

Nothing here is applied by hand except one bootstrap manifest. Everything else arrives by pushing to this repo.

## Layout

```
bootstrap/root-app.yaml     the only thing you kubectl apply
platform/                   one Argo CD Application per platform component
charts/app-with-db/         the blueprint -- generic, not tied to any one app
apps/<name>/                one deployed instance of that blueprint
    application.yaml            the Argo CD Application
    values.yaml                 your configuration
```

The chart is a **blueprint**; `apps/<name>/` is an **instance** of it. Adding a second application means creating a new directory with two files — no change to the chart, the platform, or anything else.

## How it fits together

```
kubectl apply bootstrap/root-app.yaml
        │
        ▼
   Application "root"  ──watches──▶  platform/*.yaml
        │
        ├─ wave 0  cert-manager      (helm: jetstack)
        ├─ wave 0  cnpg-operator     (helm: cloudnative-pg)
        ├─ wave 1  barman-plugin     (helm: cloudnative-pg)  needs cert-manager CRDs
        └─ wave 2  apps-root  ──watches──▶  apps/*/application.yaml
                     │
                     └─ notes  ──renders──▶  charts/app-with-db
                                             + apps/notes/values.yaml
                          │
                          ├─ CNPG Cluster    3 instances, synchronous replication
                          ├─ ObjectStore     S3 backups (optional)
                          ├─ Deployment      the app
                          └─ Service
```

Two levels of *app of apps*: `root` manages the platform, `apps-root` manages user applications. Both are just Applications whose rendered resources happen to be Applications.

`apps-root` filters with `directory.include: "*/application.yaml"` — without it Argo would try to apply each `values.yaml` as a Kubernetes manifest.

### How an app gets its values

`apps/notes/application.yaml` declares **two sources**:

```yaml
sources:
  - repoURL: <this repo>
    path: charts/app-with-db          # the chart
    helm:
      valueFiles:
        - $values/apps/notes/values.yaml
  - repoURL: <this repo>
    ref: values                        # contributes no manifests
```

The second source produces nothing; `ref: values` exists purely to give the first source a handle (`$values`) for reading files elsewhere in the repo. That's how the chart stays generic while its configuration lives next to the app.

## Adding another app

```bash
mkdir -p apps/reports
cp apps/notes/values.yaml apps/reports/values.yaml
sed -e 's/notes/reports/g' apps/notes/application.yaml > apps/reports/application.yaml
git add apps/reports && git commit -m "Add reports app" && git push
```

`apps-root` picks it up and creates the Application, its Postgres cluster, and its app. Note the release name drives resource names, so `reports` gets `Cluster/reports-db` — which needs its own EKS Pod Identity association if you enable backups.

### Sync waves

Argo CD applies resources in ascending wave order and waits for each wave to report healthy before starting the next. That is how ordering dependencies are expressed without any imperative scripting:

- cert-manager and the CNPG operator have no dependencies — wave 0.
- The barman plugin creates `Certificate` resources, so cert-manager's CRDs must already exist — wave 1.
- User apps create `Cluster` resources, a type that does not exist until the CNPG operator's CRDs are installed — so `apps-root` is wave 2.

Within the chart the same mechanism orders `ObjectStore` (wave -1) before `Cluster` (wave 0) before the app `Deployment` (wave 1).

### ServerSideApply

Every Application sets `ServerSideApply=true`. The CNPG and cert-manager CRDs are far larger than the ~256KB limit on the annotation that client-side apply uses to track state. Without it, sync fails outright.

## Bootstrap

Argo CD itself is installed with Helm, once, outside git — the usual chicken-and-egg:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.2.2 --set configs.params."server\.insecure"=true --wait
```

Then hand it the root application:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

From here on, `git push` is the only interface.

### Reaching the UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Open http://localhost:8080, user `admin`.

## The chart

`charts/app-with-db` bundles an application with a CloudNativePG cluster. The app is [PostgREST](https://postgrest.org), which exposes the database as a REST API — a small stand-in for "an app that needs a database".

A user of this chart edits `apps/<name>/values.yaml` and pushes. Common knobs:

```yaml
app:
  replicas: 2
database:
  instances: 3
  storage:
    size: 5Gi
  synchronous:
    enabled: true
    number: 1
backup:
  enabled: false
  destinationPath: ""
```

Full list in `charts/app-with-db/values.yaml`.

### What the chart wires up for you

- CNPG generates the database password and stores it in `<release>-db-app`. The app reads the `uri` key from that Secret directly — no secret is ever written to git.
- That URI points at the `-rw` Service, so it follows failover automatically.
- `postInitApplicationSQL` seeds a `notes` table and the read-only role PostgREST needs.
- A guard rail fails the render if `database.instances < database.synchronous.number + 2`, the configuration where losing one replica blocks every write.

### Backups

`backup.enabled: true` adds an `ObjectStore` and attaches the barman-cloud plugin for continuous WAL archiving and base backups to S3.

Authentication uses EKS Pod Identity, so no credentials appear anywhere. It requires an IAM role associated with the ServiceAccount CNPG creates, which is named after the database cluster — `notes-db` for the `notes` release. See the terraform in the companion `learn-cncf-psql` repo.

## Try it

```bash
kubectl -n notes get cluster
kubectl -n notes get pods -L cnpg.io/instanceRole

kubectl -n notes port-forward svc/notes 8080:80
curl localhost:8080/notes
curl localhost:8080/notes -H 'Content-Type: application/json' -d '{"body":"written over http"}'
```

Kill the primary and watch the app keep serving:

```bash
kubectl -n notes delete pod notes-db-1
```
