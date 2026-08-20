param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    [int]$Port = 8088,
    [string]$OutputPath,
    [switch]$ValidateConfigOnly
)

$ErrorActionPreference = 'Stop'
$startedUtc = [datetime]::UtcNow
$script:CurrentStage = 'configuration'
$script:FailureWritten = $false

function Write-JsonFile($Value, [string]$Path) {
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $jsonText = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($resolvedPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
    return $jsonText
}

trap {
    $errorMessage = $_.Exception.Message
    if ($OutputPath -and -not $script:FailureWritten) {
        $failure = [ordered]@{
            name = if ($null -ne $config -and $config.name) { $config.name } else { $null }
            accepted = $false
            failure_stage = $script:CurrentStage
            error = $errorMessage
            started_utc = $startedUtc.ToString('o')
            failed_utc = [datetime]::UtcNow.ToString('o')
            samples = @()
        }
        try {
            Write-JsonFile $failure $OutputPath | Out-Null
            $script:FailureWritten = $true
        } catch {}
    }
    Write-Error "Flight trial failed during $($script:CurrentStage): $errorMessage"
    exit 1
}

function Require-Property($Object, [string]$Name) {
    if ($null -eq $Object -or $null -eq $Object.$Name) { throw "Configuration is missing '$Name'." }
}

function Has-Property($Object, [string]$Name) {
    return $null -ne $Object -and @($Object.PSObject.Properties.Name) -contains $Name
}

$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -Raw -LiteralPath $resolvedConfig | ConvertFrom-Json
Require-Property $config 'name'
Require-Property $config 'sampleDatarefs'
if (@($config.sampleDatarefs).Count -lt 1) { throw 'sampleDatarefs must not be empty.' }

$defaults = [ordered]@{
    immediatePauseTimeoutSeconds = 20
    pluginInitSeconds = 8
    discoveryTimeoutSeconds = 30
    commandDurationSeconds = 0.2
    stabilizeSeconds = 60
    sampleCount = 15
    sampleIntervalMs = 750
}
foreach ($key in $defaults.Keys) {
    if ($null -eq $config.$key) {
        $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
    }
}

if ([double]$config.immediatePauseTimeoutSeconds -le 0) { throw 'immediatePauseTimeoutSeconds must be positive.' }
if ([double]$config.pluginInitSeconds -lt 0) { throw 'pluginInitSeconds must not be negative.' }
if ([double]$config.discoveryTimeoutSeconds -le 0) { throw 'discoveryTimeoutSeconds must be positive.' }
if ([double]$config.commandDurationSeconds -le 0) { throw 'commandDurationSeconds must be positive; zero-duration activations are not permitted.' }
if ([double]$config.stabilizeSeconds -lt 0) { throw 'stabilizeSeconds must not be negative.' }
if ([int]$config.sampleCount -lt 1) { throw 'sampleCount must be at least 1.' }
if ([int]$config.sampleIntervalMs -lt 1) { throw 'sampleIntervalMs must be at least 1.' }

foreach ($blockName in @('pausedReadiness', 'postCommandState', 'convergence')) {
    $block = $config.$blockName
    if ($null -ne $block -and @($block.conditions).Count -lt 1) {
        throw "$blockName must contain at least one condition."
    }
}

$sampleSet = @{}
foreach ($name in @($config.sampleDatarefs)) {
    if (-not $name) { throw 'sampleDatarefs contains an empty name.' }
    if ($sampleSet.ContainsKey([string]$name)) { throw "sampleDatarefs contains duplicate name '$name'." }
    $sampleSet[[string]$name] = $true
}

function Require-SampledRule([string]$Name, [string]$RuleType) {
    if (-not $sampleSet.ContainsKey($Name)) {
        throw "$RuleType references '$Name', but that dataref is not in sampleDatarefs."
    }
}

if ($null -ne $config.reject) {
    if ($config.reject.servoDataref) { Require-SampledRule ([string]$config.reject.servoDataref) 'servoDataref' }
    if ($config.reject.bankDataref) { Require-SampledRule ([string]$config.reject.bankDataref) 'bankDataref' }
    foreach ($ruleType in @('maxRanges', 'requiredValues', 'meanTargets', 'minimums', 'maximums')) {
        foreach ($rule in @($config.reject.$ruleType)) {
            if ($null -eq $rule) { continue }
            Require-Property $rule 'name'
            Require-SampledRule ([string]$rule.name) $ruleType
        }
    }
}

if ($ValidateConfigOnly) {
    [pscustomobject]@{
        valid = $true
        name = $config.name
        immediate_pause_timeout_seconds = [double]$config.immediatePauseTimeoutSeconds
        command_duration_seconds = [double]$config.commandDurationSeconds
        reset_datarefs = @($config.resetDatarefs).Count
        setup_datarefs = @($config.setupDatarefs).Count
        setup_commands = @($config.pausedCommands).Count + @($config.afterSetupCommands).Count
        sample_datarefs = @($config.sampleDatarefs).Count
        sample_count = [int]$config.sampleCount
        interval_ms = [int]$config.sampleIntervalMs
        convergence_configured = ($null -ne $config.convergence)
        mass_correction_configured = ($null -ne $config.massCorrection)
    } | ConvertTo-Json -Depth 5
    exit 0
}

$env:NO_PROXY = 'localhost,127.0.0.1'
$env:no_proxy = $env:NO_PROXY
$baseUri = "http://127.0.0.1:$Port/api/v3"

function Get-ApiItems([string]$Resource, [int]$Limit) {
    $response = Invoke-RestMethod -Uri "$baseUri/$Resource`?limit=$Limit" -TimeoutSec 30
    if ($null -eq $response.data) { throw "The $Resource catalog returned no data." }
    return @($response.data)
}

function New-NameMap($Items) {
    $map = @{}
    foreach ($item in @($Items)) { $map[[string]$item.name] = $item }
    return $map
}

function Get-DrefValueById($Id) {
    $value = (Invoke-RestMethod -Uri "$baseUri/datarefs/$Id/value" -TimeoutSec 10).data
    if ($value -is [array]) { return $value[0] }
    return $value
}

function Invoke-CommandById($Id, [double]$DurationSeconds) {
    if ($DurationSeconds -le 0) { throw 'Command duration must be positive.' }
    $body = @{ duration = $DurationSeconds } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$baseUri/command/$Id/activate" -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
}

function Set-PauseState($CommandMapArg, $DatarefMapArg, [bool]$Paused, [double]$TimeoutSeconds) {
    $commandName = if ($Paused) { 'sim/operation/pause_on' } else { 'sim/operation/pause_off' }
    $commandItem = $CommandMapArg[$commandName]
    $pausedItem = $DatarefMapArg['sim/time/paused']
    if (-not $commandItem -or -not $pausedItem) { throw "Could not map $commandName and sim/time/paused." }

    $expected = if ($Paused) { 1 } else { 0 }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            Invoke-CommandById $commandItem.id ([double]$config.commandDurationSeconds)
            Start-Sleep -Milliseconds 100
            $actual = [int](Get-DrefValueById $pausedItem.id)
            if ($actual -eq $expected) { return }
        } catch {}
        Start-Sleep -Milliseconds 250
    } while ([datetime]::UtcNow -lt $deadline)

    throw "Simulator did not reach pause state $expected within $TimeoutSeconds seconds."
}

$script:CurrentStage = 'preload_catalog'
$preDatarefMap = New-NameMap (Get-ApiItems 'datarefs' 30000)
$preCommandMap = New-NameMap (Get-ApiItems 'commands' 20000)
if (-not $preDatarefMap.ContainsKey('sim/time/paused') -or -not $preCommandMap.ContainsKey('sim/operation/pause_on')) {
    throw 'Generic pause controls were unavailable before flight load.'
}

if ($null -ne $config.flightRequest) {
    $script:CurrentStage = 'flight_load'
    $flightBody = $config.flightRequest | ConvertTo-Json -Depth 20
    try {
        Invoke-RestMethod -Method Post -Uri "$baseUri/flight" -ContentType 'application/json' -Body $flightBody -TimeoutSec 180 | Out-Null
    } catch {
        if ($_.Exception.ToString() -notmatch '(?i)response ended prematurely') { throw }
    }
}

$script:CurrentStage = 'immediate_pause'
Set-PauseState $preCommandMap $preDatarefMap $true ([double]$config.immediatePauseTimeoutSeconds)
Start-Sleep -Milliseconds ([int]([double]$config.pluginInitSeconds * 1000))

$requiredDatarefs = @{}
$requiredCommands = @{}
function Add-RequiredDataref([string]$Name) { if ($Name) { $requiredDatarefs[$Name] = $true } }
function Add-RequiredCommand([string]$Name) { if ($Name) { $requiredCommands[$Name] = $true } }
function Add-ConditionDatarefs($Block) {
    if ($null -ne $Block) {
        foreach ($condition in @($Block.conditions)) { if ($null -ne $condition) { Add-RequiredDataref ([string]$condition.name) } }
    }
}
function Add-CommandSpecs($Specs) {
    foreach ($spec in @($Specs)) {
        if ($null -eq $spec) { continue }
        if ($spec -is [string]) { Add-RequiredCommand ([string]$spec) }
        elseif ($null -ne $spec) { Add-RequiredCommand ([string]$spec.name) }
    }
}

Add-RequiredDataref 'sim/time/paused'
foreach ($name in @($config.sampleDatarefs)) { Add-RequiredDataref ([string]$name) }
foreach ($setting in @($config.resetDatarefs) + @($config.setupDatarefs) + @($config.afterCommandDatarefs)) {
    if ($null -ne $setting) { Add-RequiredDataref ([string]$setting.name) }
}
Add-ConditionDatarefs $config.pausedReadiness
Add-ConditionDatarefs $config.postCommandState
Add-ConditionDatarefs $config.convergence
if ($null -ne $config.massCorrection) {
    Add-RequiredDataref ([string]$config.massCorrection.totalMassDataref)
    Add-RequiredDataref ([string]$config.massCorrection.adjustDataref)
}
Add-RequiredCommand 'sim/operation/pause_on'
Add-RequiredCommand 'sim/operation/pause_off'
Add-CommandSpecs $config.pausedCommands
Add-CommandSpecs $config.afterSetupCommands

$script:CurrentStage = 'postload_discovery'
$catalogDeadline = [datetime]::UtcNow.AddSeconds([double]$config.discoveryTimeoutSeconds)
do {
    $datarefMap = New-NameMap (Get-ApiItems 'datarefs' 30000)
    $commandMap = New-NameMap (Get-ApiItems 'commands' 20000)
    $missingDatarefs = @($requiredDatarefs.Keys | Where-Object { -not $datarefMap.ContainsKey($_) } | Sort-Object)
    $missingCommands = @($requiredCommands.Keys | Where-Object { -not $commandMap.ContainsKey($_) } | Sort-Object)
    if ($missingDatarefs.Count -eq 0 -and $missingCommands.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
} while ([datetime]::UtcNow -lt $catalogDeadline)
if ($missingDatarefs.Count -gt 0 -or $missingCommands.Count -gt 0) {
    throw "Post-load discovery timed out. Missing datarefs: $($missingDatarefs -join ', '). Missing commands: $($missingCommands -join ', ')."
}

function Get-DrefValue([string]$Name) {
    $item = $datarefMap[$Name]
    if (-not $item) { throw "Missing dataref: $Name" }
    return Get-DrefValueById $item.id
}

function Set-DrefValue([string]$Name, $Value) {
    $item = $datarefMap[$Name]
    if (-not $item) { throw "Missing dataref: $Name" }
    $body = @{ data = $Value } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Patch -Uri "$baseUri/datarefs/$($item.id)/value" -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
}

function Invoke-SimCommandSpec($Spec) {
    if ($Spec -is [string]) {
        $name = [string]$Spec
        $duration = [double]$config.commandDurationSeconds
    } else {
        Require-Property $Spec 'name'
        $name = [string]$Spec.name
        $duration = if ($null -ne $Spec.durationSeconds) { [double]$Spec.durationSeconds } else { [double]$config.commandDurationSeconds }
    }
    if ($duration -le 0) { throw "Command '$name' has a non-positive duration." }
    $item = $commandMap[$name]
    if (-not $item) { throw "Missing command: $name" }
    Invoke-CommandById $item.id $duration
}

function Set-DrefSetting($Setting, [string]$Kind, [bool]$VerifyByDefault) {
    Require-Property $Setting 'name'
    Require-Property $Setting 'value'
    $name = [string]$Setting.name
    Set-DrefValue $name $Setting.value

    $shouldVerify = $VerifyByDefault -or (Has-Property $Setting 'readbackTolerance')
    if ($shouldVerify) {
        Start-Sleep -Milliseconds 100
        $tolerance = if (Has-Property $Setting 'readbackTolerance') { [double]$Setting.readbackTolerance } else { 0.01 }
        $actual = [double](Get-DrefValue $name)
        if ([math]::Abs($actual - [double]$Setting.value) -gt $tolerance) {
            throw "$Kind readback failed for '$name': requested $($Setting.value), actual $actual, tolerance $tolerance."
        }
    }
}

function Test-DrefConditions($Conditions) {
    $failures = [System.Collections.Generic.List[string]]::new()
    $values = [ordered]@{}
    foreach ($condition in @($Conditions)) {
        Require-Property $condition 'name'
        $name = [string]$condition.name
        $actual = [double](Get-DrefValue $name)
        $values[$name] = $actual
        $hasLimit = $false
        if (Has-Property $condition 'target') {
            $hasLimit = $true
            $tolerance = if (Has-Property $condition 'tolerance') { [double]$condition.tolerance } else { 0.0 }
            if ([math]::Abs($actual - [double]$condition.target) -gt $tolerance) {
                $failures.Add("$name=$actual outside target $($condition.target) +/- $tolerance")
            }
        }
        if (Has-Property $condition 'minimum') {
            $hasLimit = $true
            if ($actual -lt [double]$condition.minimum) { $failures.Add("$name=$actual below minimum $($condition.minimum)") }
        }
        if (Has-Property $condition 'maximum') {
            $hasLimit = $true
            if ($actual -gt [double]$condition.maximum) { $failures.Add("$name=$actual above maximum $($condition.maximum)") }
        }
        if (-not $hasLimit) { throw "Condition '$name' has no target, minimum, or maximum." }
    }
    return [pscustomobject]@{ passed = ($failures.Count -eq 0); values = $values; failures = @($failures) }
}

function Wait-DrefConditions($Block, [string]$Label) {
    $timeoutSeconds = if ($null -ne $Block.timeoutSeconds) { [double]$Block.timeoutSeconds } else { 30.0 }
    $intervalMs = if ($null -ne $Block.intervalMs) { [int]$Block.intervalMs } else { 500 }
    $requiredConsecutive = if ($null -ne $Block.consecutiveChecks) { [int]$Block.consecutiveChecks } else { 1 }
    if ($timeoutSeconds -le 0 -or $intervalMs -lt 1 -or $requiredConsecutive -lt 1) { throw "$Label has invalid timing parameters." }

    $started = [datetime]::UtcNow
    $deadline = $started.AddSeconds($timeoutSeconds)
    $consecutive = 0
    $checks = 0
    $lastEvaluation = $null
    do {
        $lastEvaluation = Test-DrefConditions $Block.conditions
        $checks++
        if ($lastEvaluation.passed) { $consecutive++ } else { $consecutive = 0 }
        if ($consecutive -ge $requiredConsecutive) {
            return [pscustomobject]@{
                configured = $true
                label = $Label
                checks = $checks
                consecutive_checks = $consecutive
                elapsed_seconds = ([datetime]::UtcNow - $started).TotalSeconds
                final_values = $lastEvaluation.values
            }
        }
        Start-Sleep -Milliseconds $intervalMs
    } while ([datetime]::UtcNow -lt $deadline)

    $lastFailure = if ($null -ne $lastEvaluation) { $lastEvaluation.failures -join '; ' } else { 'no observations' }
    throw "$Label did not converge within $timeoutSeconds seconds: $lastFailure"
}

$script:CurrentStage = 'paused_configuration'
if ([int](Get-DrefValue 'sim/time/paused') -ne 1) { throw 'Pause was lost before paused configuration began.' }
foreach ($setting in @($config.resetDatarefs)) { if ($null -ne $setting) { Set-DrefSetting $setting 'Reset' $true } }
foreach ($setting in @($config.setupDatarefs)) { if ($null -ne $setting) { Set-DrefSetting $setting 'Setup' $false } }
foreach ($command in @($config.pausedCommands)) { if ($null -ne $command) { Invoke-SimCommandSpec $command } }
$pausedReadinessResult = if ($null -ne $config.pausedReadiness) {
    Wait-DrefConditions $config.pausedReadiness 'Paused readiness'
} else { [pscustomobject]@{ configured = $false } }

$script:CurrentStage = 'unpause'
Set-PauseState $commandMap $datarefMap $false ([double]$config.immediatePauseTimeoutSeconds)

$script:CurrentStage = 'mode_engagement'
foreach ($command in @($config.afterSetupCommands)) { if ($null -ne $command) { Invoke-SimCommandSpec $command } }
foreach ($setting in @($config.afterCommandDatarefs)) { if ($null -ne $setting) { Set-DrefSetting $setting 'Post-command setup' $false } }
$postCommandStateResult = if ($null -ne $config.postCommandState) {
    Wait-DrefConditions $config.postCommandState 'Post-command state acquisition'
} else { [pscustomobject]@{ configured = $false } }

$script:CurrentStage = 'convergence'
$convergenceResult = if ($null -ne $config.convergence) {
    Wait-DrefConditions $config.convergence 'Pre-stabilization convergence'
} else { [pscustomobject]@{ configured = $false } }

$script:CurrentStage = 'mass_correction'
$massCorrectionResult = [ordered]@{ configured = $false }
if ($null -ne $config.massCorrection) {
    Require-Property $config.massCorrection 'totalMassDataref'
    Require-Property $config.massCorrection 'adjustDataref'
    Require-Property $config.massCorrection 'target'
    $totalName = [string]$config.massCorrection.totalMassDataref
    $adjustName = [string]$config.massCorrection.adjustDataref
    $targetMass = [double]$config.massCorrection.target
    $massTolerance = if ($null -ne $config.massCorrection.tolerance) { [double]$config.massCorrection.tolerance } else { 0.25 }
    $maxIterations = if ($null -ne $config.massCorrection.maxIterations) { [int]$config.massCorrection.maxIterations } else { 3 }
    $settleMs = if ($null -ne $config.massCorrection.settleMs) { [int]$config.massCorrection.settleMs } else { 500 }
    if ($massTolerance -lt 0 -or $maxIterations -lt 1 -or $settleMs -lt 0) { throw 'massCorrection has invalid tolerance or iteration settings.' }

    $iterations = 0
    for ($massAttempt = 0; $massAttempt -lt $maxIterations; $massAttempt++) {
        $actualMass = [double](Get-DrefValue $totalName)
        $massError = $targetMass - $actualMass
        if ([math]::Abs($massError) -le $massTolerance) { break }
        $adjustValue = [double](Get-DrefValue $adjustName)
        Set-DrefValue $adjustName ($adjustValue + $massError)
        $iterations++
        if ($settleMs -gt 0) { Start-Sleep -Milliseconds $settleMs }
    }
    $finalMass = [double](Get-DrefValue $totalName)
    if ([math]::Abs($finalMass - $targetMass) -gt $massTolerance) {
        throw "Mass correction failed: target $targetMass, actual $finalMass, tolerance $massTolerance."
    }
    $massCorrectionResult = [ordered]@{
        configured = $true
        target = $targetMass
        final = $finalMass
        tolerance = $massTolerance
        iterations = $iterations
        total_mass_dataref = $totalName
        adjust_dataref = $adjustName
    }
}

$script:CurrentStage = 'official_stabilization'
Start-Sleep -Milliseconds ([int]([double]$config.stabilizeSeconds * 1000))

$script:CurrentStage = 'sampling'
$samples = @()
for ($sampleIndex = 0; $sampleIndex -lt [int]$config.sampleCount; $sampleIndex++) {
    Start-Sleep -Milliseconds ([int]$config.sampleIntervalMs)
    $sample = [ordered]@{ sample = $sampleIndex; timestamp_utc = [datetime]::UtcNow.ToString('o') }
    foreach ($name in @($config.sampleDatarefs)) { $sample[$name] = [double](Get-DrefValue ([string]$name)) }
    $samples += [pscustomobject]$sample
}

$statistics = [ordered]@{}
foreach ($name in @($config.sampleDatarefs)) {
    $measure = $samples | Measure-Object -Property $name -Average -Minimum -Maximum
    $statistics[$name] = [ordered]@{
        average = [double]$measure.Average
        minimum = [double]$measure.Minimum
        maximum = [double]$measure.Maximum
        range = [double]$measure.Maximum - [double]$measure.Minimum
    }
}

function Get-Statistic([string]$Name) {
    if (-not $statistics.Contains($Name)) { throw "No sampled statistic exists for rejection rule '$Name'." }
    return $statistics[$Name]
}

$script:CurrentStage = 'validation'
$rejections = [System.Collections.Generic.List[string]]::new()
if ($null -ne $config.reject) {
    if ($config.reject.servoDataref) {
        $servoStats = Get-Statistic ([string]$config.reject.servoDataref)
        if ([double]$servoStats.minimum -lt 0.999) { $rejections.Add("Autopilot servos disengaged (minimum $($servoStats.minimum)).") }
    }
    if ($config.reject.bankDataref -and $null -ne $config.reject.maxAbsBank) {
        $bankName = [string]$config.reject.bankDataref
        $bankValues = $samples | ForEach-Object { [math]::Abs([double]$_.$bankName) }
        $bankMax = [double](($bankValues | Measure-Object -Maximum).Maximum)
        if ($bankMax -gt [double]$config.reject.maxAbsBank) {
            $rejections.Add("Bank exceeded limit: $bankMax > $($config.reject.maxAbsBank).")
        }
    }
    foreach ($rule in @($config.reject.maxRanges)) {
        if ($null -eq $rule) { continue }
        $stats = Get-Statistic ([string]$rule.name)
        if ([double]$stats.range -gt [double]$rule.max) {
            $rejections.Add("Range for $($rule.name) exceeded limit: $($stats.range) > $($rule.max).")
        }
    }
    foreach ($rule in @($config.reject.requiredValues)) {
        if ($null -eq $rule) { continue }
        $stats = Get-Statistic ([string]$rule.name)
        $tolerance = if ($null -ne $rule.tolerance) { [double]$rule.tolerance } else { 0.0 }
        $lower = [double]$rule.value - $tolerance
        $upper = [double]$rule.value + $tolerance
        if ([double]$stats.minimum -lt $lower -or [double]$stats.maximum -gt $upper) {
            $rejections.Add("Required value for $($rule.name) was not maintained: range $($stats.minimum)-$($stats.maximum), expected $($rule.value) +/- $tolerance.")
        }
    }
    foreach ($rule in @($config.reject.meanTargets)) {
        if ($null -eq $rule) { continue }
        $stats = Get-Statistic ([string]$rule.name)
        $tolerance = if ($null -ne $rule.tolerance) { [double]$rule.tolerance } else { 0.0 }
        if ([math]::Abs([double]$stats.average - [double]$rule.target) -gt $tolerance) {
            $rejections.Add("Mean for $($rule.name) missed target: $($stats.average) vs $($rule.target) +/- $tolerance.")
        }
    }
    foreach ($rule in @($config.reject.minimums)) {
        if ($null -eq $rule) { continue }
        $stats = Get-Statistic ([string]$rule.name)
        if ([double]$stats.minimum -lt [double]$rule.minimum) {
            $rejections.Add("Minimum for $($rule.name) was $($stats.minimum), below $($rule.minimum).")
        }
    }
    foreach ($rule in @($config.reject.maximums)) {
        if ($null -eq $rule) { continue }
        $stats = Get-Statistic ([string]$rule.name)
        if ([double]$stats.maximum -gt [double]$rule.maximum) {
            $rejections.Add("Maximum for $($rule.name) was $($stats.maximum), above $($rule.maximum).")
        }
    }
}

$result = [ordered]@{
    name = $config.name
    accepted = ($rejections.Count -eq 0)
    rejection_reasons = @($rejections)
    port = $Port
    config_path = $resolvedConfig
    started_utc = $startedUtc.ToString('o')
    completed_utc = [datetime]::UtcNow.ToString('o')
    immediate_pause_verified = $true
    command_duration_seconds = [double]$config.commandDurationSeconds
    paused_readiness = $pausedReadinessResult
    post_command_state = $postCommandStateResult
    convergence = $convergenceResult
    mass_correction = $massCorrectionResult
    official_stabilize_seconds = [double]$config.stabilizeSeconds
    sample_count = $samples.Count
    statistics = $statistics
    samples = $samples
}
$json = $result | ConvertTo-Json -Depth 20
if ($OutputPath) {
    Write-JsonFile $result $OutputPath | Out-Null
    $script:FailureWritten = $true
}
Write-Output $json
if ($rejections.Count -gt 0) { exit 2 }