#!/usr/bin/env bash
# Validates all SPIRE monitoring alert rules, including Kubernetes/OpenShift CRDs.
# Usage: ./monitoring/validate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_RULES=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RULES"' EXIT

PASS=0
FAIL=0

run_step() {
    local desc="$1"; shift
    echo "=== $desc ==="
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

extract_rules() {
    python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
with open(sys.argv[2], 'w') as f:
    yaml.dump({'groups': doc['spec']['groups']}, f, default_flow_style=False)
" "$1" "$2"
}

run_step "Validating standalone alert rules" \
    promtool check rules "$SCRIPT_DIR"/alerts/*.yaml

extract_rules "$SCRIPT_DIR/kubernetes/prometheus-rules.yaml" "$TMPDIR_RULES/k8s-rules.yaml"
run_step "Validating Kubernetes PrometheusRule" \
    promtool check rules "$TMPDIR_RULES/k8s-rules.yaml"

extract_rules "$SCRIPT_DIR/openshift/spire-prometheus-rules.yaml" "$TMPDIR_RULES/ocp-rules.yaml"
run_step "Validating OpenShift PrometheusRule" \
    promtool check rules "$TMPDIR_RULES/ocp-rules.yaml"

run_step "Unit tests - standalone alerts" \
    promtool test rules "$SCRIPT_DIR/alerts_test.yaml"

# Kubernetes unit tests
cat > "$TMPDIR_RULES/k8s_test.yaml" <<'TESTEOF'
rule_files:
  - k8s-rules.yaml

evaluation_interval: 1m

tests:
  - name: "K8s SPIREServerDown fires after 5m"
    interval: 1m
    input_series:
      - series: 'up{job="spire-server-metrics", instance="server-1:9988"}'
        values: "0x20"
    alert_rule_test:
      - eval_time: 4m
        alertname: SPIREServerDown
        exp_alerts: []
      - eval_time: 6m
        alertname: SPIREServerDown
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: availability
              job: spire-server-metrics
              instance: "server-1:9988"
            exp_annotations:
              summary: "SPIRE Server is down"
              description: "SPIRE Server server-1:9988 has been down for 5+ minutes.\nAgents cannot attest, workloads cannot get new SVIDs. IMMEDIATE ACTION REQUIRED.\n"
              runbook: "https://github.com/spiffe/spire/tree/main/doc"

  - name: "K8s SPIREServerX509CAExpiryCritical fires when CA expires < 24h"
    interval: 1m
    input_series:
      - series: 'spire_server_manager_x509_ca_rotate_expiration{trust_domain_id="example.org"}'
        values: "3600x20"
    alert_rule_test:
      - eval_time: 6m
        alertname: SPIREServerX509CAExpiryCritical
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: certificate
              trust_domain_id: example.org
            exp_annotations:
              summary: "SPIRE Server X.509 CA expiring in less than 24 hours"
              description: "Trust domain example.org X.509 CA certificate expires in 54m 0s.\nIMMEDIATE ACTION REQUIRED: Certificate rotation must complete before expiry to prevent service outage.\n"
              runbook: "https://github.com/spiffe/spire/tree/main/doc"

  - name: "K8s SPIREWorkloadAPINoConnections fires when connections == 0"
    interval: 1m
    input_series:
      - series: 'spire_agent_workload_api_connections{instance="agent-1:9989"}'
        values: "0x20"
    alert_rule_test:
      - eval_time: 6m
        alertname: SPIREWorkloadAPINoConnections
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-agent
              category: workload-api
              instance: "agent-1:9989"
            exp_annotations:
              summary: "No active Workload API connections"
              description: "SPIRE Agent has no active Workload API connections for 5+ minutes.\nWorkloads cannot obtain SVIDs. Check agent socket configuration and workload connectivity.\n"
              runbook: "https://github.com/spiffe/spire/tree/main/doc"

  - name: "K8s SPIREDatastoreConnectionFailures fires at rate > 0.5/s"
    interval: 1m
    input_series:
      - series: 'spire_server_datastore_node_fetch{status="INTERNAL", instance="server-1:9988"}'
        values: "0+60x25"
    alert_rule_test:
      - eval_time: 16m
        alertname: SPIREDatastoreConnectionFailures
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: datastore
              status: INTERNAL
              instance: "server-1:9988"
            exp_annotations:
              summary: "SPIRE Server datastore operations failing"
              description: "Datastore operations have 1 errors/s over 5 minutes.\nDatabase connectivity issues detected. SPIRE functionality severely impacted.\n"
              runbook: "https://github.com/spiffe/spire/tree/main/doc"

  - name: "K8s SPIREAgentAttestationFailuresCritical fires at rate > 0.5/s"
    interval: 1m
    input_series:
      - series: 'spire_server_rpc_agent_v1_agent_attest_agent{status="INTERNAL", instance="server-1:9988"}'
        values: "0+60x25"
    alert_rule_test:
      - eval_time: 16m
        alertname: SPIREAgentAttestationFailuresCritical
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-agent
              category: attestation
              status: INTERNAL
              instance: "server-1:9988"
            exp_annotations:
              summary: "High agent attestation failure rate"
              description: "Agent attestation has 1 errors/s over 5 minutes.\nNew agents cannot join the trust domain. Check node attestor configuration and server logs.\n"
              runbook: "https://github.com/spiffe/spire/tree/main/doc"
TESTEOF
run_step "Unit tests - Kubernetes rules" \
    promtool test rules "$TMPDIR_RULES/k8s_test.yaml"

# OpenShift unit tests
cat > "$TMPDIR_RULES/ocp_test.yaml" <<'TESTEOF'
rule_files:
  - ocp-rules.yaml

evaluation_interval: 1m

tests:
  - name: "OCP SPIREServerDown fires after 5m"
    interval: 1m
    input_series:
      - series: 'up{job="spire-server", namespace="openshift-spiffe-spire", instance="server-1:9988"}'
        values: "0x20"
    alert_rule_test:
      - eval_time: 6m
        alertname: SPIREServerDown
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: availability
              namespace: openshift-spiffe-spire
              job: spire-server
              instance: "server-1:9988"
            exp_annotations:
              summary: "SPIRE Server is down"
              description: "SPIRE Server server-1:9988 has been down for 5+ minutes.\nAgents cannot attest, workloads cannot get new SVIDs. IMMEDIATE ACTION REQUIRED.\n\nCheck:\n- Server deployment status: oc get deployment spire-server -n openshift-spiffe-spire\n- Server pod logs: oc logs -n openshift-spiffe-spire -l app=spire-server\n- Datastore connectivity\n"

  - name: "OCP SPIREServerX509CAExpiryCritical fires when CA expires < 24h"
    interval: 1m
    input_series:
      - series: 'spire_server_manager_x509_ca_rotate_expiration{trust_domain_id="example.org"}'
        values: "3600x20"
    alert_rule_test:
      - eval_time: 6m
        alertname: SPIREServerX509CAExpiryCritical
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: certificate
              namespace: openshift-spiffe-spire
              trust_domain_id: example.org
            exp_annotations:
              summary: "SPIRE Server X.509 CA expiring in less than 24 hours"
              description: "Trust domain example.org X.509 CA certificate expires in 54m 0s.\nIMMEDIATE ACTION REQUIRED: Certificate rotation must complete before expiry to prevent service outage.\n\nImpact: All SVID issuance will fail, breaking Zero Trust authentication cluster-wide.\n"
              runbook_url: "https://github.com/spiffe/spire/tree/main/doc"
              alert_type: "Platform"

  - name: "OCP SPIRESkippedNodeEventIDsHigh fires when > 100"
    interval: 1m
    input_series:
      - series: 'spire_server_node_skipped_node_event_ids_count{instance="server-1:9988"}'
        values: "150x20"
    alert_rule_test:
      - eval_time: 11m
        alertname: SPIRESkippedNodeEventIDsHigh
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-server
              category: datastore
              namespace: openshift-spiffe-spire
              instance: "server-1:9988"
            exp_annotations:
              summary: "High number of skipped node event IDs (PostgreSQL issue)"
              description: "150 skipped node event IDs detected.\nThis indicates PostgreSQL autoincrement configuration issues or event-based cache problems.\n\nKnown issue: https://github.com/spiffe/spire/issues/5341\n"

  - name: "OCP SPIREServerRestarted fires when uptime < 300000ms"
    interval: 1m
    input_series:
      - series: 'spire_server_uptime_in_ms{instance="server-1:9988"}'
        values: "100000x10"
    alert_rule_test:
      - eval_time: 3m
        alertname: SPIREServerRestarted
        exp_alerts:
          - exp_labels:
              severity: warning
              component: spire-server
              category: availability
              namespace: openshift-spiffe-spire
              instance: "server-1:9988"
            exp_annotations:
              summary: "SPIRE Server was recently restarted"
              description: "SPIRE Server uptime is 100kms.\nServer was restarted recently. Check logs for crash or restart reason.\n\nOOMKilled events: oc get events -n openshift-spiffe-spire | grep OOMKilled\n"

  - name: "OCP SPIREWorkloadAPINoConnections fires when connections == 0"
    interval: 1m
    input_series:
      - series: 'spire_agent_workload_api_connections{instance="agent-1:9989"}'
        values: "0x20"
    alert_rule_test:
      - eval_time: 6m
        alertname: SPIREWorkloadAPINoConnections
        exp_alerts:
          - exp_labels:
              severity: critical
              component: spire-agent
              category: workload-api
              namespace: openshift-spiffe-spire
              instance: "agent-1:9989"
            exp_annotations:
              summary: "No active Workload API connections on agent"
              description: "SPIRE Agent agent-1:9989 has no active Workload API connections for 5+ minutes.\nWorkloads on this node cannot obtain SVIDs.\n\nCheck:\n- Unix socket permissions and path\n- SELinux context (OpenShift uses enforcing mode)\n- Pod security context allowing socket access\n"
TESTEOF
run_step "Unit tests - OpenShift rules" \
    promtool test rules "$TMPDIR_RULES/ocp_test.yaml"

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
