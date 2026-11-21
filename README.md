# Debugging a Slow Checkout with OpenTelemetry

Checkout calls shipping over HTTP and returns its quote. A delayed quote can make checkout slow while its response still says HTTP 200. This local Go lab uses a request-duration histogram to compare three phases and a Jaeger trace to inspect where one request spent time.

## The symptom

The simulated incident adds a 150 ms wait to shipping. Both services keep the same route, response and code throughout the experiment. The measured workload stays fixed at one request every 500 ms, with at most one request in flight.

In the recorded run, all 300 incident requests returned HTTP 200 while mean checkout server duration rose from 1.666 ms to 152.301 ms.

## The hypothesis

Checkout waits synchronously for [shipping's quote](cmd/checkout/main.go). If shipping accounts for the change, checkout's server duration will rise across requests, and the wait in [shipping's server trace](cmd/shipping/main.go) will grow with the injected delay.

## What the trace shows

```text
checkout  GET /checkout     server
└─ checkout  HTTP GET       client
   └─ shipping  GET /quote  server
      └─ shipping.delay     internal
```

The checkout handler derives a one-second deadline from its incoming `context.Context` and passes that context to the outbound HTTP request. Each process has its own Go context. The instrumented transport creates the client span and injects its trace and span IDs in the W3C `traceparent` header. Shipping extracts the header and creates a server span whose parent is the client span. All four spans share a Trace ID, and each has a distinct Span ID. [Trace setup](internal/lab/server.go)

The `lab.shipping.delay_ms` attribute records the configured delay. The duration of `shipping.delay` records the elapsed wait. The checkout and shipping server spans include time spent in their children, so their durations overlap.

The first measured request of each phase supplied the example trace. In the simulated incident, shipping spent 150.722 ms waiting inside a 151.144 ms server span. That wait is where the extra time appeared in the selected request.

| Phase | Trace ID | Checkout server (ms) | Shipping server (ms) | Shipping wait (ms) |
| --- | --- | ---: | ---: | ---: |
| Baseline | `f5f1dd6b80c800ca904d11a2ba4d8570` | 1.166 | 0.090 | 0.001 |
| Simulated incident | `fe1e9e0b3973b5d38dac3ec48710ff64` | 152.806 | 151.144 | 150.722 |
| Recovery | `379917dfcf7761bbc2e7015080121cf7` | 1.274 | 0.052 | 0.001 |

## Verifying recovery

The [checkout HTTP histogram](cmd/checkout/metrics.go) records `http.server.request.duration` in seconds. Its Prometheus exposition includes a cumulative count, sum and a bucket at 100 ms. The comparison script uses the difference between the snapshots at the start and end of each block to compute the checkout mean and the share of calls above 100 ms. Client timings cover the whole response, including the body, and are reported separately.

Each phase starts with 20 warmup calls. It then measures three blocks of 100 calls under the same schedule. The evidence includes all client statuses and the first measured trace from each phase. The [comparison script](scripts/compare-phases.ps1) checks counts, HTTP 200 responses, quote content, cadence, trace parent IDs and the shipping wait. It also checks the source and environment records, container continuity and histogram counter resets.

The recovery band is centered on the median of the three baseline block means. Its margin is the largest of 5 ms, 10% of that median, and the largest observed baseline block deviation. If the margin exceeds a quarter of the injected delay, the run is inconclusive. Each incident block must exceed the band and the phase mean must rise by at least half the injected delay. The wait in the selected incident trace must be between 145 and 175 ms. Each recovery block must fall inside the band, and the selected shipping wait span must return to 5 ms or less with the configured delay back at zero.

| Phase | Injected wait | HTTP 200 | Checkout mean (ms) | Block means (ms) | Above 100 ms |
| --- | ---: | ---: | ---: | --- | ---: |
| Baseline | 0 ms | 300/300 | 1.666 | 1.827, 1.711, 1.460 | 0% |
| Simulated incident | 150 ms | 300/300 | 152.301 | 152.558, 152.219, 152.127 | 100% |
| Recovery | 0 ms | 300/300 | 1.273 | 1.330, 1.217, 1.272 | 0% |

The baseline center was 1.711 ms. The 5 ms margin yielded a recovery band of 0 to 6.711 ms, and all three recovery blocks fell within it. The selected recovery trace recorded 0.001 ms in `shipping.delay`. The comparator verified recovery for this run on Docker Desktop for Windows with Go 1.26.9 and Jaeger 2.23.0.

## Reproduce the experiment

Use Docker with Compose v2, PowerShell 7.2 or later, Git and curl. The [Compose manifest](compose.yaml) builds the Go binaries inside Docker and starts Jaeger. The runner records the Git revision and hashes the experiment sources. Run the commands from the repository root.

```powershell
$env:SHIPPING_DELAY_MS = '0'
docker compose config --quiet
docker compose up --build --wait
curl.exe -sS --max-time 2 -i http://127.0.0.1:8080/checkout
curl.exe -fsS http://127.0.0.1:8080/metrics
```

On macOS or Linux, use `curl` in place of `curl.exe`. If port 8080 is already in use, set `$env:CHECKOUT_PORT = '18080'` before starting Compose and use that port for manual HTTP calls. The phase runner discovers the published checkout and Jaeger ports from Compose.

Expect HTTP 200 and `{"shipping_cents":499,"currency":"USD"}`. Open [Jaeger](http://127.0.0.1:16686) and paste the response's `X-Trace-ID` into **Lookup by Trace ID**. Allow a few seconds for the batch exporter. After that first call, `GET /metrics` should expose `http_server_request_duration_seconds_count` for checkout.

Run the three phases in order. Allow about eight minutes and keep extra checkout traffic outside the run. Choose a fresh output directory outside the repository.

```powershell
$outputRoot = Join-Path ([IO.Path]::GetTempPath()) ("observability-lab-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
pwsh -NoProfile -File ./scripts/run-phase.ps1 -Phase baseline -DelayMs 0 -OutputRoot $outputRoot
pwsh -NoProfile -File ./scripts/run-phase.ps1 -Phase incident -DelayMs 150 -OutputRoot $outputRoot
pwsh -NoProfile -File ./scripts/run-phase.ps1 -Phase recovery -DelayMs 0 -OutputRoot $outputRoot
pwsh -NoProfile -File ./scripts/compare-phases.ps1 -OutputRoot $outputRoot
```

Advance to the next command after the previous one succeeds. The [phase runner](scripts/run-phase.ps1) recreates shipping with the same image in every phase and leaves checkout and Jaeger running. It saves request CSVs, Prometheus snapshots, the selected trace JSON and a manifest in each phase directory. The comparator writes `comparison.md` and exits with status 1 if evidence is invalid or recovery is unconfirmed.

Inspect the selected traces in Jaeger before shutting down. Jaeger holds live traces in memory. The JSON files saved by the runner remain available after cleanup.

```powershell
docker compose down
```

## Limits

This simulation uses one host, one endpoint, one HTTP dependency and a fixed request schedule, with full sampling for traces started by checkout. The injected delay represents waiting. The results describe latency and recovery for this workload on the recorded host. The recovery band is an operational tolerance for this experiment.
