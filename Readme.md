# Grafana Monitoring Stack with OpenTelemetry, Loki, Prometheus, Tempo, and Grafana

This project provides a **full observability stack** for local development and testing. It includes:

* **OpenTelemetry Collector** – Receives logs, metrics, and traces from applications.
* **Loki** – Centralized log storage and querying.
* **Prometheus** – Metrics collection and monitoring.
* **Tempo** – Distributed tracing backend.
* **Grafana** – Unified dashboard for logs, metrics, and traces.

The stack is orchestrated using **Docker Compose**.

---

## Table of Contents

* [Prerequisites](#prerequisites)
* [Setup and Run](#setup-and-run)
* [Service Overview](#service-overview)
* [Integrate with Your API Project](#integrate-with-your-api-project)
* [Persistence and Data Retention](#persistence-and-data-retention)
* [Troubleshooting](#troubleshooting)

---

## Prerequisites

* Docker ≥ 20.x
* Docker Compose ≥ 2.x
* A Unix-like terminal (Linux, macOS, WSL on Windows)

> **Note:** All services run in Docker containers and communicate over the `grafana-monitoring` network.

---

## Setup and Run

1. **Clone the repository:**

```bash
git clone <repo-url>
cd <repo-directory>
```

2. **Start the stack:**

```bash
docker compose up -d
```

3. **Check service health:**

```bash
docker compose ps
```

All services should be in `Up` state.

4. **Access services:**

| Service              | URL                                              | Default Credentials |
| -------------------- | ------------------------------------------------ | ------------------- |
| Grafana              | [http://localhost:3000](http://localhost:3000)   | admin / admin       |
| Loki (logs)          | [http://localhost:3100](http://localhost:3100)   | n/a                 |
| Prometheus (metrics) | [http://localhost:9090](http://localhost:9090)   | n/a                 |
| Tempo (traces)       | [http://localhost:3200](http://localhost:3200)   | n/a                 |
| OTEL Collector       | [http://localhost:13133](http://localhost:13133) | n/a (healthcheck)   |

5. **Stop the stack:**

```bash
docker compose down
```

> **Tip:** Data will persist because the services use **host-mounted volumes**.

---

## Service Overview

### OpenTelemetry Collector

* Receives OTLP logs, metrics, and traces from APIs or apps.
* Exports:

  * Logs → Loki
  * Metrics → Prometheus
  * Traces → Tempo

### Loki

* Stores logs on host volumes (`./loki/data`)
* Uses a TSDB schema for high performance and retention configuration (`30d`).

### Prometheus

* Scrapes metrics from OTEL Collector every `15s`.
* Stores metrics in `./prometheus/data` with `7-day` retention.

### Tempo

* Receives distributed traces via OTLP.
* Stores trace blocks in `./tempo/data` with `7-day` retention.

### Grafana

* Dashboards for logs, metrics, and traces.
* Datasources configured via provisioning:

  * Loki (default)
  * Prometheus
  * Tempo

---

## Integrate with Your API Project

1. **Add OpenTelemetry SDK** to your project (C#, Node.js, Java, etc.)
2. **Configure OTLP exporter** to point to the collector:

```text
http://localhost:14318
```

3. **Send telemetry data:**

   * Logs → collector → Loki
   * Metrics → collector → Prometheus
   * Traces → collector → Tempo

4. **View data in Grafana** at `http://localhost:3000`.

---

## Persistence and Data Retention

* **Logs, metrics, and traces** are persisted in **host-mounted volumes**:

| Service    | Host Directory    | Container Directory |
| ---------- | ----------------- | ------------------- |
| Loki       | ./loki/data       | /loki/data          |
| Prometheus | ./prometheus/data | /prometheus/data    |
| Tempo      | ./tempo/data      | /var/tempo          |
| Grafana    | ./grafana/data    | /var/lib/grafana    |

* Retention periods:

  * Loki logs: 30 days
  * Prometheus metrics: 7 days
  * Tempo traces: 7 days

> **Important:** Changing container configs or running `docker compose down` will **not delete your host data**, so logs and metrics persist.

---

## Troubleshooting

* **Logs not visible in Grafana:**

  * Ensure `./loki/data` contains files and that `path_prefix` in Loki config matches the volume.
  * Check OTEL Collector logs for export errors.

* **Metrics missing in Prometheus:**

  * Verify OTEL Collector metrics endpoint (`http://localhost:9464`) is reachable.

* **Traces missing in Tempo:**

  * Ensure your API is sending traces to OTLP endpoint `http://localhost:14318`.

* **Service healthchecks failing:**

  * Run `docker logs <service-name>` to inspect startup errors.
