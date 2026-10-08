$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$frontend = Join-Path $repoRoot 'frontend'
$cacheRoot = 'D:\cineme-tool-cache'
$definesFile = Join-Path $frontend 'dart_defines.env'
$releaseDefinesFile = Join-Path $cacheRoot 'dart-defines.release.json'
$apkSource = Join-Path $frontend 'build\app\outputs\flutter-apk\app-release.apk'
$artifactDirectory = Join-Path $repoRoot 'artifacts\android'
$apkDestination = Join-Path $artifactDirectory 'cineme-release.apk'
$productionApiBaseUrl = 'https://cineme-theta.vercel.app'

function Assert-ReleaseApkProductionApiTarget {
    param(
        [Parameter(Mandatory = $true)][string]$ApkPath,
        [Parameter(Mandatory = $true)][string]$ExpectedApiBaseUrl
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $appLibraries = @($archive.Entries | Where-Object {
            $_.FullName -match '^lib/[^/]+/libapp\.so$'
        })
        if ($appLibraries.Count -eq 0) {
            throw 'Release APK contains no Flutter app libraries; refusing to distribute it.'
        }

        $loopbackPattern = '(?i)https?://(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|10\.0\.2\.2|10\.0\.3\.2|\[::1\])(?::\d+)?'
        foreach ($entry in $appLibraries) {
            $memory = New-Object System.IO.MemoryStream
            $stream = $entry.Open()
            try {
                $stream.CopyTo($memory)
                $binaryText = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
            }
            finally {
                $stream.Dispose()
                $memory.Dispose()
            }

            if (-not $binaryText.Contains($ExpectedApiBaseUrl)) {
                throw "Production API target is missing from $($entry.FullName); refusing to distribute the APK."
            }
            if ($binaryText -match $loopbackPattern -or $binaryText.Contains('same-origin')) {
                throw "Loopback or same-origin API target found in $($entry.FullName); refusing to distribute the APK."
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $definesFile -PathType Leaf)) {
    throw "Flutter runtime configuration not found: $definesFile"
}

$runtimeDefines = @{}
Get-Content -LiteralPath $definesFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $separator = $line.IndexOf('=')
            if ($separator -lt 1) {
                throw "Invalid runtime define in $definesFile"
            }
            $name = $line.Substring(0, $separator).Trim()
            $value = $line.Substring($separator + 1).Trim()
            if ($name -ne 'API_BASE_URL' -and $name -ne 'SOURCE_COMMIT') {
                if ($runtimeDefines.ContainsKey($name)) {
                    throw "Duplicate runtime define in $definesFile"
                }
                $runtimeDefines[$name] = $value
            }
        }
    }

foreach ($requiredDefine in @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')) {
    if (-not $runtimeDefines.ContainsKey($requiredDefine) -or -not $runtimeDefines[$requiredDefine]) {
        throw "Required production runtime define is missing: $requiredDefine"
    }
}

$runtimeDefines['API_BASE_URL'] = $productionApiBaseUrl
$runtimeDefines['CINEME_PREVIEW'] = 'false'

if ($runtimeDefines.Count -eq 0) {
    throw "No runtime defines found in $definesFile"
}

$sourceCommit = (& git -C $repoRoot rev-parse --short HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceCommit) {
    throw 'Could not determine the source commit for the release build.'
}
$runtimeDefines['SOURCE_COMMIT'] = $sourceCommit

$flutterDirectory = Join-Path $env:USERPROFILE 'flutter'
$flutterShortPath = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($flutterDirectory).ShortPath
$flutterCommand = Join-Path $flutterShortPath 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterCommand -PathType Leaf)) {
    throw "Flutter executable not found: $flutterCommand"
}

$null = New-Item -ItemType Directory -Force -Path `
    (Join-Path $cacheRoot 'gradle'), `
    (Join-Path $cacheRoot 'tmp'), `
    $artifactDirectory
$env:GRADLE_USER_HOME = Join-Path $cacheRoot 'gradle'
$env:TEMP = Join-Path $cacheRoot 'tmp'
$env:TMP = $env:TEMP
$env:GRADLE_OPTS = '-Dorg.gradle.project.kotlin.incremental=false'
$runtimeDefines | ConvertTo-Json | Set-Content -LiteralPath $releaseDefinesFile -Encoding utf8

Push-Location $frontend
try {
    & $flutterCommand build apk --release "--dart-define-from-file=$releaseDefinesFile"
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build apk failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $releaseDefinesFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $apkSource -PathType Leaf)) {
    throw "Expected release APK was not produced: $apkSource"
}

Assert-ReleaseApkProductionApiTarget -ApkPath $apkSource -ExpectedApiBaseUrl $productionApiBaseUrl

Copy-Item -LiteralPath $apkSource -Destination $apkDestination -Force
$sourceHash = (Get-FileHash -LiteralPath $apkSource -Algorithm SHA256).Hash
$copyHash = (Get-FileHash -LiteralPath $apkDestination -Algorithm SHA256).Hash
if ($sourceHash -ne $copyHash) {
    throw 'Copied APK SHA-256 does not match the build output.'
}

Get-Item -LiteralPath $apkDestination | Select-Object FullName, Length
"SHA256: $copyHash"
