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

Write-Host "[3/4] Clearing stale llama.dll locks (the Windows build COMPILES llama.dll itself)..."
# The runner's CMake builds a unified llama.dll (llama_shared target) with
# every llama_* AND ggml_* symbol exported. Never pre-download a DLL into
# the build output: official llama.cpp release DLLs split those symbols
# (wrong for our FFI) and a pre-placed/locked file makes the linker fail
# with LNK1168 "cannot open llama.dll for writing".
taskkill /F /IM tim_project.exe 2>$null | Out-Null
foreach ($cfg in @("Debug","Release")) {
  $dll = "build\windows\x64\runner\$cfg\llama.dll"
  if (Test-Path $dll) { Remove-Item $dll -Force -ErrorAction SilentlyContinue }
}

Write-Host "[4/4] Done. Run the app with:"
Write-Host '  flutter run -d windows --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...'
Write-Host "Then: Settings -> Voice -> Download voice models (~180 MB, one time)."
