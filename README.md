# mesh-lab

Laboratorio local para practicar canary, A/B, mirroring y progressive delivery y **ver por dónde fluye el tráfico**.
50-150 microservicios sin código (todos son la misma imagen `fake-service`) sobre kind + Istio ambient.

```
k6 (en el cluster) ──► fe-001..fe-0NN ──► api-* ──► biz-* ──► data-* ──► ext-*
                              todo el tráfico L7 pasa por 1 waypoint (Envoy) en el namespace `mesh`
                                   │
                  Prometheus ◄─────┤ métricas por servicio/versión (istio_requests_total)
                  Kiali      ◄─────┤ grafo de tráfico con % por arista
                  Tempo      ◄─────┘ trazas (fake-service ─Zipkin─► Tempo)
```

## Requisitos (Windows + WSL2)

- Docker Desktop con ~9 GiB para WSL (`docker info | findstr "Total Memory"`).
- Todo se ejecuta **dentro de Ubuntu (WSL)**, no en PowerShell. Activa la integración de Ubuntu en Docker Desktop.

```bash
make tools      # instala kind, kubectl, helm, envsubst
make up         # cluster + Istio ambient + Prometheus/Grafana + Tempo + Kiali + Argo Rollouts + k6-operator (~10 min)
make deploy N=50
make verify     # humo: pods, waypoint, una petición real, métricas
make ui         # Grafana :3000 (admin/admin), Kiali :20001, Argo Rollouts :3100, Prometheus :9090
make load SCENARIO=baseline RATE=20
```

Empieza con `N=50`. Sube a 100 y luego a 150 mirando `docker stats` / `make status`. Con 9 GiB, 150 es el techo razonable.

## Qué hay en el grafo

`make generate N=100` escribe `generated/topology.yaml` (semilla fija → mismo grafo siempre) e imprime las
**llamadas internas por petición de usuario**. Importante: fake-service llama a *todos* sus upstreams en cada
petición, así que el fan-out se multiplica; el generador lo mantiene en 1-2 por servicio (~19 llamadas internas
por petición con N=100). Con `RATE=20` son ~400 req/s internos.

El generador elige automáticamente, entre los servicios más transitados de las capas intermedias:

| Tipo | Qué se despliega | Para qué |
|---|---|---|
| `canary` (2 por defecto) | Argo Rollout + `-stable`/`-canary` + VirtualService | canary con análisis automático |
| `variants` modo `ab` | Deployments `-v1`/`-v2` + VirtualService por cabecera | A/B testing |
| `variants` modo `mirror` | igual, con shadow traffic a v2 | dark launch |
| resto | Deployment + Service | tráfico de fondo |

Los nombres elegidos salen al ejecutar `make generate` (p. ej. `canary: ['data-001', 'data-023']`).

## Experimentos

**Canary automático** (Argo Rollouts, pasos 10% → 30% → 60%, 45 s cada uno, análisis sobre Prometheus):

```bash
make load SCENARIO=baseline                       # tráfico estable
make canary-release SVC=data-001 VERSION=v2 ERR=0.0   # versión buena: debería completarse
make canary-release SVC=data-001 VERSION=v3 ERR=0.4   # versión mala: debería abortarse sola
```
Míralo en el dashboard de Argo Rollouts (:3100), en Kiali (porcentajes en las aristas) y en el dashboard
"Traffic by version" de Grafana (escribe el servicio, p. ej. `data-001`).

**A/B por cabecera**: k6 envía `x-user-group: beta` al 20% de los usuarios y fake-service reenvía las cabeceras,
así que el VirtualService en medio del grafo las ve. El grupo beta va a v2 (más lenta y con 10% de errores).

```bash
make exp-mode SVC=biz-010 MODE=ab        # beta → v2, resto → v1
make exp-mode SVC=biz-010 MODE=split PCT=20   # 80/20 por peso
make exp-mode SVC=data-003 MODE=mirror   # v1 responde; v2 recibe copia
make exp-mode SVC=biz-010 MODE=off
```
(Cambia `SVC` por los nombres que imprimió `make generate`.)

**Carga**: `SCENARIO=baseline` (constante), `ramp` (sube y baja), `spike` (x5 durante 1 min, útil para ver cascadas de errores).

**Feature flags**: no incluido todavía. Es la única pieza que necesita código (un servicio que consulte flagd).

## Estado de verificación (léelo)

Lo que sí se probó aquí: el generador (grafo acíclico, todos los servicios alcanzables, determinista),
la sintaxis de las plantillas Helm, y que los YAML/JSON/shell se parsean.

Lo que **no** se pudo probar: no había Helm ni cluster en el entorno donde se generó, así que el chart no se
renderizó con `helm template` y nada se ejecutó contra Kubernetes. Si algo falla, es lo primero que hay que mirar:

1. `helm template mesh charts/mesh -f generated/topology.yaml | head -200` antes de `make deploy`.
2. **Tempo**: el chart pasó a `grafana-community/tempo`. Los valores de `values/tempo.yaml` son de mi mejor estimación;
   comprueba `kubectl -n monitoring get svc tempo` (esperado: 9411 y 3200) y ajusta `values/tempo.yaml`, `values/kiali.yaml`,
   `values/kps.yaml` y `charts/mesh/values.yaml` si los puertos difieren.
3. **Métricas L7**: en ambient solo el waypoint emite `istio_requests_total` (con `reporter="waypoint"`). Si Grafana sale vacío,
   mira en Prometheus → Status → Targets que `istio-waypoint` está UP y que existe esa métrica. Los dashboards y el `AnalysisTemplate` dependen de ella.
4. **Imagen**: `nicholasjackson/fake-service:v0.26.2`; si `docker pull` falla, cambia `IMAGE=` (`make deploy IMAGE=...`).
5. **k6-operator**: si `helm install` dice que no encuentra el chart, mira si también se movió a `grafana-community`.
6. fake-service **no expone métricas Prometheus** (solo Datadog/Zipkin); por eso todo se mide en el waypoint, no en la app.

## Limpieza

```bash
make down       # borra el cluster
```
