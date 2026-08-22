[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Capture', 'Verify')] [string] $Mode,
    [Parameter(Mandatory)] [string] $XPlaneRoot,
    [Parameter(Mandatory)] [string] $SnapshotPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Full-Path([string] $Path) { return [IO.Path]::GetFullPath($Path) }

function Assert-Within([string] $Path, [string] $Root, [string] $Label) {
    $resolvedPath = Full-Path $Path
    $resolvedRoot = (Full-Path $Root).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside the X-Plane root: $resolvedPath"
    }
    return $resolvedPath
}

function Target-Array($Value) {
    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string]$_ })
}

function Normalize-Target([string] $Target, [string] $LinkParent) {
    if ([IO.Path]::IsPathRooted($Target)) { return (Full-Path $Target).TrimEnd('\') }
    return (Full-Path (Join-Path $LinkParent $Target)).TrimEnd('\')
}

function Get-EntryState([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $targets = @(Target-Array $item.Target)
    return [ordered]@{
        path = Full-Path $Path
        entry_type = if ($item.PSIsContainer) { 'directory' } else { 'file' }
        attributes = [string]$item.Attributes
        is_reparse_point = $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
        link_type = [string]$item.LinkType
        targets = $targets
    }
}

function Get-TopLevelState([string] $Directory) {
    return @(Get-ChildItem -LiteralPath $Directory -Force | Sort-Object Name | ForEach-Object {
        [ordered]@{
            name = $_.Name
            entry_type = if ($_.PSIsContainer) { 'directory' } else { 'file' }
            is_reparse_point = $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
            link_type = [string]$_.LinkType
            targets = @(Target-Array $_.Target)
        }
    })
}

function Assert-HealthyStockScenery([string] $DefaultScenery) {
    if (-not (Test-Path -LiteralPath $DefaultScenery -PathType Container)) {
        throw "X-Plane stock default scenery is missing: $DefaultScenery"
    }
    if (@(Get-ChildItem -LiteralPath $DefaultScenery -Force).Count -eq 0) {
        throw "X-Plane stock default scenery is empty. Stop testing and repair the installation separately: $DefaultScenery"
    }
    $simLibrary = Join-Path $DefaultScenery 'sim objects\library.txt'
    if (-not (Test-Path -LiteralPath $simLibrary -PathType Leaf)) {
        throw "X-Plane stock sim-object library is missing: $simLibrary"
    }

    $carrierVirtualPath = 'lib/ships/Ford_Carrier_accessory/AIM-120_Cart_Empty.obj'
    $carrierLine = Select-String -LiteralPath $simLibrary -SimpleMatch $carrierVirtualPath | Select-Object -First 1
    if ($carrierLine) {
        $pattern = '^\s*EXPORT(?:_EXCLUDE)?\s+\S+\s+(.+?)\s*$'
        $match = [regex]::Match([string]$carrierLine.Line, $pattern)
        if (-not $match.Success) { throw "Could not parse required carrier export in: $simLibrary" }
        $carrierObject = Join-Path (Split-Path -Parent $simLibrary) $match.Groups[1].Value
        if (-not (Test-Path -LiteralPath $carrierObject -PathType Leaf)) {
            throw "Stock library export is unresolved: $carrierVirtualPath -> $carrierObject"
        }
    }
}

function Get-InstallState([string] $Root) {
    $defaultScenery = Assert-Within (Join-Path $Root 'Resources\default scenery') $Root 'Default scenery'
    $globalScenery = Assert-Within (Join-Path $Root 'Global Scenery') $Root 'Global scenery'
    $customScenery = Assert-Within (Join-Path $Root 'Custom Scenery') $Root 'Custom scenery'
    $xplaneExe = Assert-Within (Join-Path $Root 'X-Plane.exe') $Root 'X-Plane executable'

    Assert-HealthyStockScenery $defaultScenery
    foreach ($required in @($globalScenery, $customScenery, $xplaneExe)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Protected installation path is missing: $required" }
    }

    $criticalFiles = @(
        Join-Path $defaultScenery 'sim objects\library.txt'
        Join-Path $defaultScenery 'sim objects\dynamic\ford_carrier_accessories\AIM-120_Cart_Empty.obj'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

    $simHeavenRoot = Join-Path $customScenery 'simHeaven_X-WORLD-Pro_Library'
    $simHeavenState = [ordered]@{ present = $false }
    if (Test-Path -LiteralPath $simHeavenRoot -PathType Container) {
        $simHeavenLink = Join-Path $simHeavenRoot 'XP12_libs'
        if (-not (Test-Path -LiteralPath $simHeavenLink -PathType Container)) {
            throw "simHeaven XP12_libs is missing: $simHeavenLink"
        }
        $linkItem = Get-Item -LiteralPath $simHeavenLink -Force
        if (-not $linkItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw "simHeaven XP12_libs must be a junction/symlink, not a materialized directory: $simHeavenLink"
        }
        $targets = @(Target-Array $linkItem.Target)
        if ($targets.Count -ne 1) { throw "simHeaven XP12_libs has an unexpected target count: $simHeavenLink" }
        $actualTarget = Normalize-Target $targets[0] (Split-Path -Parent $simHeavenLink)
        $expectedTarget = (Full-Path $defaultScenery).TrimEnd('\')
        if ($actualTarget -ne $expectedTarget) {
            throw "simHeaven XP12_libs targets '$actualTarget', expected '$expectedTarget'."
        }
        $simHeavenState = [ordered]@{
            present = $true
            xp12_libs = Get-EntryState $simHeavenLink
            normalized_target = $actualTarget
        }
    }

    return [ordered]@{
        xplane_executable = [ordered]@{
            state = Get-EntryState $xplaneExe
            sha256 = (Get-FileHash -LiteralPath $xplaneExe -Algorithm SHA256).Hash
        }
        default_scenery = [ordered]@{
            state = Get-EntryState $defaultScenery
            top_level_entries = Get-TopLevelState $defaultScenery
            critical_hashes = @($criticalFiles | ForEach-Object {
                [ordered]@{
                    relative_path = [IO.Path]::GetRelativePath($defaultScenery, $_)
                    size_bytes = (Get-Item -LiteralPath $_).Length
                    sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
                }
            })
        }
        global_scenery = [ordered]@{
            state = Get-EntryState $globalScenery
            top_level_entries = Get-TopLevelState $globalScenery
        }
        simheaven = $simHeavenState
    }
}

if (Get-Process -Name 'X-Plane' -ErrorAction SilentlyContinue) {
    throw 'Stop X-Plane before capturing or verifying protected installation state.'
}

$root = Full-Path $XPlaneRoot
$snapshot = Assert-Within $SnapshotPath $root 'Protected-state snapshot'

if ($Mode -eq 'Capture') {
    if (Test-Path -LiteralPath $snapshot) { throw "Snapshot already exists: $snapshot" }
    $state = Get-InstallState $root
    $snapshotParent = Split-Path -Parent $snapshot
    if (-not (Test-Path -LiteralPath $snapshotParent -PathType Container)) {
        New-Item -ItemType Directory -Path $snapshotParent -Force | Out-Null
    }
    $document = [ordered]@{
        schema_version = 1
        captured_utc = [DateTime]::UtcNow.ToString('o')
        xplane_root = $root
        state = $state
    }
    $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $snapshot -Encoding utf8NoBOM
    $document | ConvertTo-Json -Depth 20
    return
}

if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { throw "Snapshot is missing: $snapshot" }
$expected = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
if ([int]$expected.schema_version -ne 1) { throw 'Unsupported protected-state snapshot schema.' }
if ((Full-Path ([string]$expected.xplane_root)).TrimEnd('\') -ne $root.TrimEnd('\')) {
    throw 'Protected-state snapshot belongs to a different X-Plane root.'
}

$actualState = Get-InstallState $root
$expectedJson = $expected.state | ConvertTo-Json -Depth 20 -Compress
$actualJson = $actualState | ConvertTo-Json -Depth 20 -Compress
$verified = $expectedJson -ceq $actualJson
$result = [ordered]@{
    verified_utc = [DateTime]::UtcNow.ToString('o')
    verified = $verified
    snapshot_path = $snapshot
}
if (-not $verified) {
    throw "Protected X-Plane installation state changed. Preserve the test quarantine and compare against: $snapshot"
}
$result | ConvertTo-Json -Depth 5
