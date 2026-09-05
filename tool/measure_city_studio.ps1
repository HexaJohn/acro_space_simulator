# Copyright (c) 2026 John Peroutka
#
# This work is licensed under the PolyForm Noncommercial License 1.0.0.
# To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

# Builds and launches the city studio in profile mode, generates the
# reference colony, runs the perf A/B with the moving-camera sweep against
# the regression thresholds, samples the UI-thread profile, and stops the
# app. One command for "did this change cost frame time":
#
#   powershell -File tool/measure_city_studio.ps1 [-Tag name] [-Sprawl 20]
#       [-Static 12] [-Sweep 16] [-Worst 33] [-OutDir build/perf]
#
# Thresholds are milliseconds: the static average, the warm-orbit average,
# and the worst frame of any sweep. The script's exit code is the gate's.
# See wiki/GPU-Profiling.md for what each tool reports.
param(
  [string]$Tag = "run",
  [int]$Sprawl = 20,
  [double]$Static = 12,
  [double]$Sweep = 16,
  [double]$Worst = 33,
  [string]$OutDir = "build/perf"
)
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
New-Item -ItemType Directory -Force $OutDir | Out-Null
$log = Join-Path $OutDir "studio_$Tag.log"
if (Test-Path $log) { Remove-Item $log -Force }
Get-Process acro_space_simulator -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
$null = Start-Process -FilePath "cmd.exe" -ArgumentList "/c fvm flutter run -d windows --profile -t lib/main_city_studio_dev.dart --enable-impeller --enable-flutter-gpu > `"$log`" 2>&1" -PassThru -WindowStyle Hidden
$uri = $null
for ($i = 0; $i -lt 600; $i++) {
  Start-Sleep -Seconds 2
  if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern "VM Service on Windows is available at: (http\S+)" | Select-Object -First 1
    if ($m) { $uri = $m.Matches[0].Groups[1].Value; break }
    if (Select-String -Path $log -Pattern "Build failed|error MSB|Exception:|Error:" -Quiet) { break }
  }
}
if (-not $uri) { Write-Output "NO VM URI"; Get-Content $log -Tail 30; exit 1 }
Write-Output "== VM $uri"
$shot = Join-Path (Resolve-Path $OutDir) "shot_$Tag.png"
cmd /c "fvm dart run tool/city_perf_ab.dart $uri --sprawl=$Sprawl --distance=1320 --elevation=0.55 --samples=8 --sweep --spikes --assert=static:$Static,sweep:$Sweep,worst:$Worst --shot=$shot 2>&1" | Where-Object { $_ -notmatch "Running build hooks" }
$gate = $LASTEXITCODE
Write-Output "==== GATE exit $gate"
Write-Output "==== PROFILE"
cmd /c "fvm dart run tool/profile_ui_thread.dart $uri 6 2>&1" | Where-Object { $_ -notmatch "Running build hooks" } | Select-Object -First 40
Get-Process acro_space_simulator -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Write-Output "done (gate $gate)"
exit $gate
