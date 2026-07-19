// ============================================================
// lib/data/services/windows_ocr.dart
// v0.3.4 — REAL screen reading, today, with zero new models.
//
// From the narrated recording: "when the user says look at my
// screen … it needs to take a screenshot of the ACTIVE screen and
// analyze it" — and the old flow ended in a stub reply because no
// vision model is bundled yet.
//
// Windows 10/11 ships an OCR engine (Windows.Media.Ocr). We reach
// it through powershell.exe (WinRT projection works on the built-in
// PowerShell 5.1; NOT pwsh 7 — hence the explicit executable). The
// captured desktop PNG goes in, the readable text of the screen
// comes out, and the LLM analyzes that text. For code, docs, web
// pages, and interview questions on screen — the actual use cases —
// text is what matters. A pixel-level vision model can layer on
// later via the existing VisionEngine hook.
// ============================================================

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';

class WindowsOcr {
  static final Logger _log = Logger('WindowsOcr');

  static const String _psScript = r'''
param([string]$Path)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
Function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}
$null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
$file    = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream  = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap  = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$engine  = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { exit 2 }
$result  = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
foreach ($line in $result.Lines) { Write-Output $line.Text }
''';

  /// OCR a PNG on disk via the built-in Windows OCR engine.
  /// Returns extracted text, or null if OCR is unavailable/failed.
  static Future<String?> extractText(List<int> pngBytes) async {
    if (!Platform.isWindows) return null;
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('tim_ocr_');
      final imgPath = p.join(tmp.path, 'capture.png');
      final scriptPath = p.join(tmp.path, 'ocr.ps1');
      await File(imgPath).writeAsBytes(pngBytes);
      await File(scriptPath).writeAsString(_psScript);

      final result = await Process.run(
        'powershell.exe', // 5.1 specifically — WinRT breaks on pwsh 7
        [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-File', scriptPath,
          '-Path', imgPath,
        ],
      ).timeout(const Duration(seconds: 30));

      if (result.exitCode != 0) {
        _log.warn('OCR exited ${result.exitCode}: ${result.stderr}');
        return null;
      }
      final text = (result.stdout as String).trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      _log.warn('OCR failed: $e');
      return null;
    } finally {
      try {
        await tmp?.delete(recursive: true);
      } catch (_) {}
    }
  }
}
