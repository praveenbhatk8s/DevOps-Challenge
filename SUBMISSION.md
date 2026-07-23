# TradeByte DevOps Challenge — Submission

## Overview

This submission containerises the demo Tornado/Redis application and deploys it to a local Kubernetes cluster (minikube) in a production-ready, scalable, and secure manner.

---

## What Was Built

| File | Purpose |
|------|---------|
| `Dockerfile` | Containerises the Python app as a non-root user |
| `requirements.txt` | Updated dependency versions (see note below) |
| `k8s/namespace.yaml` | Dedicated namespace `devops-challenge` |
| `k8s/secret.yaml` | All environment variables stored as a Kubernetes Secret |
| `k8s/redis.yaml` | Redis Deployment + ClusterIP Service |
| `k8s/deployment.yaml` | App Deployment — 3 replicas, resource limits, health probes |
| `k8s/service.yaml` | ClusterIP Service exposing port 80 → 8000 |
| `k8s/hpa.yaml` | HorizontalPodAutoscaler — scales 3–10 replicas on CPU > 70% |
| `k8s/ingress.yaml` | Ingress rule routing `devops-challenge.local` to the service |

---

## Dependency Version Changes (`requirements.txt`)

| Package | Original | Updated | Reason |
|---------|----------|---------|--------|
| `tornado` | `5.1.1` | `6.4` | Tornado 5.x uses `collections.MutableMapping` which was **removed in Python 3.10**. Running the app on Python 3.11 caused an immediate `AttributeError` crash on import. Tornado 6.x migrated to `collections.abc.MutableMapping` and is fully Python 3.10+ compatible. |
| `redis` | `3.0.1` | `4.6.0` | Redis-py 3.x is end-of-life and has known compatibility issues on Python 3.10+. Version 4.x is the current stable release, maintains the same API (`r.set`, `r.incr`) used by `hello.py`, and receives active security patches. |

The error observed before the fix:
```
File "/usr/local/lib/python3.11/site-packages/tornado/httputil.py", line 107, in <module>
    class HTTPHeaders(collections.MutableMapping):
AttributeError: module 'collections' has no attribute 'MutableMapping'
```

---

## 1. Containerisation

**File:** [`Dockerfile`](Dockerfile)

```dockerfile
https://github.com/praveenbhatk8s/DevOps-Challenge/blob/master/Dockerfile
```

**Decisions:**
- `python:3.11-slim` — minimal attack surface; no build tools included.
- `--no-cache-dir` — keeps the image layer small.
- Non-root user (`appuser`) — principle of least privilege; a container running as root can escalate to host root if there is a container escape.
- `EXPOSE 8000` documents the contract; the actual binding comes from the env var `PORT`.

---

## 2. Kubernetes Cluster Setup

**Tool:** minikube (single-node local cluster)

```bash
minikube start --cpus=2 --memory=4096
minikube addons enable metrics-server   # required for HPA
eval $(minikube docker-env)             # build image inside minikube
docker build -t devops-challenge:local .
```

**Deploy all manifests:**
```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/ingress.yaml
```

---

## 3. Replicas — Minimum 3

**File:** [`k8s/deployment.yaml`](k8s/deployment.yaml)

```yaml
spec:
  replicas: 3
```

The HPA `minReplicas: 3` enforces this floor even under scale-down pressure. All 3 replicas share the same Redis instance, so the hit counter is consistent regardless of which pod handles a request.

---

## 4. Autoscaling on CPU

**File:** [`k8s/hpa.yaml`](k8s/hpa.yaml)

```yaml
spec:
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

- Scales between 3 and 10 replicas.
- Triggers when average CPU across all pods exceeds 70%.
- Uses `autoscaling/v2` (the current stable API).
- CPU `requests: 100m` on the Deployment is mandatory — the HPA calculates utilisation as `current usage / request`; without a request value the HPA cannot function.

---

## 5. Secure Environment Variable Handling

**File:** [`k8s/secret.yaml`](k8s/secret.yaml)

All six environment variables the app reads (`ENVIRONMENT`, `HOST`, `PORT`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_DB`) are stored in a Kubernetes `Secret`.

```yaml
https://github.com/praveenbhatk8s/DevOps-Challenge/blob/master/k8s/secret.yaml
```

The Deployment loads them via `envFrom`:
```yaml
envFrom:
- secretRef:
    name: app-config
```

**Why Secrets over ConfigMaps for this:**
- Secrets are base64-encoded at rest and can be encrypted at rest with KMS in production.
- RBAC can restrict Secret access independently of ConfigMap access.
- In production, this Secret would be managed by an external secrets operator (e.g. External Secrets Operator with AWS Secrets Manager / HashiCorp Vault) so the raw values never live in Git.

---

## 6. Scalability and Performance

**Resource requests and limits** on the app container:
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

- `requests` — used by the scheduler for bin-packing pods across nodes and by the HPA for utilisation calculations.
- `limits` — prevent a single pod from starving neighbours (noisy-neighbour protection).

**Redis** is the shared state store for the hit counter, meaning all app replicas read/write the same counter correctly — no in-memory state that would give inconsistent counts across pods.

**Health probes** ensure traffic only reaches healthy pods:
```yaml
readinessProbe:
  httpGet:
    path: /
    port: 8000
  initialDelaySeconds: 5
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 30
```

- `readinessProbe` — pod only enters the Service's endpoint list once it returns HTTP 200. Prevents traffic being sent to pods still connecting to Redis.
- `livenessProbe` — Kubernetes restarts a pod if it becomes unresponsive (e.g. deadlock).

---

## 7. Verification

```bash
# All pods running
kubectl -n devops-challenge get pods

# Deployment healthy
kubectl -n devops-challenge get deploy

# HPA active and watching
kubectl -n devops-challenge get hpa

# Access the app
kubectl -n devops-challenge port-forward svc/devops-challenge 8080:80
curl http://localhost:8080

# Run tests
python tests/test.py
```

---

## Production Considerations

| Concern | Current (minikube) | Production recommendation |
|---------|-------------------|--------------------------|
| Secrets management | `kind: Secret` in YAML | External Secrets Operator + AWS Secrets Manager / Vault; secrets never in Git |
| Redis availability | Single replica | Redis Sentinel or Redis Cluster for HA; or managed service (ElastiCache) |
| Image registry | Local minikube docker | ECR / GCR / Harbor with image scanning (Trivy) on push |
| TLS | Ingress without TLS | cert-manager + Let's Encrypt ClusterIssuer |
| Observability | None | Prometheus scraping `/metrics`, Grafana dashboards, structured JSON logging |
| Rolling updates | Default (maxSurge 25%) | Explicitly set `RollingUpdate` strategy; canary releases via Argo Rollouts |
| Network policy | None | `NetworkPolicy` to restrict pod-to-pod traffic to only app → redis on port 6379 |
