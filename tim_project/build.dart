// build.dart — Flutter native asset hook for llama_cpp_dart on Windows.
// This script is NOT invoked automatically by Flutter - run it manually or
// via the setup script to download llama.dll into the build output.
// llama_cpp_dart 0.2.2 uses llama.cpp near commit 4ffc47cb (b5206).

import 'dart:io';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) return;

  const url =
      'https://github.com/ggml-org/llama.cpp/releases/download/b5206/'
      'llama-b5206-bin-win-avx2-x64.zip';

  final buildDir = args.isNotEmpty ? args[0] : r'build\windows\x64\runner\Debug';
  final outDir = Directory(buildDir);
  await outDir.create(recursive: true);

  final dllFile = File('$buildDir\\llama.dll');
  if (dllFile.existsSync()) {
    print('[build.dart] llama.dll already present.');
    return;
  }

  print('[build.dart] Downloading llama.dll...');
  final result = await Process.run('powershell', [
    '-NoProfile', '-Command',
    r'$ProgressPreference = "SilentlyContinue"; ' +
    'Invoke-WebRequest -Uri "$url" -OutFile "llama_tmp.zip"; ' +
    r'Expand-Archive -Path "llama_tmp.zip" -DestinationPath "llama_unzip" -Force; ' +
    'Copy-Item (Get-ChildItem -Recurse "llama_unzip" -Filter "llama.dll" | Select-Object -First 1).FullName ' +
    '-Destination "${dllFile.path}"; ' +
    r'Remove-Item "llama_tmp.zip","llama_unzip" -Recurse -Force'
  ]);

  if (result.exitCode != 0) {
    stderr.writeln('[build.dart] Error: ${result.stderr}');
    exit(1);
  }
  print('[build.dart] Done: ${dllFile.path}');
}
