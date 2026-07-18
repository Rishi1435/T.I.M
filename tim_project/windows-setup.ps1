# ============================================================
# T.I.M. Windows bootstrap — run once from tim_project\
#   powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
# ============================================================
$ErrorActionPreference = "Stop"

Write-Host "[1/4] Checking Developer Mode (needed for Flutter plugin symlinks)..."
$dm = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
if (-not $dm -or $dm.AllowDevelopmentWithoutDevLicense -ne 1) {
  Write-Warning "Developer Mode looks OFF. If 'flutter run' fails with a symlink error, enable it:"
  Write-Warning "  Settings > System > For developers > Developer Mode > On"
}

Write-Host "[2/4] flutter pub get..."
flutter pub get

Write-Host "[3/4] Fetching llama.dll into Debug and Release output dirs..."
dart run build.dart "build\windows\x64\runner\Debug"
dart run build.dart "build\windows\x64\runner\Release"

Write-Host "[4/4] Done. Run the app with:"
Write-Host '  flutter run -d windows --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...'
Write-Host "Then: Settings -> Voice -> Download voice models (~180 MB, one time)."
