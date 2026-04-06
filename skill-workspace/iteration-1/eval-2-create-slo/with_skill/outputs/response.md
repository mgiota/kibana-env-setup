# Creating SLO for checkout-service

I'll help you create an SLO for your checkout-service targeting 99% of transactions under 2 seconds over a 30-day rolling window.

First, let me confirm your Kibana connection details are set. You'll need to read the Kibana port and ES credentials from your active development environment:

```bash
# Read Kibana port from kibana.dev.yml
kibana_port=$(grep -E "^ *port:" config/kibana.dev.yml | head -1 | awk '{print $2}')
kibana_url="http://localhost:${kibana_port}"

# Read ES credentials
es_user=$(grep -E "^ *username:" config/kibana.dev.yml | head -1 | awk '{print $2}' | tr -d '"')
es_pass=$(grep -E "^ *password:" config/kibana.dev.yml | head -1 | awk '{print $2}' | tr -d '"')

echo "Kibana URL: $kibana_url"
echo "ES User: $es_user"
```

Once you have the connection details, verify Kibana is ready:

```bash
until curl -s "http://localhost:${kibana_port}/api/status" | grep -q '"overall":{"level":"available"'; do
  sleep 5
done
echo "Kibana is ready!"
```

Now, create the SLO using the APM Latency indicator (since you're targeting transaction latency):

```bash
curl -X POST "http://localhost:${kibana_port}/api/observability/slos" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "${es_user}:${es_pass}" \
  -d '{
    "name": "Checkout Service Latency SLO",
    "description": "99% of checkout-service transactions under 2 seconds over 30-day rolling window",
    "budgetingMethod": "occurrences",
    "indicator": {
      "type": "sli.apm.transactionDuration",
      "params": {
        "service": "checkout-service",
        "environment": "production",
        "transactionType": "request",
        "threshold": 2000,
        "index": "metrics-apm*"
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

**Key details:**

- **Endpoint:** `POST /api/observability/slos`
- **Headers:** `kbn-xsrf: true` (required for CSRF protection) and `Content-Type: application/json`
- **Indicator type:** `sli.apm.transactionDuration` — measures transaction duration from APM data
- **Service name:** `checkout-service` — targets your specific service
- **Threshold:** `2000` milliseconds (2 seconds)
- **Target:** `0.99` (99%)
- **Time window:** `30d` with type `rolling` for a 30-day rolling window
- **Budgeting method:** `occurrences` — tracks the ratio of transactions meeting the threshold

The response will include the created SLO's ID and status. You can verify it was created by listing your SLOs:

```bash
curl -s "http://localhost:${kibana_port}/api/observability/slos" \
  -H "kbn-xsrf: true" \
  -u "${es_user}:${es_pass}" | jq '.results[] | {id, name, status}'
```

If you need to modify the SLO later (e.g., adjust the threshold, target, or environment), just let me know!
