[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ManifestPath,
    [string] $StatusPath
)

$ErrorActionPreference = 'Stop'

function Full-Path([string] $Path) { return [IO.Path]::GetFullPath($Path) }

function Assert-Within([string] $Path, [string] $Root, [string] $Label) {
    $resolvedPath = Full-Path $Path
    $resolvedRoot = (Full-Path $Root).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside its permitted root: $resolvedPath"
    }
    return $resolvedPath
}

function Move-Atomic([string] $Source, [string] $Destination) {
    if (Test-Path -LiteralPath $Destination) { throw "Destination collision: $Destination" }
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.PSIsContainer) { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Test-MarkedPlaceholder([string] $Directory, [string] $MarkerName, [string] $Token) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    $items = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($items.Count -ne 1 -or $items[0].Name -ne $MarkerName -or $items[0].PSIsContainer) { return $false }
    return (Get-Content -LiteralPath $items[0].FullName -Raw) -eq $Token
}

function Target-Array($Value) {
    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string]$_ })
}

if (Get-Process -Name 'X-Plane' -ErrorAction SilentlyContinue) {
    throw 'Stop X-Plane before restoring the clean profile.'
}

$Manifest = Full-Path $ManifestPath
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest is missing: $Manifest" }
$manifestData = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ([int]$manifestData.schema_version -ne 4) { throw 'This recovery script requires clean-profile manifest schema_version 4.' }

$isolationRoot = Split-Path -Parent $Manifest
$xplaneRoot = Full-Path ([string]$manifestData.xplane_root)
$pluginRoot = Assert-Within ([string]$manifestData.plugin_root) $xplaneRoot 'Plugin root'
$liveScenery = Assert-Within ([string]$manifestData.scenery.original_path) $xplaneRoot 'Live scenery root'
$stagedScenery = Assert-Within ([string]$manifestData.scenery.quarantined_path) $isolationRoot 'Staged scenery root'
$placeholderPark = Assert-Within ([string]$manifestData.scenery.test_placeholder_park_path) $isolationRoot 'Placeholder park'
$markerName = [string]$manifestData.scenery.placeholder_marker_name
$markerToken = [string]$manifestData.scenery.placeholder_token
if ([string]::IsNullOrWhiteSpace($markerName) -or [IO.Path]::GetFileName($markerName) -ne $markerName) {
    throw 'Manifest placeholder_marker_name must be one file name.'
}
if ([string]::IsNullOrWhiteSpace($markerToken)) { throw 'Manifest placeholder_token is empty.' }

if (-not $StatusPath) { $StatusPath = Join-Path $isolationRoot 'restoration-status.json' }
$Status = Assert-Within $StatusPath $isolationRoot 'Restoration status'

foreach ($entry in @($manifestData.plugin_entries)) {
    $source = Assert-Within ([string]$entry.quarantined_path) $isolationRoot 'Plugin quarantine path'
    $destination = Assert-Within ([string]$entry.original_path) $pluginRoot 'Plugin destination'
    $sourceExists = Test-Path -LiteralPath $source
    $destinationExists = Test-Path -LiteralPath $destination
    if ($sourceExists -and $destinationExists) { throw "Plugin collision: $source and $destination" }
    if ($sourceExists) { Move-Atomic $source $destination }
    elseif (-not $destinationExists) { throw "Plugin is missing from both locations: $($entry.name)" }
}

$stagedExists = Test-Path -LiteralPath $stagedScenery -PathType Container
$liveExists = Test-Path -LiteralPath $liveScenery -PathType Container
if ($stagedExists -and $liveExists) {
    if (-not (Test-MarkedPlaceholder $liveScenery $markerName $markerToken)) {
        throw 'Both staged and live scenery exist, and live scenery is not the exact marked placeholder. Preserve both; do not merge recursively.'
    }
    if (Test-Path -LiteralPath $placeholderPark) { throw "Placeholder park collision: $placeholderPark" }
    Move-Atomic $liveScenery $placeholderPark
    try {
        Move-Atomic $stagedScenery $liveScenery
    } catch {
        if (-not (Test-Path -LiteralPath $liveScenery) -and (Test-Path -LiteralPath $placeholderPark)) {
            Move-Atomic $placeholderPark $liveScenery
        }
        throw
    }
} elseif ($stagedExists -and -not $liveExists) {
    Move-Atomic $stagedScenery $liveScenery
} elseif (-not $stagedExists -and -not $liveExists) {
    throw 'Original scenery is missing from both live and staged locations.'
}

$expectedPluginNames = @(@($manifestData.stock_allowlist) + @($manifestData.plugin_entries | ForEach-Object { [string]$_.name }) | Sort-Object)
$livePluginNames = @(Get-ChildItem -LiteralPath $pluginRoot -Force | Select-Object -ExpandProperty Name | Sort-Object)
$missingPlugins = @($expectedPluginNames | Where-Object { $livePluginNames -notcontains $_ })
$extraPlugins = @($livePluginNames | Where-Object { $expectedPluginNames -notcontains $_ })

$expectedSceneryNames = @($manifestData.scenery.top_level_entries | ForEach-Object { [string]$_.name } | Sort-Object)
$liveSceneryNames = @(Get-ChildItem -LiteralPath $liveScenery -Force | Select-Object -ExpandProperty Name | Sort-Object)
$missingScenery = @($expectedSceneryNames | Where-Object { $liveSceneryNames -notcontains $_ })
$extraScenery = @($liveSceneryNames | Where-Object { $expectedSceneryNames -notcontains $_ })

$reparseResults = @($manifestData.scenery.reparse_points | ForEach-Object {
    $path = Assert-Within (Join-Path $liveScenery ([string]$_.relative_path)) $liveScenery 'Restored reparse point'
    $item = try { Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $null }
    $exists = $null -ne $item
    $actualTargets = if ($item) { Target-Array $item.Target } else { @() }
    $expectedTargets = Target-Array $_.target
    [ordered]@{
        relative_path = [string]$_.relative_path
        exists = $exists
        expected_link_type = [string]$_.link_type
        actual_link_type = if ($item) { [string]$item.LinkType } else { $null }
        expected_target = $expectedTargets
        actual_target = $actualTargets
        match = ($exists -and $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            [string]$item.LinkType -eq [string]$_.link_type -and
            ($expectedTargets -join "`n") -eq ($actualTargets -join "`n"))
    }
})
$reparseMismatches = @($reparseResults | Where-Object { -not $_.match })

$hashResults = @($manifestData.critical_hashes | ForEach-Object {
    $path = Full-Path ([string]$_.path)
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $actual = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
    [ordered]@{ path = $path; expected_sha256 = [string]$_.sha256; actual_sha256 = $actual; match = ($exists -and $actual -eq [string]$_.sha256) }
})
$hashMismatches = @($hashResults | Where-Object { -not $_.match })

$quarantineRoots = @($manifestData.plugin_entries | ForEach-Object { Split-Path -Parent ([string]$_.quarantined_path) } | Sort-Object -Unique)
$quarantineCount = 0
foreach ($root in $quarantineRoots) {
    if (Test-Path -LiteralPath $root) { $quarantineCount += @(Get-ChildItem -LiteralPath $root -Force).Count }
}

$verified = $missingPlugins.Count -eq 0 -and $extraPlugins.Count -eq 0 -and
    $missingScenery.Count -eq 0 -and $extraScenery.Count -eq 0 -and
    $reparseMismatches.Count -eq 0 -and $hashMismatches.Count -eq 0 -and
    $quarantineCount -eq 0 -and -not (Test-Path -LiteralPath $stagedScenery)

$statusData = [ordered]@{
    restored_utc = [datetime]::UtcNow.ToString('o')
    verified = $verified
    plugin_count = $livePluginNames.Count
    expected_plugin_count = $expectedPluginNames.Count
    missing_plugins = $missingPlugins
    extra_plugins = $extraPlugins
    plugin_quarantine_count = $quarantineCount
    scenery_count = $liveSceneryNames.Count
    expected_scenery_count = $expectedSceneryNames.Count
    missing_scenery = $missingScenery
    extra_scenery = $extraScenery
    staged_scenery_exists = Test-Path -LiteralPath $stagedScenery
    reparse_points = $reparseResults
    critical_hashes = $hashResults
}

if ($verified -and (Test-Path -LiteralPath $placeholderPark)) {
    if (-not (Test-MarkedPlaceholder $placeholderPark $markerName $markerToken)) {
        throw 'Placeholder park is not the exact marked placeholder; refusing deletion.'
    }
    Remove-Item -LiteralPath $placeholderPark -Recurse -Force
}
$statusData['placeholder_park_exists'] = Test-Path -LiteralPath $placeholderPark
$statusData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Status -Encoding utf8NoBOM

if (-not $verified) { throw "Restoration audit failed. See $Status" }
$statusData | ConvertTo-Json -Depth 10
