{{/*
Resolve one service: defaults < services[] entry < overrides[name].
Uses set() so that a zero value (errorRate: 0) in an override still wins.
Returns YAML.
*/}}
{{- define "mesh.resolve" -}}
{{- $m := dict -}}
{{- range $k, $v := .root.Values.defaults }}{{ $_ := set $m $k $v }}{{ end -}}
{{- range $k, $v := .svc }}{{ $_ := set $m $k $v }}{{ end -}}
{{- $o := get .root.Values.overrides .svc.name | default (dict) -}}
{{- range $k, $v := $o }}{{ $_ := set $m $k $v }}{{ end -}}
{{- toYaml $m -}}
{{- end -}}

{{/*
Pod template (metadata + spec) for one fake-service instance.
Expects: image, resources, tracing, zipkin, name, version, uris, errorRate, p50, p90, p99
*/}}
{{- define "mesh.podTemplate" -}}
metadata:
  labels:
    app: {{ .name }}
    version: {{ .version | quote }}
spec:
  containers:
    - name: app
      image: {{ .image }}
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 9090
      env:
        - name: NAME
          value: {{ .name | quote }}
        - name: MESSAGE
          value: {{ printf "%s %s" .name .version | quote }}
        - name: LISTEN_ADDR
          value: "0.0.0.0:9090"
        - name: UPSTREAM_URIS
          value: {{ .uris | quote }}
        - name: UPSTREAM_WORKERS
          value: "2"
        - name: ERROR_RATE
          value: {{ .errorRate | toString | quote }}
        - name: TIMING_50_PERCENTILE
          value: {{ printf "%vms" .p50 | quote }}
        - name: TIMING_90_PERCENTILE
          value: {{ printf "%vms" .p90 | quote }}
        - name: TIMING_99_PERCENTILE
          value: {{ printf "%vms" .p99 | quote }}
        - name: TIMING_VARIANCE
          value: "10"
        - name: HTTP_CLIENT_KEEP_ALIVES
          value: "true"
        - name: HTTP_SERVER_KEEP_ALIVES
          value: "true"
        - name: HTTP_CLIENT_REQUEST_TIMEOUT
          value: "5s"
        - name: LOG_LEVEL
          value: "warn"
        {{- if .tracing }}
        - name: TRACING_ZIPKIN
          value: {{ .zipkin | quote }}
        {{- end }}
      readinessProbe:
        httpGet:
          path: /health
          port: http
        periodSeconds: 10
        initialDelaySeconds: 1
      resources:
        {{- toYaml .resources | nindent 8 }}
{{- end -}}
