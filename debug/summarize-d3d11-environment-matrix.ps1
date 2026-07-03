param(
    [string]$InputRoot = "",
    [string]$OutDir = "",
    [switch]$FailOnMissing
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
if ($InputRoot.Length -eq 0) {
    $InputRoot = Join-Path $repoRoot "zig-out\d3d11-env-smoke"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $InputRoot "matrix-ledger-$timestamp"
}

$matrixClasses = @(
    "local-physical",
    "rdp",
    "virtual-machine",
    "hybrid-gpu",
    "weak-integrated-gpu",
    "single-monitor",
    "multi-monitor-same-dpi",
    "multi-monitor-mixed-dpi"
)

function Get-JsonField([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Format-LedgerValue([object]$Value) {
    if ($null -eq $Value) {
        return "unknown"
    }
    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }
        return "false"
    }
    $text = [string]$Value
    return $text.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Short-Commit([object]$Commit) {
    if ($null -eq $Commit) {
        return "unknown"
    }
    $text = [string]$Commit
    if ($text.Length -gt 8) {
        return $text.Substring(0, 8)
    }
    return $text
}

function EvidenceStatus([object]$Entry) {
    if ($Entry.pass -ne $true) {
        return "failing"
    }
    if ($Entry.class_match -eq $true) {
        return "recorded"
    }
    if ($Entry.class_match -eq $false) {
        return "mismatch"
    }
    if ($Entry.class -eq "hybrid-gpu") {
        return "operator-review"
    }
    return "recorded-unclassified"
}

function StatusRank([string]$Status) {
    switch ($Status) {
        "recorded" { return 0 }
        "operator-review" { return 1 }
        "recorded-unclassified" { return 2 }
        "mismatch" { return 3 }
        "failing" { return 4 }
    }
    return 5
}

function Add-MarkdownRow([object]$Lines, [object[]]$Values) {
    $cells = @()
    foreach ($value in $Values) {
        $cells += (Format-LedgerValue $value)
    }
    $Lines.Add("| $($cells -join ' | ') |") | Out-Null
}

if (!(Test-Path -LiteralPath $InputRoot)) {
    throw "input root not found: $InputRoot"
}

$jsonFiles = Get-ChildItem -LiteralPath $InputRoot -Recurse -Filter "environment.json" -File
$entries = @()

foreach ($file in $jsonFiles) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $json = $raw | ConvertFrom-Json
    $matrix = Get-JsonField $json "matrix"
    if ($null -eq $matrix) {
        continue
    }

    $environment = Get-JsonField $json "environment"
    $d3d11 = Get-JsonField $environment "d3d11"
    $windows = Get-JsonField $environment "windows"
    $detection = Get-JsonField $matrix "detection"
    $policy = Get-JsonField $json "policy"
    $repo = Get-JsonField $json "repo"
    $artifacts = Get-JsonField $json "artifacts"

    $class = [string](Get-JsonField $matrix "requested_class")
    if ($class.Length -eq 0) {
        $class = "unspecified"
    }

    $entry = [ordered]@{
        class = $class
        status = $null
        pass = [bool](Get-JsonField $json "pass")
        class_match = Get-JsonField $matrix "class_match"
        require_class_match = [bool](Get-JsonField $matrix "require_class_match")
        generated_at = Get-JsonField $json "generated_at"
        branch = Get-JsonField $repo "branch"
        commit = Get-JsonField $repo "commit"
        root = Get-JsonField $artifacts "root"
        environment_json = $file.FullName
        matrix_summary = Get-JsonField $artifacts "matrix_summary"
        normal_session_json = Get-JsonField $artifacts "normal_session_json"
        diagnostic_log = Get-JsonField $artifacts "diagnostic_log"
        adapter_description = Get-JsonField $d3d11 "adapter_description"
        feature_level = Get-JsonField $d3d11 "feature_level"
        dedicated_video_memory = Get-JsonField $d3d11 "dedicated_video_memory"
        output_count = Get-JsonField $d3d11 "output_count"
        remote_session = Get-JsonField $detection "remote_session"
        monitor_count = Get-JsonField $detection "monitor_count"
        mixed_dpi = Get-JsonField $detection "mixed_dpi"
        virtual_machine_candidate = Get-JsonField $detection "virtual_machine_candidate"
        integrated_gpu_candidate = Get-JsonField $detection "integrated_gpu_candidate"
        weak_integrated_gpu_candidate = Get-JsonField $detection "weak_integrated_gpu_candidate"
        environment_blocking = Get-JsonField $policy "environment_blocking"
        automatic_fallback = Get-JsonField $policy "automatic_fallback"
        default_unchanged = Get-JsonField $policy "default_unchanged"
    }
    $entry.status = EvidenceStatus $entry
    $entries += [pscustomobject]$entry
}

$classRows = @()
foreach ($class in $matrixClasses) {
    $candidates = @($entries | Where-Object { $_.class -eq $class } | Sort-Object @{ Expression = { StatusRank $_.status }; Ascending = $true }, @{ Expression = { $_.generated_at }; Descending = $true })
    $best = if ($candidates.Count -gt 0) { $candidates[0] } else { $null }
    $status = if ($null -eq $best) { "missing" } else { $best.status }
    $classRows += [pscustomobject][ordered]@{
        class = $class
        status = $status
        evidence_count = $candidates.Count
        selected_environment_json = if ($null -eq $best) { $null } else { $best.environment_json }
        selected_matrix_summary = if ($null -eq $best) { $null } else { $best.matrix_summary }
        selected_commit = if ($null -eq $best) { $null } else { $best.commit }
        selected_generated_at = if ($null -eq $best) { $null } else { $best.generated_at }
        selected_class_match = if ($null -eq $best) { $null } else { $best.class_match }
        selected_pass = if ($null -eq $best) { $null } else { $best.pass }
        selected_adapter = if ($null -eq $best) { $null } else { $best.adapter_description }
        selected_monitor_count = if ($null -eq $best) { $null } else { $best.monitor_count }
        selected_mixed_dpi = if ($null -eq $best) { $null } else { $best.mixed_dpi }
    }
}

$missing = @($classRows | Where-Object { $_.status -eq "missing" })
$generatedAt = (Get-Date).ToString("o")
$ledger = [ordered]@{
    schema = "wispterm-d3d11-environment-matrix-ledger/v1"
    generated_at = $generatedAt
    input_root = $InputRoot
    evidence_count = $entries.Count
    missing_count = $missing.Count
    policy = [ordered]@{
        record_only = $true
        environment_blocking = $false
        automatic_fallback = $false
        default_unchanged = $true
    }
    classes = @($classRows)
    evidence = @($entries)
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ledgerJsonPath = Join-Path $OutDir "matrix-ledger.json"
$ledgerMdPath = Join-Path $OutDir "matrix-ledger.md"
$ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerJsonPath -Encoding UTF8

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# WispTerm D3D11 Environment Matrix Ledger") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Generated at: $generatedAt") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Input root: $InputRoot") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("This ledger aggregates record-only Phase V evidence packages. It does not imply environment blocking, fallback-marker writes, or a Windows default renderer change.") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Matrix Status") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Class | Status | Evidence | Commit | Generated | Class match | Pass | Adapter | Monitors | Mixed DPI | Summary |") | Out-Null
$lines.Add("|---|---|---:|---|---|---|---|---|---:|---|---|") | Out-Null
foreach ($row in $classRows) {
    Add-MarkdownRow $lines @(
        $row.class,
        $row.status,
        $row.evidence_count,
        (Short-Commit $row.selected_commit),
        $row.selected_generated_at,
        $row.selected_class_match,
        $row.selected_pass,
        $row.selected_adapter,
        $row.selected_monitor_count,
        $row.selected_mixed_dpi,
        $row.selected_matrix_summary
    )
}

$lines.Add("") | Out-Null
$lines.Add("## All Evidence Packages") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Class | Status | Pass | Class match | Generated | Commit | Adapter | Monitors | Mixed DPI | Environment JSON |") | Out-Null
$lines.Add("|---|---|---|---|---|---|---|---:|---|---|") | Out-Null
foreach ($entry in ($entries | Sort-Object generated_at)) {
    Add-MarkdownRow $lines @(
        $entry.class,
        $entry.status,
        $entry.pass,
        $entry.class_match,
        $entry.generated_at,
        (Short-Commit $entry.commit),
        $entry.adapter_description,
        $entry.monitor_count,
        $entry.mixed_dpi,
        $entry.environment_json
    )
}

if ($missing.Count -gt 0) {
    $lines.Add("") | Out-Null
    $lines.Add("## Missing Classes") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($row in $missing) {
        $lines.Add("- $($row.class)") | Out-Null
    }
}

$lines | Set-Content -LiteralPath $ledgerMdPath -Encoding UTF8

$summary = [ordered]@{
    evidence_count = $entries.Count
    missing_count = $missing.Count
    ledger_json = $ledgerJsonPath
    ledger_markdown = $ledgerMdPath
}
$summary | ConvertTo-Json -Depth 4

if ($FailOnMissing -and $missing.Count -gt 0) {
    throw "missing matrix evidence classes: $((@($missing | ForEach-Object { $_.class })) -join ', ')"
}
