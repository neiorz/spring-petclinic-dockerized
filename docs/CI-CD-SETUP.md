# Spring PetClinic — CI/CD Pipeline Setup Guide

This documents the 7-stage GitHub Actions pipeline defined in
`.github/workflows/deploy.yml`, plus every credential, secret and service it needs.

---

## 1. Pipeline overview

| # | Job (in the workflow) | What it does | Fails the run? |
|---|------------------------|--------------|----------------|
| 1 | `build-and-test` | `./mvnw clean verify` — compile + unit/integration tests, upload JAR & reports | **Yes** |
| 2 | `sonarqube-analysis` | SonarQube static analysis | **No — warning only** (`continue-on-error: true`) |
| 3 | `trivy-scan` | Trivy fs scan + container image scan | **No — warning only** (`exit-code: 0` + `continue-on-error: true`) |
| 4 | `nexus-push` | `docker build`, login to Nexus, push `<:sha>` + `:latest` | **Yes** |
| 5 | `deploy-local` | `docker compose pull app` + `up -d app mysql`, wait for `/actuator/health` | **Yes** |
| 6 | `monitoring` | `docker compose up -d prometheus grafana`, verify scrape target + Grafana | **Yes** (Prometheus/Grafana must come up) |
| 7 | `smoke-tests` | `scripts/smoke-test.sh` — 14 assertions incl. a real DB write | **Yes** |

Jobs are chained with `needs:`, so they always run in the order above.

> **Why a self-hosted runner?** Jobs 4–7 must reach the *local* Docker daemon,
> the local Nexus and the local Prometheus/Grafana. A GitHub-hosted runner could
> not see any of them. All jobs use `runs-on: self-hosted`.

### Files

| File | Purpose |
|------|---------|
| `.github/workflows/deploy.yml` | The pipeline (7 jobs) |
| `docker-compose.yml` | app + MySQL (+ optional PostgreSQL) + Prometheus + Grafana + Nexus |
| `prometheus.yml` | Scrapes `/actuator/prometheus` from the `app` service |
| `grafana/provisioning/datasources/prometheus.yml` | Auto-creates the Prometheus datasource in Grafana |
| `scripts/smoke-test.sh` | Stage 7 |
| `pom.xml` | Added `io.micrometer:micrometer-registry-prometheus` — **required**, without it `/actuator/prometheus` returns 404 |

---

## 2. GitHub Secrets

**Repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret | Example value | Required? | Used by |
|--------|---------------|-----------|---------|
| `NEXUS_USER` | `admin` | **Yes** | Stage 4 (login + reachability check) |
| `NEXUS_PASSWORD` | `s3cr3t` | **Yes** | Stage 4 |
| `NEXUS_URL` | `http://localhost:8081` | Recommended | Manual checks / UI link (not read by the workflow) |
| `SONAR_HOST_URL` | `http://localhost:9000` | Optional | Stage 2 — if empty the stage is skipped with a warning |
| `SONAR_TOKEN` | `sqa_xxxx…` | Optional | Stage 2 — if empty the stage is skipped with a warning |

Two more values are **not secrets** — they are `env:` at the top of
`deploy.yml`, change them there if your Nexus differs:

```yaml
NEXUS_DOCKER_REGISTRY: localhost:8082   # <host>:<docker connector port>
NEXUS_DOCKER_REPO: docker_hosted     # the Repository ID in Nexus
```

The full image reference becomes
`localhost:8082/docker_hosted/spring-petclinic:<git-sha>`.

> The old `DOCKER_USERNAME` / `DOCKER_PASSWORD` secrets are no longer used.
> Delete `.github/workflows/ci-cd.yml` so the previous Docker-Hub pipeline does
> not run in parallel with this one.

---

## 3. Self-hosted GitHub Actions runner

Prerequisites on the runner machine (already true on this host):

* Docker installed, runner user in the `docker` group (`groups` → includes `docker`)
* `jq` and `curl` installed (used by the monitoring + smoke-test stages)
* Java is *not* required globally — `actions/setup-java` installs JDK 17 per job

### 3.1 Register the runner

Repo → **Settings → Actions → Runners → New self-hosted runner → Linux x64**,
then copy the commands it gives you:

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -L -O https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
tar xzf actions-runner-linux-x64-2.337.0.tar.gz
./config.sh --url https://github.com/neiorz/spring-petclinic-dockerized --token <TOKEN_FROM_GITHUB>
```

> On this machine the runner is **already registered** at `~/actions-runner`
> for this exact repository (`.runner` → `gitHubUrl` = your repo). It only
> needs to be *started*.

### 3.2 Start it

```bash
cd ~/actions-runner
./run.sh            # foreground — keep the terminal open
```

Or install it as a system service (survives reboots):

```bash
cd ~/actions-runner
sudo ./svc.sh install nourz
sudo ./svc.sh start
sudo ./svc.sh status
```

Labels are the defaults `self-hosted, Linux, X64`, which matches
`runs-on: self-hosted` in the workflow. When the runner is offline the jobs
simply queue until it comes back.

---

## 4. Nexus — Docker Hosted repository

### 4.1 Start Nexus

```bash
cd <repo-root>
docker compose up -d nexus
```

`docker-compose.yml` publishes **8081** (UI/REST) and **8082** (Docker
connector). If an older Nexus container without 8082 is running, compose will
recreate it — data lives in the `nexus-data` volume and survives.

First-time admin password:

```bash
# works whatever the container is called (nexus / petclinic-nexus / <project>-nexus-1)
docker exec $(docker ps -qf name=nexus) cat /nexus-data/admin.password
```

UI: <http://localhost:8081> → `admin` / that password → choose a new one.

### 4.2 Give the Docker repository an HTTP connector port

Your repository **`docker_hosted`** (type `hosted`, format `docker`) already exists,
but it has **no dedicated connector port**. Only `8081` is bound inside the container
and Nexus shows its URL as `http://localhost:8081/repository/docker_hosted/` — a
*sub-path* URL, which the Docker CLI cannot talk to.

1. Gear icon (**Administration**) → **Repository → Repositories** → click **`docker_hosted`** → edit (pencil icon)
2. Find the field **`HTTP connector port`**
   (older versions label it *"Create an HTTP connector at specified port"*)
3. Set it to **`8082`** → **Save**. No Nexus restart required.

If that field is not editable on an existing repository, delete `docker_hosted` and
recreate it:

1. **Repository → Repositories → Create repository**
2. Type: **`docker (hosted)`**
3. Name: **`docker_hosted`**  ← must equal `NEXUS_DOCKER_REPO`
4. **HTTP connector port: `8082`** ← must equal the port in `NEXUS_DOCKER_REGISTRY`
5. Strict content type validation: off (optional) → **Create repository**

> Port `8082` is already published from the Nexus container to the host
> (`docker port nexus` shows `8082/tcp -> 0.0.0.0:8082`) and `localhost:8082` is
> already listed in `/etc/docker/daemon.json` → `insecure-registries`. Once Nexus
> binds the connector, nothing else has to change.
>
> Without the connector nothing listens on 8082 inside the container and
> `docker login localhost:8082` fails with `read: connection reset by peer`.

### 4.3 Enable the Docker Bearer Token Realm

**Security → Realms** → in *Available realms* select **Docker Bearer Token
Realm** → move it to *Active realms* → **Save**.

Without this, `docker login localhost:8082` returns `401 Unauthorized`.

### 4.4 Credentials

Either:

* **A (simplest, local lab):** **Security → Anonymous Access → Allow anonymous access**, or
* **B (recommended):** **Security → Users → Add user** (e.g. `nexus-deployer`)
  with role `nx-admin`, or at minimum
  `nx-component-admin` + `nx-repository-view-docker-docker_hosted-*`.

Then put that user/password into the `NEXUS_USER` / `NEXUS_PASSWORD` secrets.

### 4.5 Teach the Docker daemon about HTTP (plain, non-TLS) registries

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "insecure-registries": ["localhost:8082"]
}
EOF
sudo systemctl restart docker
```

*(If `daemon.json` already exists, add the key instead of overwriting the file.)*

### 4.6 Verify

```bash
# expects: HTTP 401 + header "Docker-Distribution-Api-Version: registry/2.0"
curl -i http://localhost:8082/v2/

docker login localhost:8082 -u <user> -p <password>   # -> "Login Succeeded"
```

If `/v2/` answers on **8081** instead of 8082 (connector configured on the
main port), just set `NEXUS_DOCKER_REGISTRY: localhost:8081` at the top of
`deploy.yml` — nothing else changes.

---

## 5. SonarQube

### 5.1 Run it

> There is already a `sonarqube` container on this machine (it was working and
> stopped 3 days ago). Just bring it back instead of creating a new one:
>
> ```bash
> docker start sonarqube && sleep 60 && curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9000/
> ```
>
> To start from scratch instead, use the commands below.

```bash
# required for Elasticsearch (already set on this host: vm.max_map_count = 1048576)
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -w fs.file-max=65536

docker run -d --name sonarqube -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  sonarqube:community
```

Wait ~2–3 minutes, then open <http://localhost:9000> → `admin` / `admin` → change password.

### 5.2 Create the project

**Projects → Create new project** → key **`spring-petclinic`**, name
`Spring PetClinic`.

The key must match `-Dsonar.projectKey=spring-petclinic` in `deploy.yml`
(step *Run SonarQube scan*). If you choose a different key, edit that line.

### 5.3 Create the token

**My Account (top-right) → Security → Generate Tokens** → name it `ci-cd`,
type *User Token* → **Generate** → copy the `sqa_…` value.

Add the secrets:

```
SONAR_HOST_URL = http://localhost:9000
SONAR_TOKEN    = sqa_xxxxxxxxxxxxxxxx
```

> If either secret is missing the Sonar stage prints a warning and is skipped —
> the rest of the pipeline still runs. If the scan itself fails (bad token,
> unreachable host, quality-gate issues) the step outcome is `failure` but
> `continue-on-error: true` keeps the job green and the pipeline moving.

---

## 6. How the pieces work together

1. **Trigger** — a push to `main`/`master` (or *Run workflow*) creates a run.
   GitHub sees `runs-on: self-hosted` and hands the job to your runner.
2. **Stage 1** — checkout into `~/actions-runner/_work/...`, `setup-java` (JDK 17
   + Maven cache in `~/.m2`, which persists on the machine and makes later runs
   fast), then `./mvnw clean verify` compiles the app and runs the tests
   (Testcontainers talks to the same local Docker daemon). The fat JAR and the
   test/coverage reports are uploaded as artifacts for later jobs.
3. **Stage 2** — full-history checkout, `mvn -DskipTests compile` so the scanner
   has `target/classes`, then `SonarSource/sonarqube-scan-action` uploads the
   analysis. `continue-on-error: true` means a failing quality gate or a broken
   token becomes an annotation **warning**; the job still succeeds, so `needs:`
   lets Stage 3 start.
4. **Stage 3** — the image is built once (`docker build`, guarded by
   `docker image inspect` so later jobs reuse it from the shared daemon), then
   Trivy scans the filesystem/dependencies *and* the image. `exit-code: 0` plus
   `continue-on-error: true` guarantee that even 100 CRITICAL findings only
   produce warnings + a job-summary table + uploaded reports.
5. **Stage 4** — fail-fast reachability check on `http://<registry>/v2/`, then
   `docker/login-action` and two `docker push`es:
   `…/spring-petclinic:<sha>` (immutable, ties the deployment to the commit) and
   `…:latest`.
6. **Stage 5** — `APP_IMAGE` is set to the *exact* reference pushed in Stage 4,
   so what gets deployed is what was scanned and published. `docker compose
   pull app` fetches it from Nexus (falling back to the local tag if Nexus is
   down), then `docker compose up -d --no-build app mysql` starts MySQL (health
   gate) and the app, and the step polls `/actuator/health` for up to 120 s.
7. **Stage 6** — `docker compose up -d prometheus grafana`. Prometheus reads
   `prometheus.yml`, scrapes `app:8080/actuator/prometheus` every 10 s; Grafana
   boots with the Prometheus datasource already provisioned. The step waits for
   `/-/ready` and polls `/api/v1/targets` until the `spring-petclinic` job is
   `up` (a target that never comes up is a warning, not a hard failure).
8. **Stage 7** — `scripts/smoke-test.sh` performs 14 checks: the main pages,
   actuator health, the Prometheus metrics endpoint, a **real DB round-trip**
   (create owner → find owner), Prometheus target health, Grafana health and the
   provisioned datasource. Non-zero exit fails the run and dumps the compose
   logs.

**Data flow between jobs:** the JAR/reports travel as GitHub artifacts; the
container image travels through the shared local Docker daemon (that is the main
reason the runner must be on the same machine as the deployment target).
Secrets are only exposed as step-level environment variables and are masked in
the logs.

---

## 7. Running it / troubleshooting

```bash
# apply everything locally first (from the repository root!)
docker compose up -d --build
./scripts/smoke-test.sh
```

| Symptom | Fix |
|---------|-----|
| Two workflows run on every push, one is red | Delete `.github/workflows/ci-cd.yml` (the old Docker-Hub pipeline) |
| Jobs sit *queued* forever | Start the runner: `cd ~/actions-runner && ./run.sh` |
| `port is already allocated` (8080/3000/9090/5432) | A locally-started stack is using the same ports. The runner deploys from `~/actions-runner/_work/spring-petclinic-dockerized/...` → compose project `spring-petclinic-dockerized`, while running compose by hand from the repo root → project `spring-petclinic`. They cannot run at the same time: `docker compose down` one of them first. |
| `HTTP response to HTTPS client` on push | `insecure-registries: ["localhost:8082"]` in `/etc/docker/daemon.json`, restart Docker |
| `connection refused` on 8082 | The Docker repo has no HTTP connector port, or 8082 is not published in `docker-compose.yml` |
| `401 Unauthorized` on `docker login` | Enable the **Docker Bearer Token Realm** (Security → Realms) |
| `Container name … already in use` | Run compose from the repository root (project name = folder name) or `docker compose down --remove-orphans` |
| `PostgresIntegrationTests` → *Connection to localhost:5432 refused* | The `postgres` service must publish `5432:5432` (already in this compose file) |
| Sonar/Trivy steps show a yellow warning but the run is green | Working as designed — those stages are non-blocking |
| `/actuator/prometheus` → 404 | The `micrometer-registry-prometheus` dependency is missing from `pom.xml` |
