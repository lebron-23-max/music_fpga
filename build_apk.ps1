$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $root 'app'
$tool = Join-Path $root 'toolchain'
$jdk = Join-Path $tool 'jdk-17.0.13+11'
$buildTools = Join-Path $tool 'android-15'
$androidJar = Join-Path $tool 'android-35/android.jar'
$build = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
$env:JAVA_HOME = $jdk
$env:Path = (Join-Path $jdk 'bin') + ';' + (Join-Path $buildTools '') + ';' + $env:Path

if (Test-Path $build) {
    $resolved = (Resolve-Path $build).Path
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe build path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $build 'gen') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $build 'classes') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $build 'dex') -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$resZip = Join-Path $build 'res.zip'
& (Join-Path $buildTools 'aapt2.exe') compile --dir (Join-Path $app 'res') -o $resZip

$unsigned = Join-Path $build 'unsigned-unaligned.apk'
& (Join-Path $buildTools 'aapt2.exe') link -o $unsigned -I $androidJar --manifest (Join-Path $app 'AndroidManifest.xml') --java (Join-Path $build 'gen') --min-sdk-version 23 --target-sdk-version 35 -A (Join-Path $app 'assets') $resZip
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

$javaFiles = @(Get-ChildItem -LiteralPath (Join-Path $app 'java') -Recurse -Filter '*.java' | ForEach-Object FullName)
$genFiles = @(Get-ChildItem -LiteralPath (Join-Path $build 'gen') -Recurse -Filter '*.java' | ForEach-Object FullName)
$allJava = $javaFiles + $genFiles
& (Join-Path $jdk 'bin/javac.exe') -encoding UTF-8 -source 8 -target 8 -classpath $androidJar -d (Join-Path $build 'classes') $allJava
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

$classFiles = @(Get-ChildItem -LiteralPath (Join-Path $build 'classes') -Recurse -Filter '*.class' | ForEach-Object FullName)
& (Join-Path $buildTools 'd8.bat') --lib $androidJar --release --min-api 23 --output (Join-Path $build 'dex') $classFiles
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

$dex = Join-Path $build 'dex/classes.dex'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($unsigned, [IO.Compression.ZipArchiveMode]::Update)
try {
    $old = $zip.GetEntry('classes.dex')
    if ($old) { $old.Delete() }
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dex, 'classes.dex', [IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally { $zip.Dispose() }

$aligned = Join-Path $build 'aligned.apk'
& (Join-Path $buildTools 'zipalign.exe') -f -p 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }

$keystore = Join-Path $root 'debug.keystore'
if (-not (Test-Path $keystore)) {
    & (Join-Path $jdk 'bin/keytool.exe') -genkeypair -keystore $keystore -alias androiddebugkey -storepass android -keypass android -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
}
$final = Join-Path $dist 'YunYinKong-v1.7.apk'
& (Join-Path $buildTools 'apksigner.bat') sign --ks $keystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out $final $aligned
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }
& (Join-Path $buildTools 'apksigner.bat') verify --verbose $final | Tee-Object -FilePath (Join-Path $dist 'verify.txt')
$hash = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToUpperInvariant()
Set-Content -LiteralPath (Join-Path $dist 'SHA256.txt') -Value $hash -Encoding ASCII
Write-Host "APK=$final"
Write-Host "SHA256=$hash"