# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

There is no application code here: the repo is configuration for an OpenTelemetry Collector + Loki + Prometheus + Tempo + Grafana stack, run by [docker-compose.yml](docker-compose.yml) and deployed by [azure-pipelines.yml](azure-pipelines.yml). There are no tests; the Build stage's validators are the check. To run them locally, set the image tags (the pipeline reads them from the `monitoring-prod` variable group; the values below are the examples from [Readme.md](Readme.md)):

```bash
OTEL_VERSION=0.128.0 LOKI_VERSION=3.5.0 PROMETHEUS_VERSION=v3.4.1 TEMPO_VERSION=2.8.0   # Prometheus tags have a leading v

docker compose --env-file .env.example -f docker-compose.yml config -q
docker run --rm -v "$PWD/otel:/cfg:ro" otel/opentelemetry-collector-contrib:$OTEL_VERSION validate --config=/cfg/otel-collector.yml
docker run --rm -v "$PWD/prometheus:/cfg:ro" --entrypoint promtool prom/prometheus:$PROMETHEUS_VERSION check config /cfg/prometheus.yml
docker run --rm -v "$PWD/loki:/cfg:ro" grafana/loki:$LOKI_VERSION -config.file=/cfg/loki-config.yml -verify-config -target=all
docker run --rm -v "$PWD/tempo:/cfg:ro" grafana/tempo:$TEMPO_VERSION -config.file=/cfg/tempo.yml -config.verify
```

`.env.example` is currently empty, so the compose check only warns that the variables are unset and still passes. It checks the YAML structure, not the image tags. Grafana's provisioning file has no validator in the pipeline.

## Architecture

Compose project `monitoring`, one bridge network `grafana-monitoring` (so the Docker network is `monitoring_grafana-monitoring`, which the pipeline hard-codes). Each container is named after its service.

| Service | Listens on (in network) | Published on host |
|---|---|---|
| otel-collector | 4318 OTLP/HTTP, 9464 Prometheus exporter, 13133 health_check, 8888 internal metrics (scraped) | `14318 -> 4318` |
| loki | 3100 (OTLP ingest at `/otlp`) | none |
| prometheus | 9090 | none |
| tempo | 3200 HTTP, 4318 OTLP/HTTP | none |
| grafana | 3000 | `3000` |

Only 14318 and 3000 are published, on purpose. Don't publish the others. UFW on the VM limits 14318 to `WIN_SERVER` and 3000 to `DESKTOP_CIDR`.

Data flow ([otel/otel-collector.yml](otel/otel-collector.yml)): the instrumented app (`MyApp.WebApi` on `<app-server>`) sends OTLP/HTTP to `<monitoring-vm>:14318`. The collector's three pipelines share the `memory_limiter -> resource -> batch` processors (`resource` inserts `deployment.environment=production`):

- logs -> `otlphttp/loki` (`http://loki:3100/otlp`)
- traces -> `otlphttp/tempo` (`http://tempo:4318`)
- metrics -> `prometheus` exporter on `:9464`, which Prometheus **scrapes** (pull, not push). `resource_to_telemetry_conversion` is what turns `service.name` into a `service_name` label, and `enable_open_metrics` carries exemplars.

Only the OTLP HTTP protocol is enabled (no gRPC/4317). The receiver must bind `0.0.0.0`, not localhost.

Retention: Loki 30d (`compactor.retention_enabled`), Prometheus 30d (compose command flag), Tempo 7d (`block_retention: 168h`). Loki needs `allow_structured_metadata: true` because OTLP `trace_id`/`span_id` arrive as structured metadata.

### Correlation ([grafana/provisioning/datasources/datasource.yaml](grafana/provisioning/datasources/datasource.yaml))

Datasources use fixed uids `loki`, `prometheus`, `tempo`, and the cross-links refer to them by uid, so renaming a uid breaks the links. Loki is the default datasource.

- Loki -> Tempo: derived field `TraceID` matches the `trace_id` label/metadata ("View trace").
- Tempo -> Loki: `tracesToLogsV2` with `filterByTraceID`, maps tag `service.name` to `service_name`, and shifts the time window by ±5m.
- Tempo -> Prometheus: `tracesToMetrics` (no custom queries); node graph enabled.
- Prometheus -> Tempo: `exemplarTraceIdDestinations` on `trace_id`. This needs Prometheus's `--enable-feature=exemplar-storage` and the collector's `enable_open_metrics`.

## Deployment

The self-hosted Azure DevOps agent runs **on the monitoring VM itself** (pool `Ubuntu 24.04 LTS`), so there is no SSH hop: the pipeline writes straight into `/opt/monitoring`. The host must have been prepared once with [bootstrap-host.sh](bootstrap-host.sh) (run as root with `AGENT_USER`, `WIN_SERVER`, `DESKTOP_CIDR`). It creates the deploy root and data dirs, adds the agent user to the `docker` group, and adds the UFW rules.

- Triggers on `main` and on PRs to `main`. PRs run **Build only**.
- **Build**: the five validators above, then `CopyFiles@2` stages `docker-compose.yml`, `bootstrap-host.sh`, `.env.example` and the five component dirs, minus `**/data/**` and `.git/**`. `Readme.md`, `.gitignore` and the pipeline file are not deployed.
- **Deploy** (deployment job on environment `monitoring-prod`, gated by its approval check):
  1. Check that `/opt/monitoring` exists and that the agent can reach Docker.
  2. Back up the current config to `/opt/monitoring-backup-<stamp>` and keep the newest 5.
  3. Write `.env` (mode 600) from the variable group.
  4. `rsync -a --delete` the artifact into `/opt/monitoring`, excluding `.env`, `loki/data/`, `prometheus/data/`, `tempo/data/` and `grafana/data/`.
  5. Run `docker compose pull && up -d --remove-orphans`.
  6. Poll readiness through a throwaway `curlimages/curl` container on the Docker network, for up to 150s per service. The endpoints are collector `:13133`, Loki `/ready`, Prometheus `/-/healthy`, Tempo `/ready` and Grafana `/api/health`.
  7. Smoke-test from the host: `POST /v1/traces` on 14318 must return 200, Grafana `/api/health` on 3000 must succeed, and Prometheus must have at least one target `up`.
  8. On failure, rsync the backup back and run `up -d`.
- Values: every image tag (`OTEL_VERSION`, `LOKI_VERSION`, `PROMETHEUS_VERSION`, `TEMPO_VERSION`, `GRAFANA_VERSION`), `GF_ADMIN_USER`, `GF_ADMIN_PASSWORD` (secret) and the optional `GF_ROOT_URL` come from variable group `monitoring-prod`, through the generated `.env`. A secret variable is not auto-mapped into the shell, so it is passed through the step's `env:`. If you add a variable, add it to the group, to the "Write .env" step, and to `docker-compose.yml`.

## Quirks

- **Data dirs and UIDs**: `loki/data`, `prometheus/data`, `tempo/data` and `grafana/data` are bind mounts. They are gitignored, created by the bootstrap script, and never touched by rsync. Containers run non-root with fixed UIDs (Loki and Tempo `10001`, Prometheus `65534`, Grafana `472`), and the dirs must be chowned to match or the containers crash-loop with permission denied. If you change a `user:` in compose, change the `chown` in `bootstrap-host.sh` too. Don't reintroduce `user: "0:0"`.
- **Container mount paths must match the configs**: Loki `/loki/data` (`path_prefix`), Tempo `/var/tempo` (wal and blocks), Prometheus `/prometheus/data` (`--storage.tsdb.path`), and Grafana `/var/lib/grafana`, **not** `/var/lib/grafana/data`. One level too deep and `grafana.db`, with its users and dashboards, is lost on restart.
- **No compose healthchecks**: the collector and Tempo images are distroless (no shell, no `wget`), so a `wget`/`curl` healthcheck would fail forever. `depends_on` only orders startup, and readiness is checked by the pipeline from a separate curl container. Don't add `docker exec ... sh` debugging steps for those images.
- Image tags are always variables. Don't hard-code tags or use `latest` in compose (the pipeline's own `curlimages/curl:latest` is the one exception).
- Renaming the compose `name:` or the network changes `monitoring_grafana-monitoring` and breaks the readiness and smoke-test steps.
- Running the stack locally needs a real `.env` with the variables above. On Linux it also needs the data dirs created with the UIDs above.
