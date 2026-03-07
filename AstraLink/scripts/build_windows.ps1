param(
  [string]$ProjectDir = "C:\Users\odafi\Desktop\AstraLink\astralink_app",
  [string]$Version = "1.0.0+1"
)

$ErrorActionPreference = "Stop"

Set-Location $ProjectDir
flutter pub get
flutter build windows --release

$root = Split-Path $ProjectDir -Parent
$target = Join-Path $root "dist\windows\$Version"
New-Item -ItemType Directory -Force -Path $target | Out-Null

Copy-Item -Path (Join-Path $ProjectDir "build\windows\x64\runner\Release\*") -Destination $target -Recurse -Force

$safeVersion = $Version.Replace("+", "_")
$archive = Join-Path $root "dist\windows\astralink_windows_$safeVersion.zip"
Compress-Archive -Path (Join-Path $target "*") -DestinationPath $archive -Force

Write-Host "Windows build is ready:"
Write-Host $target
Write-Host $archive
