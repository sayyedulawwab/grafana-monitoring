# Grafana Observability Stack

OpenTelemetry Collector + Loki + Prometheus + Tempo + Grafana, deployed to an
Ubuntu VM by Azure DevOps using a self-hosted agent that already runs on that VM.

Placeholders used below: `<monitoring-vm>` is the Ubuntu VM, `<app-server>` is the
Windows Server running the .NET API, `<agent-user>` is the Azure DevOps agent's
Linux user, and `MyApp.WebApi` is the instrumented service.

```
Windows Server <app-server>         Desktop (LAN)
  MyApp.WebApi ──OTLP/HTTP──┐            │
                            ▼            ▼
            <monitoring-vm>:14318   <monitoring-vm>:3000
                            │            │
   ┌────────────────────────┼────────────┼──────────────┐
   │ docker network: monitoring_grafana-monitoring      │
   │   otel-collector:4318 ──┬── loki:3100       (logs) │
   │                         ├── prometheus:9090 (metrics, scrapes :9464)
   │                         └── tempo:4318      (traces)
   │                              ▲                     │
   │                        grafana:3000 ───────────────┘
   └────────────────────────────────────────────────────┘
```

## Repo layout

```
.gitignore
.env.example            # variable shape; the real .env is never committed
azure-pipelines.yml     # point the ADO pipeline at this
bootstrap-host.sh       # run once, manually, as root on the Ubuntu VM
docker-compose.yml
Readme.md
grafana/provisioning/datasources/datasource.yaml
loki/loki-config.yml
otel/otel-collector.yml
prometheus/prometheus.yml
tempo/tempo.yml
```

The repo root maps 1:1 onto `/opt/monitoring` on the VM. At runtime four extra
directories appear there — `loki/data`, `prometheus/data`, `tempo/data`,
`grafana/data`. They are gitignored, created by `bootstrap-host.sh`, and
excluded from every rsync, so no deploy can wipe your telemetry history.

---

## 1. One-time host preparation

```bash
scp bootstrap-host.sh <agent-user>@<monitoring-vm>:~
ssh <agent-user>@<monitoring-vm>
sudo AGENT_USER=<agent-user> WIN_SERVER=<app-server> DESKTOP_CIDR=<lan-cidr> bash bootstrap-host.sh
sudo systemctl restart 'vsts.agent.*'
sudo -u <agent-user> docker ps      # must succeed without sudo
```

Creates `/opt/monitoring`, chowns the data directories to the UIDs the container
processes actually run as, adds `<agent-user>` to the `docker` group, and opens UFW for
`14318` (Windows Server only) and `3000` (LAN).

## 2. One-time Azure DevOps setup

**Variable group** — Pipelines → Library → `monitoring-prod`:

| Variable | Example | Notes |
|---|---|---|
| `OTEL_VERSION` | `0.128.0` | pin; don't use `latest` |
| `LOKI_VERSION` | `3.5.0` | |
| `PROMETHEUS_VERSION` | `v3.4.1` | note the leading `v` |
| `TEMPO_VERSION` | `2.8.0` | |
| `GRAFANA_VERSION` | `12.0.2` | |
| `GF_ADMIN_USER` | `admin` | |
| `GF_ADMIN_PASSWORD` | — | **mark as secret**, or link from Key Vault |
| `GF_ROOT_URL` | `http://<monitoring-vm>:3000` | Grafana's public URL; defaults to `http://localhost:3000` |

Confirm the tags exist before the first run (`docker pull grafana/loki:3.5.0`).
Version bumps are now a variable-group edit plus a re-run — no code change.

**Environment** — Pipelines → Environments → new environment `monitoring-prod`
(kind: None), with an *Approvals* check so production deploys are gated.

**Pipeline** — New pipeline → existing YAML → `/azure-pipelines.yml`. Grant it
access to the variable group and environment on the first run.

## 3. What the pipeline does

**Build** runs each component's own validator inside its own image:
`docker compose config`, `otelcol validate`, `promtool check config`,
`loki -verify-config`, `tempo -config.verify`. A typo fails here, not at 3am.
Publishes the repo (minus `data/` and `.git/`) as an artifact. PRs run this
stage only.

**Deploy**, gated by the environment approval:

1. Precondition check — `/opt/monitoring` exists, agent can reach Docker
2. Back up the current config to `/opt/monitoring-backup-<stamp>` (keeps 5)
3. Write `.env` from the variable group, mode 600
4. `rsync --delete` the artifact over `/opt/monitoring`, excluding `data/` and `.env`
5. `docker compose pull && docker compose up -d --remove-orphans`
6. Poll every readiness endpoint from a throwaway `curl` container on the Docker network (up to 150s), dumping container logs on timeout
7. Smoke test the two published ports — `POST /v1/traces` on `14318` must return 200, `GET /api/health` on `3000` must succeed, Prometheus must have a live target
8. On any failure, restore the backup and `up -d` again

## 4. Application-side change (Windows Server)

`appsettings.Production.json` points at `localhost:14318`, which from the Windows
box is the Windows box. It must be:

```json
"Otlp": {
  "LogsEndpoint":    "http://<monitoring-vm>:14318/v1/logs",
  "TracesEndpoint":  "http://<monitoring-vm>:14318/v1/traces",
  "MetricsEndpoint": "http://<monitoring-vm>:14318/v1/metrics"
}
```

Guard the lookups in `Program.cs` — `new Uri(null)` throws at startup:

```csharp
var otlpLogsEndpoint = builder.Configuration["Otlp:LogsEndpoint"]
    ?? throw new InvalidOperationException("Otlp:LogsEndpoint is not configured");
```

Verify from the Windows Server:

```powershell
Test-NetConnection <monitoring-vm> -Port 14318      # TcpTestSucceeded : True
Invoke-WebRequest -Uri http://<monitoring-vm>:14318/v1/traces -Method POST `
  -ContentType 'application/json' -Body '{"resourceSpans":[]}'   # 200
```

Consider dropping the metrics export interval from 60s to 15–30s to line up with
Prometheus's 15s scrape.

## 5. Verifying in Grafana

`http://<monitoring-vm>:3000`

**Logs** — Explore → Loki:
```logql
{service_name="MyApp.WebApi"} | json
{service_name="MyApp.WebApi"} |= "Error"
```
Expand a line: `trace_id` appears as structured metadata with a **View trace**
link straight into Tempo.

**Traces** — Explore → Tempo → Search, service `MyApp.WebApi`. ASP.NET Core spans
with nested `SqlClient` children; since you set `RecordException`, failed queries
carry the exception. "Logs for this span" pivots back to Loki.

**Metrics** — Explore → Prometheus:
```promql
rate(http_server_request_duration_seconds_count{service_name="MyApp.WebApi"}[5m])
histogram_quantile(0.95, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket[5m])))
process_runtime_dotnet_gc_collections_count
```
Missing `service_name` label means `resource_to_telemetry_conversion` isn't
taking effect — check the collector logs.

**Dashboards** — import by ID (Dashboards → New → Import): ASP.NET Core OTel
`19924`, .NET runtime `19925`, OTel Collector `15983`.

## 6. Changes made to the original configs

| # | Issue | Fix |
|---|---|---|
| 1 | `appsettings.json` OTLP endpoints use `localhost:14318` | point at `<monitoring-vm>` |
| 2 | Compose published `3100`, `9090`, `3200`, `9464`, `13133` to the host | removed; only `14318` and `3000`, matching the intended design |
| 3 | Grafana volume mounted at `/var/lib/grafana/data` | corrected to `/var/lib/grafana`. As written, `grafana.db` was **not** persisted — every restart lost users and dashboards |
| 4 | Healthchecks call `wget` | removed. The collector and Tempo images are distroless — no shell, no wget — so those healthchecks fail permanently and the container reports unhealthy forever. Readiness is checked from the pipeline instead |
| 5 | Images unpinned (`grafana/loki`, `prom/prometheus`, …) | pinned via `.env` so a redeploy can't silently pull a breaking major version |
| 6 | Grafana admin password hard-coded in the compose file | moved to a secret variable, injected via `.env` at deploy time |
| 7 | No `resource_to_telemetry_conversion` on the Prometheus exporter | added — without it `service.name` never becomes a metric label |
| 8 | `user: "0:0"` on Loki, root-owned data dirs | data dirs chowned to real container UIDs; all containers run non-root |
| 9 | Datasources had no correlation config | added Loki→Tempo derived field, Tempo→Loki `tracesToLogsV2`, Prometheus exemplars→Tempo |
| 10 | Prometheus retention 7d vs Loki 30d | Prometheus raised to 30d |
| 11 | Collector's own internal metrics not scraped | added `otel-collector:8888` so dropped spans and queue saturation are visible |

## 7. Operations

```bash
cd /opt/monitoring
docker compose ps
docker compose logs -f otel-collector
docker compose restart grafana
docker compose down && docker compose up -d     # data survives
```

Redeploy = re-run the pipeline. Rollback = re-run the last good run, or on the
host: `rsync -a --delete --exclude='.env' --exclude='*/data/' /opt/monitoring-backup-<stamp>/ /opt/monitoring/ && docker compose up -d`.

Before treating this as fully production-grade: TLS on the OTLP endpoint if
telemetry ever crosses an untrusted segment, Grafana behind a reverse proxy with
real auth, and disk alerts on `/opt/monitoring` — Loki at 30d retention is the
one that will grow.