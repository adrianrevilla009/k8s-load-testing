apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-${SCENARIO}
  namespace: load
spec:
  parallelism: 1
  script:
    configMap:
      name: k6-scenarios
      file: scenarios.js
  arguments: --out experimental-prometheus-rw
  runner:
    env:
      - name: SCENARIO
        value: "${SCENARIO}"
      - name: ENTRYPOINTS
        value: "${ENTRYPOINTS}"
      - name: RATE
        value: "${RATE}"
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: "http://kps-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
      - name: K6_PROMETHEUS_RW_TREND_STATS
        value: "p(95),p(99),avg"
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        memory: 384Mi
