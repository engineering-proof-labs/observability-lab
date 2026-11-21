#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('baseline', 'incident', 'recovery')][string]$Phase,
    [Parameter(Mandatory)][int]$DelayMs,
    [Parameter(Mandatory)][string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$Phase = $Phase.ToLowerInvariant()
$expectedDelay = @{ baseline = 0; incident = 150; recovery = 0 }
if ($DelayMs -ne $expectedDelay[$Phase]) {
    throw "$Phase requires -DelayMs $($expectedDelay[$Phase])."
}
$phasePath = Join-Path $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot) $Phase

function Invoke-Docker {
    $output = & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($args -join ' ') exited with code $LASTEXITCODE."
    }
    $output
}

function Get-ContainerState {
    $services = [ordered]@{}
    foreach ($service in 'checkout', 'shipping', 'jaeger') {
        $id = Invoke-Docker compose ps -q $service
        if (!$id) { throw "$service is not running. Start the lab with docker compose up --build --wait." }
        $container = (Invoke-Docker inspect $id) -join "`n" | ConvertFrom-Json
        if (!$container.State.Running -or ($service -ne 'jaeger' -and $container.State.Health.Status -ne 'healthy')) {
            throw "$service is not ready."
        }
        $services[$service] = [ordered]@{
            id = $container.Id
            image = $container.Image
            imageReference = $container.Config.Image
            startedAt = $container.State.StartedAt
            restarts = $container.RestartCount
            resources = [ordered]@{
                memoryBytes = $container.HostConfig.Memory
                nanoCpus = $container.HostConfig.NanoCpus
                cpuPeriod = $container.HostConfig.CpuPeriod
                cpuQuota = $container.HostConfig.CpuQuota
                cpuShares = $container.HostConfig.CpuShares
                cpuSet = $container.HostConfig.CpusetCpus
            }
            experimentEnvironment = @($container.Config.Env | Where-Object {
                $_ -match '^(SHIPPING_DELAY_MS|OTEL_EXPORTER_OTLP_TRACES_ENDPOINT|OTEL_SEMCONV_STABILITY_OPT_IN)='
            } | Sort-Object)
        }
    }
    $services
}

function Invoke-RequestBlock([int]$Block, [int]$Count) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($index = 1; $index -le $Count; $index++) {
        $scheduledMs = ($index - 1) * 500
        while (($remainingMs = $scheduledMs - $clock.Elapsed.TotalMilliseconds) -gt 0) {
            if ($remainingMs -gt 2) { Start-Sleep -Milliseconds ([int][math]::Floor($remainingMs - 1)) }
            else { [Threading.Thread]::SpinWait(100) }
        }

        $response = $null
        $status = 0
        $traceId = ''
        $quoteMatches = $false
        $requestError = ''
        $startedAt = [DateTimeOffset]::UtcNow
        $startedMs = $clock.Elapsed.TotalMilliseconds
        try {
            # GetAsync buffers the complete body before finishing.
            $response = $client.GetAsync("$checkoutUrl/checkout").GetAwaiter().GetResult()
            $finishedMs = $clock.Elapsed.TotalMilliseconds
            $status = [int]$response.StatusCode
            if ($response.Headers.Contains('X-Trace-ID')) {
                $traceId = $response.Headers.GetValues('X-Trace-ID') -join ','
            }
            if ($status -eq 200) {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                $quoteMatches = $body.shipping_cents -ceq 499 -and $body.currency -ceq 'USD'
            }
        } catch {
            if (!$response) { $finishedMs = $clock.Elapsed.TotalMilliseconds }
            $requestError = $_.Exception.GetBaseException().Message
        } finally {
            if ($response) { $response.Dispose() }
        }

        [pscustomobject][ordered]@{
            block = $Block
            attempt = $index
            startedAtUtc = $startedAt.ToString('o')
            scheduledMs = $scheduledMs
            startLagMs = $startedMs - $scheduledMs
            clientDurationMs = $finishedMs - $startedMs
            crossedNextSlot = $finishedMs -ge ($scheduledMs + 500)
            status = $status
            quoteMatches = $quoteMatches
            traceId = $traceId
            error = $requestError
        }
    }
}

function Save-Scrape([string]$Name) {
    (Invoke-WebRequest -Uri "$checkoutUrl/metrics" -NoProxy -TimeoutSec 3).Content |
        Set-Content -LiteralPath (Join-Path $phasePath "$Name.prom")
}

function Save-Trace([string]$TraceId) {
    if ($TraceId -cnotmatch '^[a-f0-9]{32}$') {
        throw 'The first measured request did not return a valid trace ID.'
    }
    $poll = [Diagnostics.Stopwatch]::StartNew()
    do {
        $response = Invoke-WebRequest -Uri "$jaegerUrl/api/traces/$TraceId" -NoProxy -SkipHttpErrorCheck -TimeoutSec 3
        if ($response.StatusCode -eq 200) {
            $trace = ($response.Content | ConvertFrom-Json).data
            if (@($trace).Count -eq 1 -and $trace[0].spans.Count -ge 4) {
                $response.Content | Set-Content -LiteralPath (Join-Path $phasePath 'trace.json')
                return
            }
        }
        Start-Sleep -Milliseconds 500
    } while ($poll.Elapsed.TotalSeconds -lt 15)
    throw "Jaeger did not return the complete selected trace $TraceId."
}

$previousDelay = $env:SHIPPING_DELAY_MS
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    if (Test-Path -LiteralPath $phasePath) { throw "Output already exists at $phasePath. Use a fresh output root." }
    [IO.Directory]::CreateDirectory($phasePath) | Out-Null
    $env:SHIPPING_DELAY_MS = [string]$DelayMs
    Invoke-Docker compose up -d --no-deps --no-build --force-recreate --wait --wait-timeout 30 shipping

    $checkoutUrl = 'http://' + (Invoke-Docker compose port checkout 8080)
    $jaegerUrl = 'http://' + (Invoke-Docker compose port jaeger 16686)
    $sourceFiles = @('.dockerignore', 'Dockerfile', 'compose.yaml', 'go.mod', 'go.sum', 'scripts/run-phase.ps1')
    $sourceFiles += Get-ChildItem cmd, internal -Recurse -Filter '*.go' -File | ForEach-Object {
        [IO.Path]::GetRelativePath((Get-Location).Path, $_.FullName).Replace('\', '/')
    }
    $sources = [ordered]@{}
    foreach ($source in ($sourceFiles | Sort-Object)) { $sources[$source] = (Get-FileHash -LiteralPath $source).Hash }
    $revision = & git rev-parse --verify HEAD 2>$null
    $runtime = (Invoke-Docker info --format '{{json .}}') | ConvertFrom-Json
    $manifest = [ordered]@{
        phase = $Phase
        delayMs = $DelayMs
        startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        checkoutUrl = $checkoutUrl
        jaegerUrl = $jaegerUrl
        environment = [ordered]@{
            machine = [Environment]::MachineName
            os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            powerShell = $PSVersionTable.PSVersion.ToString()
            dockerEngine = $runtime.ServerVersion
            compose = (Invoke-Docker compose version --short)
            dockerCpuCount = $runtime.NCPU
            dockerMemoryBytes = $runtime.MemTotal
            goBuilder = (Get-Content -LiteralPath Dockerfile -TotalCount 1).Split(' ')[1]
        }
        revision = $revision
        sourceSha256 = $sources
        containersBefore = Get-ContainerState
    }
    if ($manifest.containersBefore.shipping.experimentEnvironment -cnotcontains "SHIPPING_DELAY_MS=$DelayMs") {
        throw "Shipping did not start with the requested $DelayMs ms delay."
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $phasePath 'phase.json')

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(2)
    try {
        Save-Scrape 'pre-warmup'
        Invoke-RequestBlock -Block 0 -Count 20 | Export-Csv -LiteralPath (Join-Path $phasePath 'warmup.csv')
        Start-Sleep -Seconds 1
        $requestPath = Join-Path $phasePath 'requests.csv'
        for ($block = 1; $block -le 3; $block++) {
            Save-Scrape "block-$block-before"
            $rows = @(Invoke-RequestBlock -Block $block -Count 100)
            Start-Sleep -Seconds 1
            $rows | Export-Csv -LiteralPath $requestPath -Append
            Save-Scrape "block-$block-after"
            if ($block -eq 1) { $firstTraceId = $rows[0].traceId }
            $ok = @($rows | Where-Object { $_.status -eq 200 }).Count
            $timingIssues = @($rows | Where-Object { $_.startLagMs -gt 50 -or $_.crossedNextSlot }).Count
            Write-Host "$Phase block $block completed with $ok HTTP 200 responses and $timingIssues cadence violations."
        }
    } finally {
        $client.Dispose()
    }
    $manifest.containersAfter = Get-ContainerState
    $manifest.finishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $manifest.firstTraceId = $firstTraceId
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $phasePath 'phase.json')
    Save-Trace $firstTraceId
    Write-Host "Saved $Phase evidence and trace $firstTraceId to $phasePath."
} finally {
    $env:SHIPPING_DELAY_MS = $previousDelay
    Pop-Location
}
