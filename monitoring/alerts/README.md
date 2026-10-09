# SPIRE Prometheus Alerting Rules

This directory contains production-ready Prometheus alerting rules for monitoring SPIRE Server and Agent deployments.

## Overview

The alerting rules are organized by component and category:

- **certificate-alerts.yaml** - Certificate expiration and SVID signing alerts
- **federation-alerts.yaml** - Federation bundle health and connectivity alerts 
- **agent-alerts.yaml** - Agent attestation, workload API, and sync alerts
- **server-alerts.yaml** - Server availability, datastore, and operational alerts

## Alert Severity Levels

| Severity | Description | Response Time |
|----------|-------------|---------------|
| `critical` | Service-impacting issue requiring immediate attention | < 15 minutes |
| `warning` | Degraded performance or potential future issue | < 1 hour |
| `info` | Informational notification, no action required | N/A |

## Prerequisites

1. **Prometheus Server** with alerting enabled
2. **AlertManager** configured for routing notifications
3. **SPIRE Server and Agent** with telemetry enabled (Prometheus format)

## Installation

### Option 1: Standalone Prometheus

Add these rules to your `prometheus.yml`:

```yaml
rule_files:
 - "/etc/prometheus/rules/spire/*.yaml"
```

Then copy the alert files:

```bash
cp monitoring/alerts/*.yaml /etc/prometheus/rules/spire/
```

### Option 2: Prometheus Operator (Kubernetes)

Create a `PrometheusRule` resource:

```bash
kubectl apply -f monitoring/kubernetes/prometheus-rules.yaml
```

### Option 3: OpenShift Monitoring

For OpenShift environments, deploy as a `PrometheusRule` in the monitoring namespace:

```bash
oc apply -f monitoring/openshift/spire-prometheus-rules.yaml
```

## Configuration

### Enabling SPIRE Telemetry

#### SPIRE Server Configuration

```hcl
server {
 # ... other config ...

 telemetry {
 Prometheus {
 port = 9988
 }
 }
}
```

#### SPIRE Agent Configuration

```hcl
agent {
 # ... other config ...

 telemetry {
 Prometheus {
 port = 9989
 }
 }
}
```

### Prometheus Scrape Configuration

Add SPIRE endpoints to your Prometheus scrape config:

```yaml
scrape_configs:
 - job_name: 'spire-server'
 static_configs:
 - targets: ['spire-server:9988']
 labels:
 component: 'spire-server'

 - job_name: 'spire-agent'
 static_configs:
 - targets: ['spire-agent:9989']
 labels:
 component: 'spire-agent'
```

For Kubernetes/OpenShift, use ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
 name: spire-server
spec:
 selector:
 matchLabels:
 app: spire-server
 endpoints:
 - port: prometheus
 interval: 30s
```

## Alert Categories

### Certificate Alerts

Monitor X.509 CA and SVID certificate lifecycle:

- **Critical**: CA expiring < 24 hours
- **Warning**: CA expiring < 7 days 
- **Info**: CA expiring < 30 days
- SVID signing failures
- Agent SVID rotation issues

**Key Metrics:**
- `spire_server_manager_x509_ca_rotate_expiration`
- `spire_server_server_ca_sign_x509_svid`
- `spire_agent_agent_svid_rotate`

### Federation Alerts

Monitor cross-cluster/cross-domain trust:

- Federation bundle fetch failures
- Stale bundles (not updated recently)
- Bundle fetch latency issues

**Key Metrics:**
- `spire_server_bundle_manager_fetch_federated_bundle`
- `spire_server_bundle_manager_update_federated_bundle`

### Agent Alerts

Monitor agent health and workload API:

- Agent attestation failures
- No active agents in trust domain
- Workload API connectivity issues
- High number of tainted SVIDs
- Agent sync failures

**Key Metrics:**
- `spire_server_rpc_agent_v1_agent_attest_agent`
- `spire_agent_workload_api_connections`
- `spire_agent_cache_manager_tainted_x509_svids_workload`

### Server Alerts

Monitor server availability and datastore:

- Server down or restarted
- Datastore connection failures
- Entry cache reload issues
- Registration entry/node creation failures

**Key Metrics:**
- `up{job=~".*spire-server.*"}`
- `spire_server_uptime_in_ms`
- `spire_server_datastore_*`

## Alert Routing Examples

### AlertManager Configuration

```yaml
route:
 group_by: ['alertname', 'trust_domain_id']
 group_wait: 10s
 group_interval: 10s
 repeat_interval: 12h
 receiver: 'spire-team'
 routes:
 - match:
 severity: critical
 receiver: 'pagerduty'
 continue: true
 - match:
 severity: warning
 receiver: 'slack'

receivers:
 - name: 'spire-team'
 email_configs:
 - to: 'spire-ops@example.com'

 - name: 'pagerduty'
 pagerduty_configs:
 - service_key: '<pagerduty-key>'

 - name: 'slack'
 slack_configs:
 - api_url: '<slack-webhook-url>'
 channel: '#spire-alerts'
```

## Testing Alerts

### Manual Testing

Use `promtool` to validate alert syntax:

```bash
promtool check rules monitoring/alerts/*.yaml
```

### Trigger Test Alerts

Use `amtool` to send test alerts to AlertManager:

```bash
amtool alert add \
 --annotation=summary="Test SPIRE alert" \
 --annotation=description="Testing alert routing" \
 SPIRETestAlert
```

## Runbooks

Each alert includes a `runbook` annotation linking to troubleshooting documentation:

- Certificate alerts → https://github.com/spiffe/spire/tree/main/doc
- Federation alerts → https://github.com/spiffe/spire/tree/main/doc
- Agent alerts → https://github.com/spiffe/spire/tree/main/doc
- Server alerts → https://github.com/spiffe/spire/tree/main/doc

### Common Resolution Steps

#### Certificate Expiry Alerts

1. Check current CA expiration:
 ```bash
 spire-server x509 show
 ```

2. Rotate CA if needed:
 ```bash
 spire-server x509 rotate
 ```

#### Federation Bundle Fetch Failures

1. Check federation endpoint connectivity:
 ```bash
 curl -k https://<federated-domain>/.well-known/spiffe/federation
 ```

2. Review server logs for federation errors:
 ```bash
 journalctl -u spire-server | grep federation
 ```

#### Agent Attestation Failures

1. Check agent logs for attestation errors:
 ```bash
 journalctl -u spire-agent | grep attest
 ```

2. Verify node attestor configuration matches server

3. Check join token validity (if using join token attestation)

#### Datastore Connection Failures

1. Verify database connectivity:
 ```bash
 psql -h <db-host> -U spire -d spire-db -c "SELECT 1"
 ```

2. Check connection pool exhaustion in server logs

3. Review database performance metrics

## Customization

### Adjusting Thresholds

Edit the alert expressions to match your environment:

```yaml
# Example: Change CA expiry warning from 7 days to 14 days
- alert: SPIREServerX509CAExpiryWarning
 expr: (spire_server_manager_x509_ca_rotate_expiration - time()) < 1209600 # 14 days
```

### Adding Labels

Add custom labels for routing or filtering:

```yaml
labels:
 severity: critical
 component: spire-server
 team: platform-security # Custom label
 environment: production # Custom label
```

## Monitoring Best Practices

1. **Deploy alerts in stages**: Start with `critical` alerts, then add `warning` and `info`
2. **Tune thresholds**: Adjust based on your SLOs and operational capacity
3. **Document runbooks**: Maintain up-to-date runbooks for each alert
4. **Test regularly**: Periodically trigger test alerts to validate routing
5. **Review alert fatigue**: If alerts are noisy, adjust thresholds or severity

## Integration with Grafana

These alerts complement the SPIRE Grafana dashboards in `doc/telemetry/`:

1. Import `doc/telemetry/spire_grafana_dashboard.json`
2. Add alert state annotations to dashboards
3. Create alert list panels showing active alerts

## Support

- SPIRE Documentation: https://spiffe.io/docs/
- GitHub Issues: https://github.com/spiffe/spire/issues
- Slack: https://slack.spiffe.io

## Contributing

When adding new alerts:

1. Use existing SPIRE metrics from `doc/telemetry/telemetry.md`
2. Follow the severity level guidelines
3. Include clear annotations (summary + description)
4. Add runbook links where applicable
5. Test alert expressions with real data
6. Update this README with the new alert category

## License

These alerting rules are provided under the same license as SPIRE (Apache 2.0).
