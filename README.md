# Internal Utility Service

A production-hardened Flask web service demonstrating containerization,
secure CI/CD, automated deployment, and zero-downtime updates on AWS EC2.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Local Development](#local-development)
4. [Dockerfile Structure](#dockerfile-structure)
5. [Multi-Stage Build Reasoning](#multi-stage-build-reasoning)
6. [CI/CD Pipeline](#cicd-pipeline)
7. [Docker Image Tagging Strategy](#docker-image-tagging-strategy)
8. [Secret Management](#secret-management)
9. [EC2 Deployment](#ec2-deployment)
10. [HTTPS Setup](#https-setup-lets-encrypt)
11. [Blue-Green Deployment Strategy](#blue-green-deployment-strategy)
12. [Rollback Procedure](#rollback-procedure)
13. [Health Monitoring](#health-monitoring)
14. [Failure Simulation](#failure-simulation)
15. [Scaling Strategy](#scaling-strategy)
16. [Security Considerations](#security-considerations)
17. [Trade-offs](#trade-offs)
18. [Reflection Questions](#reflection-questions)
19. [GitHub Secrets Required](#github-secrets-required)

---

## Architecture Overview

```
Developer pushes to main
        │
        ▼
┌───────────────────┐
│   GitHub Actions  │  1. Lint (flake8) + Test (pytest)
│   CI/CD Pipeline  │  2. Build multi-stage Docker image
│                   │  3. Push to Docker Hub (3 tags)
│                   │  4. SSH to EC2 and run deploy.sh
└───────────────────┘
        │
        ▼ (SSH)
┌──────────────────────────────────────────────────────┐
│                   AWS EC2 Instance                   │
│                                                      │
│  ┌──────────┐  HTTPS:443  ┌──────────────────────┐  │
│  │  Nginx   │─────────────▶  Let's Encrypt / TLS  │  │
│  │ (reverse │  HTTP:80    └──────────────────────┘  │
│  │  proxy)  │  → redirect                           │
│  └────┬─────┘                                       │
│       │ upstream: 127.0.0.1:5001 or :5002           │
│       ▼                                             │
│  ┌─────────────┐    ┌─────────────┐                 │
│  │  app-blue   │    │  app-green  │  (one active)   │
│  │  :5001      │    │  :5002      │                 │
│  └─────────────┘    └─────────────┘                 │
│                                                      │
│  Secrets: AWS Secrets Manager (via IAM Role)         │
└──────────────────────────────────────────────────────┘
```

| Component | Role |
|---|---|
| GitHub Repository | Source of truth |
| GitHub Actions | CI/CD engine |
| Docker Hub | Image registry (`yuwa619/internal-utility-service`) |
| AWS EC2 (t2.micro) | Compute — runs the containers |
| Nginx | Reverse proxy + TLS termination |
| Let's Encrypt / Certbot | Free SSL certificates with auto-renewal |
| AWS Secrets Manager | Runtime secret storage |

---

## Repository Structure

```
.
├── .github/workflows/ci.yml   # Full CI/CD pipeline
├── nginx/nginx.conf           # Reverse proxy + HTTPS config
├── scripts/
│   ├── deploy.sh              # Blue-green deployment
│   ├── rollback.sh            # One-command rollback
│   └── ec2-setup.sh           # One-time EC2 provisioning
├── tests/
│   └── test_app.py            # 9 pytest tests
├── .dockerignore
├── .env.example               # Template — copy to .env locally
├── .flake8                    # Linter config (max-line-length=88)
├── .gitignore
├── Dockerfile                 # Multi-stage build
├── app.py                     # Flask application
├── config.py                  # Secrets loader (env vars / AWS SM)
├── database.py                # Data layer (no credential leaks)
├── docker-compose.yml         # Local dev stack
├── requirements.txt
└── utils.py                   # Internal utilities
```

---

## Local Development

### Prerequisites

- Docker Desktop
- Python 3.9+

### Quick start

```bash
git clone https://github.com/yuwa619/Internal-utility-service.git
cd Internal-utility-service

# Copy and fill in env template
cp .env.example .env

# Start app + nginx
docker compose up --build

# Run tests (outside Docker)
pip install -r requirements.txt
pytest tests/ -v
```

Endpoints:

| Endpoint | Description |
|---|---|
| `GET /` | Service status and environment |
| `GET /health` | Health check (used by Docker and Nginx) |
| `GET /users` | Returns list of users (no credentials exposed) |

---

## Dockerfile Structure

```
Stage 1 (builder)
  - python:3.9-slim base
  - Creates /opt/venv, installs all pip dependencies
  - pip cache and build tools stay in this stage only

Stage 2 (production)
  - python:3.9-slim base (fresh — no build junk)
  - Install curl (required by HEALTHCHECK)
  - RUN useradd appuser (UID 1001)  ← must happen BEFORE --chown
  - COPY --from=builder /opt/venv   ← only the compiled packages
  - COPY --chown=appuser:appuser .  ← source, owned by non-root user
  - ENV PATH includes /opt/venv/bin
  - USER appuser                    ← drop root privileges
  - EXPOSE 5000
  - HEALTHCHECK → GET /health
  - CMD: gunicorn (production WSGI server)
```

Key decisions:

- **User before COPY** — `--chown` requires the user to exist at build time.
  The original Dockerfile had this backwards, causing a build-time error.
- **Gunicorn instead of `python app.py`** — The Flask dev server is
  single-threaded and explicitly warns against production use.
- **`PYTHONUNBUFFERED=1`** — Logs stream to stdout immediately, visible
  via `docker logs` without buffering delays.
- **Single `RUN` for apt** — Combines `update`, `install`, and cleanup in
  one layer so the apt cache is never baked into the image.

---

## Multi-Stage Build Reasoning

A single-stage build would include pip, gcc (pulled by some packages),
the pip download cache, and test tools (pytest, flake8) — none of which
are needed at runtime. They increase image size and add CVE exposure.

A two-stage build keeps the production image lean:

- Builder installs everything into an isolated venv
- Production copies only the compiled venv — test tools and caches are
  discarded automatically

Result: smaller image, faster pulls, smaller blast radius from any
dependency vulnerability.

---

## CI/CD Pipeline

File: `.github/workflows/ci.yml`

```
push or PR to main
       │
  ┌────▼────┐
  │  test   │  flake8 lint → pytest (all 9 tests must pass)
  └────┬────┘
       │ only if tests pass AND branch == main
  ┌────▼────┐
  │  build  │  docker buildx → Docker Hub (latest, v1.0.0, sha-XXXXXXX)
  └────┬────┘
       │
  ┌────▼────┐
  │ deploy  │  SSH into EC2 → git pull → deploy.sh (blue-green)
  └─────────┘
```

The `test` job runs on all branches and PRs. The `build` and `deploy`
jobs run only on direct pushes to `main`, ensuring PRs are validated
before anything reaches Docker Hub or EC2.

Secrets never appear in logs: GitHub masks all registered secret values
automatically.

---

## Docker Image Tagging Strategy

Every push to `main` produces three tags:

| Tag | Example | Purpose |
|---|---|---|
| `latest` | `yuwa619/internal-utility-service:latest` | Always the newest main build. Used by deploy.sh. |
| Semantic version | `yuwa619/internal-utility-service:v1.0.0` | Human-readable release marker. Update in `ci.yml` per release. |
| Commit SHA | `yuwa619/internal-utility-service:sha-a3f1c9b` | Immutable. Enables rollback to any exact commit. |

Using only `latest` makes it impossible to audit exactly what code is
running. The SHA tag provides that guarantee.

---

## Secret Management

### Where secrets live

| Secret | Stored in | Used by |
|---|---|---|
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | GitHub Secrets | CI build step |
| `EC2_HOST`, `EC2_USERNAME`, `EC2_SSH_KEY` | GitHub Secrets | CI deploy step |
| `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | **AWS Secrets Manager** | Application at runtime |

### Runtime flow

1. EC2 instance has an **IAM Role** with `secretsmanager:GetSecretValue`
   on the specific secret — no long-lived access keys on the instance.
2. On startup, `config.py` checks `AWS_SECRETS_MANAGER_SECRET_NAME`.
   If set, it calls Secrets Manager and populates `DB_*` variables.
   If not set (local dev), it falls back to plain environment variables.

### Why the split?

**GitHub Secrets** are the right home for CI/CD credentials (SSH keys,
registry tokens) — they are scoped to the pipeline and never touch the
running application.

**AWS Secrets Manager** is the right home for runtime application secrets
because it supports rotation, versioning, fine-grained IAM policies, and
audit logging. The application never holds credentials statically.

### What is never in source

- No hardcoded values in `config.py` (this was the original bug — fixed)
- No `ENV` or `ARG` secrets in `Dockerfile`
- `.env` is in `.gitignore`
- `docker build` uses `--no-cache-dir`; pip cache is never committed

---

## EC2 Deployment

### One-time provisioning

```bash
# On a fresh Ubuntu 22.04 EC2 instance
chmod +x scripts/ec2-setup.sh
sudo bash scripts/ec2-setup.sh
```

Installs: Docker, Nginx, Certbot, Git. Clones the repo to
`/opt/internal-utility-service`. Configures the Nginx site.

### Security Group (firewall)

| Port | Source | Reason |
|---|---|---|
| 22 | Your IP only | SSH |
| 80 | 0.0.0.0/0 | HTTP (redirects to HTTPS) |
| 443 | 0.0.0.0/0 | HTTPS |
| All others | — | Blocked |

### Auto-restart

Containers run with `--restart unless-stopped`. Docker automatically
restarts them on crash without any manual intervention.

### Automated deployment (zero manual SSH)

Every push to `main` runs the GitHub Actions `deploy` job which SSHes
in and runs `deploy.sh`. No human intervention is required.

---

## HTTPS Setup (Let's Encrypt)

### Prerequisites

- Domain name with an A record pointing to the EC2 public IP
- Port 80 open (for ACME challenge)

### Steps

```bash
# 1. Edit nginx.conf — replace YOUR_DOMAIN_OR_IP
sudo nano /etc/nginx/sites-available/internal-utility-service

# 2. Reload Nginx
sudo nginx -s reload

# 3. Obtain certificate
sudo certbot --nginx -d yourdomain.com \
    --non-interactive --agree-tos -m you@email.com

# 4. Verify auto-renewal
sudo certbot renew --dry-run
```

Certbot automatically updates `nginx.conf` with SSL certificate paths
and configures the HTTP → HTTPS redirect.

**Auto-renewal** runs via both the `certbot.timer` systemd unit and a
cron entry added by `ec2-setup.sh` (daily at 03:00).

---

## Blue-Green Deployment Strategy

Two containers run on different host ports:

```
Blue  → 127.0.0.1:5001  (container: internal-utility-blue)
Green → 127.0.0.1:5002  (container: internal-utility-green)
```

Nginx upstream always points to one port at a time.

### Deployment sequence (`scripts/deploy.sh`)

```
1. Pull new image from Docker Hub
2. Identify inactive colour (opposite of current)
3. Start inactive colour with new image
4. Poll /health every 2 s until 200 OK (max 60 s)
5. Rewrite Nginx upstream port + reload Nginx  ← atomic cutover
6. Stop and remove old container
7. Record new active colour to ACTIVE_COLOR file
```

### Zero downtime

Step 5 uses `nginx -s reload` which is graceful: Nginx finishes serving
in-flight requests on the old upstream before draining it. Users never
see a gap.

### Rollback metadata

Before the cutover, `deploy.sh` records the previous image tag, colour,
and port. `rollback.sh` reads these files to reverse the deployment.

---

## Rollback Procedure

```bash
# On the EC2 instance:
sudo bash /opt/internal-utility-service/scripts/rollback.sh
```

`rollback.sh`:
1. Reads `PREVIOUS_IMAGE`, `PREVIOUS_COLOR`, `PREVIOUS_PORT`
2. Restarts the previous container with the known-good image
3. Waits for health check
4. Switches Nginx upstream back
5. Stops the broken container

To roll back to any specific commit:

```bash
docker pull yuwa619/internal-utility-service:sha-<COMMIT_SHA>
# Edit PREVIOUS_IMAGE with the SHA tag, then run rollback.sh
```

---

## Health Monitoring

### Docker HEALTHCHECK

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1
```

After 3 consecutive failures Docker marks the container **unhealthy** and
restarts it (due to `--restart unless-stopped`).

### Checking health status

```bash
# Container health state
docker inspect --format='{{.State.Health.Status}}' internal-utility-blue

# Restart count (should be 0 on a healthy host)
docker inspect --format='{{.RestartCount}}' internal-utility-blue

# Live logs
docker logs -f internal-utility-blue
```

### What happens when the container fails

1. Process crashes → container exits
2. Docker detects exit → restarts within 2–5 s
3. During restart, Nginx returns **502 Bad Gateway**
4. New container passes health check → Nginx resumes routing
5. Blue-green ensures a new deployment never takes the live port until
   the new container is confirmed healthy

---

## Failure Simulation

### 1. Test failure blocks build

Break a test temporarily, push to `main`. The `test` job fails; `build`
and `deploy` are never triggered.

```python
def test_home_returns_200(client):
    assert client.get("/").status_code == 999  # will fail
```

### 2. Container crash and auto-restart

```bash
# Kill the main process inside the running container
docker exec internal-utility-blue kill 1
# Docker restarts it automatically — observe:
watch docker ps
```

### 3. Missing secret

Remove `DB_PASSWORD` from `.env` and restart the container.
`config.py` sets `DB_PASSWORD` to an empty string; the application
starts and serves traffic, but a real DB query would fail with a
connection error — not a silent crash.

### 4. Deployment rollback

After a bad deploy (health check fails → `deploy.sh` exits non-zero):

```bash
sudo bash /opt/internal-utility-service/scripts/rollback.sh
```

Traffic returns to the last known-good container within seconds.

---

## Scaling Strategy

**Horizontal scaling on EC2:**

1. Add an AWS Application Load Balancer (ALB) in front of 2+ EC2 instances
2. ALB health checks hit `/health` — unhealthy instances are removed
3. An Auto Scaling Group adds/removes instances based on CPU metrics
4. GitHub Actions deploys to each instance using a matrix strategy or
   AWS Systems Manager Run Command (no SSH key distribution needed)

**Migration path to Kubernetes:**

```
Current  →  Docker + Nginx on EC2
Step 1   →  AWS ECS Fargate (managed, no EC2 patching)
Step 2   →  Amazon EKS (Kubernetes)
             - Same Docker image, zero changes to app code
             - Add Deployment + Service + HPA manifests
             - kubectl set image replaces the SSH deploy step
             - Secrets Store CSI Driver for AWS Secrets Manager integration
```

---

## Security Considerations

### Hardened

- Container runs as UID 1001 (never root)
- No secrets in source, Dockerfile, or image layers
- Debug mode disabled in production
- No credential leakage in API responses
- Security headers in Nginx (HSTS, X-Frame-Options, nosniff, XSS)
- Minimal open ports (22 restricted, 80, 443 only)
- IAM Role instead of long-lived access keys

### Remaining risks

| Risk | Mitigation |
|---|---|
| Single EC2 instance | Add ALB + Auto Scaling Group |
| No image CVE scanning | Add Trivy or Snyk to CI pipeline |
| No WAF | AWS WAF on ALB for SQL injection / DDoS |
| SSH key in GitHub Secrets | Rotate periodically; use SSM Session Manager instead |
| No Nginx rate limiting | Add `limit_req_zone` directive |

---

## Trade-offs

| Decision | Alternative | Reason chosen |
|---|---|---|
| Blue-green (2 containers) | Rolling update | Simpler on a single EC2; instant atomic cutover |
| System-level Nginx | Nginx in Docker | Certbot integrates more easily with system Nginx |
| AWS Secrets Manager | HashiCorp Vault | Native AWS; no extra service to operate |
| Gunicorn (2 workers) | uWSGI | Simpler config; adequate for internal service |
| `python:3.9-slim` base | Alpine | Better glibc compatibility; fewer pip build failures |
| Free-tier t2.micro | Larger instance | Cost constraint; scales via ASG when needed |

---

## Reflection Questions

**1. Why did you structure the Dockerfile the way you did?**

The non-root user is created before `COPY --chown` so Docker can resolve
ownership at build time (the original Dockerfile had this backwards). Curl
is installed in a single `RUN` that also purges the apt cache, keeping the
layer lean. Gunicorn is used as the CMD because the Flask dev server is
single-threaded and warns against production use. All config is injected
at runtime via environment variables, not baked into the image.

**2. Why multi-stage?**

The builder stage installs pip, build tools, and dev dependencies (pytest,
flake8) that are never needed at runtime. Multi-stage discards all of that
in the production stage, producing a smaller, lower-CVE image.

**3. Why that tagging strategy?**

`latest` is convenient for automated scripts. The semantic version
communicates intentional releases. The SHA tag provides an immutable
reference that makes any past deployment reproducible for debugging,
audits, or rollback.

**4. Why GitHub Secrets + AWS Secrets Manager split?**

GitHub Secrets hold deployment credentials (SSH keys, registry tokens)
scoped to the CI pipeline. AWS Secrets Manager holds runtime credentials
(database passwords) that the application reads via an IAM Role — no
long-lived keys exist on disk or in environment files on EC2. Rotating
a database password only requires updating the Secrets Manager value; the
application picks it up on next restart without any code change.

**5. How does your deployment avoid downtime?**

The new container starts and passes the `/health` check before Nginx
switches the upstream port. `nginx -s reload` is graceful: it drains
in-flight requests on the old upstream before discarding it. The user
sees no gap.

**6. How would you scale to multiple EC2 instances?**

Place an AWS ALB in front of two or more instances in an Auto Scaling
Group. The ALB's target group uses `/health` as its health check path.
The GitHub Actions deploy job uses a matrix to SSH into each instance
(or uses AWS Systems Manager Run Command to avoid managing SSH keys at
scale).

**7. What security risks still exist?**

No WAF, no image vulnerability scanning in CI, no Nginx rate limiting,
single SSH key for all deployments, no multi-AZ redundancy, and no
audit trail for Secrets Manager access patterns.

**8. How would you evolve this into Kubernetes?**

1. Push the same Docker image to Amazon ECR
2. Write a `Deployment` manifest with `strategy: RollingUpdate`
3. Write a `Service` of type `LoadBalancer` or add an `Ingress` with
   cert-manager for TLS
4. Use the Secrets Store CSI Driver to mount AWS Secrets Manager values
   as environment variables — the application code changes nothing
5. Replace the SSH deploy step with `kubectl set image`
6. Add a `HorizontalPodAutoscaler` for traffic-based scaling

---

## GitHub Secrets Required

Configure these in **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password) |
| `EC2_HOST` | Public IP or hostname of the EC2 instance |
| `EC2_USERNAME` | SSH user (`ubuntu` for Ubuntu AMI) |
| `EC2_SSH_KEY` | Full contents of the EC2 `.pem` private key file |
