# Blockscout Monitoring

This directory contains a Grafana dashboard for metrics exposed by this Blockscout application.

## Prometheus scrape jobs

Blockscout exposes two Prometheus endpoints:

- `/metrics` contains app, indexer, JSON-RPC, Ecto, runtime, and queue metrics.
- `/public-metrics` contains public chain KPI gauges such as successful transactions, active addresses, new token transfers, and smart-contract counts.

When running through the Docker Compose nginx proxy, this fork exposes both paths on port `9090`.

```yaml
scrape_configs:
  - job_name: blockscout
    metrics_path: /metrics
    static_configs:
      - targets: ["<host>:9090"]

  - job_name: blockscout_public
    metrics_path: /public-metrics
    static_configs:
      - targets: ["<host>:9090"]
```

## Grafana dashboard

Import `grafana/blockscout-dashboard.json` into Grafana and select:

- `Datasource`: your Prometheus datasource.
- `Metrics job`: the Prometheus job scraping `/metrics`.
- `Public metrics job`: the Prometheus job scraping `/public-metrics`.

The dashboard focuses on metrics defined in this repo:

- scraper health via `up`
- indexer height and latest block/batch age
- node delay from `delay_from_last_node_block`
- JSON-RPC request and error rates
- block/indexer processing latency histograms
- import and JSON-RPC errors
- missing block, internal transaction, token balance, and multichain export backlogs
- fetcher memory and web event-handler queues
- public chain activity gauges from `/public-metrics`
