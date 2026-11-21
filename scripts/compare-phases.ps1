#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$culture = [Globalization.CultureInfo]::InvariantCulture
$root = (Resolve-Path -LiteralPath $OutputRoot).Path
$phases = [ordered]@{ baseline = 0; incident = 150; recovery = 0 }

function Assert-Run([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Read-CsvNumber([string]$Text) {
    # Export-Csv uses the writer's decimal separator and does not add group separators.
    $decimal = $Text.Replace(',', '.').Replace([char]0x066B, [char]'.')
    [double]::Parse($decimal, [Globalization.NumberStyles]::Float, $culture)
}

function Read-Histogram([string]$Path) {
    $series = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $sample = [regex]::Match($line, '^http_server_request_duration_seconds_(?<kind>count|sum|bucket)\{(?<labels>[^}]+)\}\s+(?<value>\S+)\s*$')
        if (!$sample.Success) { continue }
        $labels = $sample.Groups['labels'].Value
        Assert-Run ($labels -match '(?:^|,)http_route="/checkout"(?:,|$)' -and
            $labels -match '(?:^|,)http_request_method="GET"(?:,|$)') "Unexpected route in histogram $Path."
        $status = [regex]::Match($labels, '(?:^|,)http_response_status_code="(?<code>\d{3})"(?:,|$)')
        Assert-Run $status.Success "Missing status in histogram $Path."
        $code = $status.Groups['code'].Value
        $kind = $sample.Groups['kind'].Value
        if ($kind -eq 'bucket') {
            $bucket = [regex]::Match($labels, '(?:^|,)le="(?<edge>[^"]+)"(?:,|$)').Groups['edge'].Value
            $edge = 0.0
            if ($bucket -eq '+Inf') { $kind = 'inf' }
            elseif ([double]::TryParse($bucket, [Globalization.NumberStyles]::Float, $culture, [ref]$edge) -and $edge -eq 0.1) {
                $kind = 'le100'
            } else { continue }
        }
        $value = [double]::Parse($sample.Groups['value'].Value, [Globalization.NumberStyles]::Float, $culture)
        Assert-Run ([double]::IsFinite($value) -and $value -ge 0) "Invalid $kind sample in $Path."
        if ($kind -ne 'sum') { Assert-Run ($value -eq [math]::Floor($value)) "Fractional count in $Path." }
        if (!$series.ContainsKey($code)) { $series[$code] = @{} }
        Assert-Run (!$series[$code].ContainsKey($kind)) "Duplicate $kind sample for HTTP $code in $Path."
        $series[$code][$kind] = $value
    }
    foreach ($point in $series.Values) {
        Assert-Run ($point.Keys.Count -eq 4 -and $point['inf'] -eq $point['count'] -and $point['le100'] -le $point['count']) "Incomplete or inconsistent histogram in $Path."
    }
    return $series
}

function Compare-Histograms([hashtable]$Before, [hashtable]$After, [string]$Window) {
    $count = 0
    $sum = 0.0
    $above = 0
    $ok = 0
    $codes = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    foreach ($code in $codes) {
        $delta = @{}
        foreach ($kind in 'count', 'sum', 'le100') {
            $old = if ($Before.ContainsKey($code)) { $Before[$code][$kind] } else { 0 }
            $new = if ($After.ContainsKey($code)) { $After[$code][$kind] } else { 0 }
            Assert-Run ($new -ge $old) "Histogram reset in $Window for HTTP ${code}."
            $delta[$kind] = $new - $old
        }
        Assert-Run ($delta['le100'] -le $delta['count'] -and ($delta['count'] -gt 0 -or $delta['sum'] -eq 0)) "Inconsistent histogram delta in $Window."
        $count += $delta['count']
        $sum += $delta['sum']
        $above += $delta['count'] - $delta['le100']
        if ($code -eq '200') { $ok = $delta['count'] }
    }
    [pscustomobject]@{ Count = $count; Sum = $sum; Above100 = $above; Http200 = $ok }
}

function Assert-Requests([object[]]$Rows, [int]$Block, [int]$Count, [string]$Label) {
    Assert-Run ($Rows.Count -eq $Count) "$Label requires $Count request records."
    for ($i = 0; $i -lt $Count; $i++) {
        $row = $Rows[$i]
        $attempt = $i + 1
        Assert-Run ($row.block -eq $Block -and $row.attempt -eq $attempt -and $row.scheduledMs -eq (500 * $i)) "$Label request $attempt has the wrong schedule."
        Assert-Run ($row.status -eq '200' -and $row.quoteMatches -eq 'True' -and !$row.error) "$Label request $attempt returned status $($row.status), quote match $($row.quoteMatches), error '$($row.error)'."
        Assert-Run ($row.traceId -cmatch '^[a-f0-9]{32}$') "$Label request $attempt has no valid trace ID."
        if ($Block -eq 0) { continue }
        $lag = Read-CsvNumber $row.startLagMs
        $duration = Read-CsvNumber $row.clientDurationMs
        Assert-Run ($lag -ge 0 -and $lag -le 50 -and $duration -ge 0 -and
            ($lag + $duration) -lt 500 -and $row.crossedNextSlot -eq 'False') "$Label request $attempt missed the cadence (lag $lag ms, duration $duration ms)."
    }
}

function Read-Trace([string]$Path, [string]$TraceId, [int]$Delay) {
    $traces = @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).data)
    Assert-Run ($traces.Count -eq 1 -and $traces[0].traceID -ceq $TraceId) "Jaeger trace does not match the first measured request."
    $trace = $traces[0]
    Assert-Run ($trace.spans.Count -eq 4 -and @($trace.spans.spanID | Sort-Object -Unique).Count -eq 4) "Expected four distinct spans in $TraceId."
    $spans = @{}
    foreach ($span in $trace.spans) {
        Assert-Run ($span.traceID -ceq $TraceId -and $span.spanID -cmatch '^[a-f0-9]{16}$' -and $span.duration -ge 0) "Invalid span ID or duration in $TraceId."
        $tags = @{}
        foreach ($tag in $span.tags) { $tags[$tag.key] = $tag.value }
        $service = $trace.processes.PSObject.Properties[$span.processID].Value.serviceName
        $key = "$service/$($tags['span.kind'])/$($span.operationName)"
        $spans[$key] = [pscustomobject]@{ Span = $span; Tags = $tags }
    }
    $chain = 'checkout/server/GET /checkout', 'checkout/client/HTTP GET', 'shipping/server/GET /quote', 'shipping/internal/shipping.delay'
    $parent = $null
    foreach ($key in $chain) {
        Assert-Run ($spans.ContainsKey($key)) "Missing span $key in $TraceId."
        $entry = $spans[$key]
        $references = @($entry.Span.references)
        if ($null -eq $parent) {
            Assert-Run ($references.Count -eq 0) "Checkout server is not the root of $TraceId."
        } else {
            Assert-Run ($references.Count -eq 1 -and $references[0].refType -eq 'CHILD_OF' -and
                $references[0].traceID -ceq $TraceId -and $references[0].spanID -ceq $parent) "Invalid parent of $key in $TraceId."
        }
        if ($key -ne $chain[-1]) {
            # Jaeger's query response can represent this attribute with its older key.
            $status = $entry.Tags['http.response.status_code'] ?? $entry.Tags['http.status_code']
            Assert-Run ($status -eq 200) "Expected HTTP 200 in span $key."
        }
        $parent = $entry.Span.spanID
    }
    $wait = $spans[$chain[-1]]
    $waitMs = $wait.Span.duration / 1000.0
    $minWait = [math]::Max(0, $Delay - 5)
    $maxWait = if ($Delay -eq 0) { 5 } else { $Delay + 25 }
    Assert-Run ($wait.Tags.ContainsKey('lab.shipping.delay_ms') -and $wait.Tags['lab.shipping.delay_ms'] -eq $Delay -and
        $waitMs -ge $minWait -and $waitMs -le $maxWait) "Unexpected shipping wait of $waitMs ms in $TraceId."
    [pscustomobject]@{
        Id = $TraceId
        CheckoutMs = $spans[$chain[0]].Span.duration / 1000.0
        ShippingMs = $spans[$chain[2]].Span.duration / 1000.0
        WaitMs = $waitMs
    }
}

function Get-PhaseResult([string]$Name, [int]$Delay) {
    $dir = Join-Path $root $Name
    $manifest = Get-Content -LiteralPath (Join-Path $dir 'phase.json') -Raw | ConvertFrom-Json
    Assert-Run ($manifest.phase -ceq $Name -and $manifest.delayMs -eq $Delay -and
        $manifest.containersBefore.shipping.experimentEnvironment -ccontains "SHIPPING_DELAY_MS=$Delay") "Wrong phase or applied delay."
    Assert-Run ((Get-Signature $manifest.containersBefore) -ceq (Get-Signature $manifest.containersAfter)) "A container changed during the phase."
    $warmup = @(Import-Csv -LiteralPath (Join-Path $dir 'warmup.csv'))
    Assert-Requests $warmup 0 20 "$Name warmup"
    $requests = @(Import-Csv -LiteralPath (Join-Path $dir 'requests.csv'))
    Assert-Run ($requests.Count -eq 300 -and @($requests.traceId | Sort-Object -Unique).Count -eq 300) "Expected 300 measured requests with distinct trace IDs."
    Assert-Run ($manifest.firstTraceId -ceq $requests[0].traceId) "Selected trace is not from the first measured request."
    $trace = Read-Trace (Join-Path $dir 'trace.json') $requests[0].traceId $Delay
    $initial = Read-Histogram (Join-Path $dir 'pre-warmup.prom')
    $previous = $initial
    $blocks = for ($block = 1; $block -le 3; $block++) {
        $label = "$Name block $block"
        $first = ($block - 1) * 100
        Assert-Requests $requests[$first..($first + 99)] $block 100 $label
        $before = Read-Histogram (Join-Path $dir "block-$block-before.prom")
        $after = Read-Histogram (Join-Path $dir "block-$block-after.prom")
        $between = Compare-Histograms $previous $before "$label pre-window"
        $expected = if ($block -eq 1) { 20 } else { 0 }
        Assert-Run ($between.Count -eq $expected -and $between.Http200 -eq $expected) "Expected $expected warmup or idle observations before $label. Found $($between.Count)."
        $delta = Compare-Histograms $before $after $label
        Assert-Run ($delta.Count -eq 100 -and $delta.Http200 -eq 100) "Expected 100 HTTP 200 observations in $label. Found $($delta.Count) total."
        $previous = $after
        [pscustomobject]@{ MeanMs = 1000 * $delta.Sum / $delta.Count; SumSeconds = $delta.Sum; Count = $delta.Count; Above100 = $delta.Above100 }
    }
    $count = ($blocks | Measure-Object -Property Count -Sum).Sum
    $clientDurations = @($requests | ForEach-Object { Read-CsvNumber $_.clientDurationMs })
    [pscustomobject]@{
        Manifest = $manifest
        Initial = $initial
        Final = $previous
        Count = $count
        MeanMs = 1000 * ($blocks.SumSeconds | Measure-Object -Sum).Sum / $count
        ClientMeanMs = ($clientDurations | Measure-Object -Average).Average
        Above100Percent = 100 * ($blocks.Above100 | Measure-Object -Sum).Sum / $count
        BlocksMs = $blocks.MeanMs
        Trace = $trace
    }
}

function Get-Signature($Value) {
    ConvertTo-Json -InputObject $Value -Depth 10 -Compress
}

function Get-ShippingConfiguration($State) {
    [ordered]@{
        image = $State.image
        resources = $State.resources
        environment = @($State.experimentEnvironment | Where-Object { $_ -notlike 'SHIPPING_DELAY_MS=*' })
    }
}

function Format-Number([double]$Number) { $Number.ToString('F3', $culture) }

$results = [ordered]@{}
$issues = [Collections.Generic.List[string]]::new()
foreach ($phase in $phases.Keys) {
    try { $results[$phase] = Get-PhaseResult $phase $phases[$phase] }
    catch { $issues.Add("${phase}: $($_.Exception.Message)") }
}

$report = [Collections.Generic.List[string]]::new()
$report.Add('# Checkout latency experiment')
$report.Add('')
$report.Add('| Phase | Injected wait | HTTP 200 | Checkout mean (ms) | Block means (ms) | Above 100 ms | Client mean (ms) |')
$report.Add('| --- | ---: | ---: | ---: | --- | ---: | ---: |')
foreach ($phase in $phases.Keys) {
    if (!$results.Contains($phase)) {
        $report.Add("| $phase | $($phases[$phase]) ms | Invalid evidence | | | | |")
        continue
    }
    $result = $results[$phase]
    $blockText = ($result.BlocksMs | ForEach-Object { Format-Number $_ }) -join ', '
    $report.Add("| $phase | $($phases[$phase]) ms | $($result.Count)/$($result.Count) | $(Format-Number $result.MeanMs) | $blockText | $(Format-Number $result.Above100Percent)% | $(Format-Number $result.ClientMeanMs) |")
}
$report.Add('')
$report.Add('| Phase | Trace ID | Checkout server (ms) | Shipping server (ms) | Shipping wait (ms) |')
$report.Add('| --- | --- | ---: | ---: | ---: |')
foreach ($phase in $results.Keys) {
    $trace = $results[$phase].Trace
    $report.Add("| $phase | $($trace.Id) | $(Format-Number $trace.CheckoutMs) | $(Format-Number $trace.ShippingMs) | $(Format-Number $trace.WaitMs) |")
}

if ($results.Count -eq 3) {
    $baseline = $results.baseline
    $incident = $results.incident
    $recovery = $results.recovery
    try {
        $first = $baseline.Manifest
        $previous = $baseline
        foreach ($next in @($incident, $recovery)) {
            $current = $next.Manifest
            Assert-Run ([DateTimeOffset]$current.startedAtUtc -ge [DateTimeOffset]$previous.Manifest.finishedAtUtc) "Phases must run sequentially."
            Assert-Run ($current.checkoutUrl -ceq $first.checkoutUrl -and $current.jaegerUrl -ceq $first.jaegerUrl -and
                $current.revision -ceq $first.revision -and (Get-Signature $current.sourceSha256) -ceq (Get-Signature $first.sourceSha256) -and
                (Get-Signature $current.environment) -ceq (Get-Signature $first.environment)) "The source or execution environment changed between phases."
            foreach ($service in 'checkout', 'jaeger') {
                Assert-Run ((Get-Signature $current.containersBefore.$service) -ceq (Get-Signature $first.containersBefore.$service)) "$service changed between phases."
            }
            Assert-Run ((Get-Signature (Get-ShippingConfiguration $current.containersBefore.shipping)) -ceq
                (Get-Signature (Get-ShippingConfiguration $first.containersBefore.shipping))) "Shipping configuration changed beyond the injected delay."
            Assert-Run ($current.containersBefore.shipping.id -ne $previous.Manifest.containersAfter.shipping.id) "Shipping must be recreated for every phase."
            $idle = Compare-Histograms $previous.Final $next.Initial 'between phases'
            Assert-Run ($idle.Count -eq 0) "Unexpected checkout calls between phases."
            $previous = $next
        }
        $report.Add('')
        $report.Add('All nine blocks met the workload, status and histogram-count requirements. All three traces passed the parent-chain and shipping-span checks.')
        $center = ($baseline.BlocksMs | Sort-Object)[1]
        $deviations = $baseline.BlocksMs | ForEach-Object { [math]::Abs($_ - $center) }
        $margin = [math]::Max(5, [math]::Max(0.1 * $center, ($deviations | Measure-Object -Maximum).Maximum))
        $lower = [math]::Max(0, $center - $margin)
        $upper = $center + $margin
        $increase = $incident.MeanMs - $baseline.MeanMs
        $report.Add('')
        $report.Add("- Baseline center $(Format-Number $center) ms, tolerance $(Format-Number $margin) ms, recovery band [$(Format-Number $lower), $(Format-Number $upper)] ms.")
        $report.Add("- Incident mean increased by $(Format-Number $increase) ms.")
        if ($margin -gt 0.25 * $phases.incident) {
            $issues.Add('Baseline variation exceeded 25% of the injected delay. The comparison is inconclusive.')
        } else {
            if (@($incident.BlocksMs | Where-Object { $_ -le $upper }).Count -gt 0 -or $increase -lt 0.5 * $phases.incident) {
                $issues.Add('The simulated incident did not meet the aggregate latency criteria.')
            }
            if (@($recovery.BlocksMs | Where-Object { $_ -lt $lower -or $_ -gt $upper }).Count -gt 0) {
                $issues.Add('One or more recovery blocks fell outside the baseline band.')
            }
        }
    } catch { $issues.Add($_.Exception.Message) }
}
$report.Add('')
if ($issues.Count -eq 0) {
    $report.Add('**Recovery verified for this run.**')
} else {
    $report.Add('**Recovery unconfirmed.**')
    $report.Add('')
    foreach ($issue in $issues) { $report.Add("- $issue") }
}
$report | Set-Content -LiteralPath (Join-Path $root 'comparison.md')
$report
if ($issues.Count -gt 0) { exit 1 }
