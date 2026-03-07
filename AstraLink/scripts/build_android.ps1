param(
  [string]$ProjectDir = "C:\Users\odafi\Desktop\AstraLink\astralink_app",
  [string]$Version = "1.0.0+1",
  [switch]$BuildAab
)

$ErrorActionPreference = "Stop"

Set-Location $ProjectDir
flutter pub get
flutter build apk --release
if ($BuildAab) {
  flutter build appbundle --release
}

$root = Split-Path $ProjectDir -Parent
$target = Join-Path $root "dist\android\$Version"
New-Item -ItemType Directory -Force -Path $target | Out-Null

$apkSource = Join-Path $ProjectDir "build\app\outputs\flutter-apk\app-release.apk"
Copy-Item -Path $apkSource -Destination (Join-Path $target "app-release.apk") -Force

if ($BuildAab) {
  $aabSource = Join-Path $ProjectDir "build\app\outputs\bundle\release\app-release.aab"
  Copy-Item -Path $aabSource -Destination (Join-Path $target "app-release.aab") -Force
}

Write-Host "Android build is ready:"
Write-Host $target
