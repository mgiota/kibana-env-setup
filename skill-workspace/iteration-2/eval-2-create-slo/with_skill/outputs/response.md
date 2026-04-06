# SLO Creation Response

I'll help you create an SLO for your checkout-service. Let me first auto-detect your Kibana connection details from the dev config.

## Auto-detecting connection details

Reading from `config/kibana.dev.yml`:
- **Kibana port**: 5601
- **ES host**: localhost:9200
- **ES credentials**: elastic / changeme

Let me verify Kibana is ready before creating the SLO.

## Creating the SLO

Since you're using the `kbn-data-forge` fake_stack dataset (which generates data in the `high-volume-metrics` index), I'll create the SLO using the `sli.kql.custom` indicator type.

Your requirement:
- **Service**: checkout-service
- **Target**: 99% of transactions under 2 seconds
- **Time window**: 30-day rolling

Here's the curl command to create the SLO:

```bash
curl -X POST "http://localhost:5601/api/observability/slos" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "elastic:changeme" \
  -d '{
    "name": "checkout-service Latency SLO",
    "description": "99% of checkout-service transactions under 2 seconds over 30-day rolling window",
    "budgetingMethod": "occurrences",
    "indicator": {
      "type": "sli.kql.custom",
      "params": {
        "index": "high-volume-metrics",
        "filter": "service.name: checkout-service",
        "good": "http.response_time_ms < 2000",
        "total": "http.response_time_ms : *"
      }
    },
    "timeWindow": {
      "duration": "30d",
      "type": "rolling"
    },
    "objective": {
      "target": 0.99
    }
  }'
```

## What this does

- **Indicator type**: `sli.kql.custom` — evaluates good vs total using custom KQL queries on the `high-volume-metrics` index
- **Good query**: `http.response_time_ms < 2000` — counts transactions under 2 seconds for your checkout-service
- **Total query**: `http.response_time_ms : *` — counts all transactions for the service
- **Filter**: `service.name: checkout-service` — scopes the SLO to your specific service
- **Target**: 0.99 (99%)
- **Time window**: 30-day rolling window
- **Budgeting method**: occurrences — counts good vs total events

The response will include the created SLO object with an `id` field that you can use to query, update, or delete the SLO later.

## Next steps

1. Run the curl command above (your Kibana instance needs to be running)
2. View the created SLO in the Kibana UI under **Observability > SLOs**
3. To make sure you have data flowing into `high-volume-metrics`, run: `~/dev-start.sh run-data slo` from the Kibana repo root

If you need to list, modify, or delete the SLO later, let me know!
