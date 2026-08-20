[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VideoPath,
    [Parameter(Mandatory)] [string] $AudioPath,
    [Parameter(Mandatory)] [string] $AudioMetadataPath,
    [Parameter(Mandatory)] [string] $FfmpegPath,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string] $ResultPath,
    [Nullable[datetime]] $VideoStartUtc,
    [double] $MinimumPeakLinear = 0.0001,
    [double] $MinimumRmsLinear = 0.00001,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Require-File([string] $Path, [string] $Label) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is missing: $resolved"
    }
    return $resolved
}

function Invoke-Ffmpeg([string[]] $Arguments, [string] $Operation) {
    $output = (& $script:Ffmpeg @Arguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with FFmpeg exit code $LASTEXITCODE.`n$output"
    }
    return $output
}

$Video = Require-File $VideoPath 'Video input'
$Audio = Require-File $AudioPath 'Audio input'
$MetadataFile = Require-File $AudioMetadataPath 'Audio metadata'
$script:Ffmpeg = Require-File $FfmpegPath 'FFmpeg executable'
$Output = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($Output).ToLowerInvariant() -ne '.mp4') {
    throw 'OutputPath must use the .mp4 extension.'
}
if ((Test-Path -LiteralPath $Output) -and -not $Force) {
    throw "Output already exists; pass -Force to replace it: $Output"
}
if ($ResultPath) {
    $Result = [IO.Path]::GetFullPath($ResultPath)
    if ((Test-Path -LiteralPath $Result) -and -not $Force) {
        throw "ResultPath already exists; pass -Force to replace it: $Result"
    }
} else {
    $Result = $null
}

$metadata = Get-Content -LiteralPath $MetadataFile -Raw | ConvertFrom-Json
foreach ($field in @('started_epoch', 'duration_seconds', 'peak_linear', 'rms_linear', 'sample_rate', 'channels')) {
    if ($null -eq $metadata.$field) { throw "Audio metadata is missing '$field'." }
}
if ([double]$metadata.peak_linear -lt $MinimumPeakLinear) {
    throw "Audio is effectively silent: peak=$($metadata.peak_linear), required=$MinimumPeakLinear."
}
if ([double]$metadata.rms_linear -lt $MinimumRmsLinear) {
    throw "Audio is effectively silent: RMS=$($metadata.rms_linear), required=$MinimumRmsLinear."
}
if ([double]$metadata.duration_seconds -le 0) { throw 'Audio duration is not positive.' }

$audioStart = [DateTimeOffset]::FromUnixTimeMilliseconds(
    [long][math]::Round([double]$metadata.started_epoch * 1000.0)
).UtcDateTime
$videoStart = if ($null -ne $VideoStartUtc -and $VideoStartUtc.HasValue) {
    $VideoStartUtc.Value.ToUniversalTime()
} else {
    (Get-Item -LiteralPath $Video).CreationTimeUtc
}
$offsetSeconds = ($videoStart - $audioStart).TotalSeconds
$offsetText = [string]::Format(
    [Globalization.CultureInfo]::InvariantCulture,
    '{0:F6}',
    [math]::Abs($offsetSeconds)
)

$outputParent = Split-Path -Parent $Output
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent | Out-Null
}

$overwrite = if ($Force) { '-y' } else { '-n' }
$muxArguments = [System.Collections.Generic.List[string]]::new()
foreach ($argument in @($overwrite, '-i', $Video)) { $muxArguments.Add($argument) }
if ($offsetSeconds -ge 0) {
    foreach ($argument in @('-ss', $offsetText, '-i', $Audio)) { $muxArguments.Add($argument) }
} else {
    foreach ($argument in @('-itsoffset', $offsetText, '-i', $Audio)) { $muxArguments.Add($argument) }
}
foreach ($argument in @(
    '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'libx264', '-crf', '21', '-preset', 'medium', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '192k', '-ar', '48000',
    '-shortest', '-movflags', '+faststart', $Output
)) { $muxArguments.Add($argument) }

Invoke-Ffmpeg $muxArguments.ToArray() 'Evidence mux' | Out-Null
Invoke-Ffmpeg @('-v', 'error', '-i', $Output, '-f', 'null', '-') 'Full decode verification' | Out-Null
$volumeOutput = Invoke-Ffmpeg @('-hide_banner', '-i', $Output, '-af', 'volumedetect', '-f', 'null', '-') 'Volume verification'
$meanMatch = [regex]::Match($volumeOutput, 'mean_volume:\s*([^\s]+)\s*dB')
$maxMatch = [regex]::Match($volumeOutput, 'max_volume:\s*([^\s]+)\s*dB')
if (-not $meanMatch.Success -or -not $maxMatch.Success) {
    throw "FFmpeg did not report output volume.`n$volumeOutput"
}
if ($maxMatch.Groups[1].Value -eq '-inf') { throw 'Final MP4 audio is silent.' }

$verification = [ordered]@{
    verified = $true
    video_path = $Video
    audio_path = $Audio
    output_path = $Output
    output_bytes = (Get-Item -LiteralPath $Output).Length
    video_start_utc = $videoStart.ToString('o')
    audio_start_utc = $audioStart.ToString('o')
    audio_alignment_seconds = $offsetSeconds
    source_audio_duration_seconds = [double]$metadata.duration_seconds
    source_audio_peak_linear = [double]$metadata.peak_linear
    source_audio_rms_linear = [double]$metadata.rms_linear
    output_mean_volume_db = $meanMatch.Groups[1].Value
    output_max_volume_db = $maxMatch.Groups[1].Value
}

if ($Result) {
    $resultParent = Split-Path -Parent $Result
    if ($resultParent -and -not (Test-Path -LiteralPath $resultParent)) {
        New-Item -ItemType Directory -Path $resultParent | Out-Null
    }
    $verification | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Result -Encoding utf8NoBOM
}
$verification | ConvertTo-Json -Depth 5
