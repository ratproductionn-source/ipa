<#
.SYNOPSIS
    Puts an ad-free, Premium-like YouTube into an LDPlayer instance.

.DESCRIPTION
    Two modes:

      -Mode patch     (default) pulls the YouTube APKs already installed in the
                      emulator, merges the splits, runs the patch bundle and
                      installs the result as com.google.android.youtube.
                      Only works when the installed YouTube version is inside the
                      patch bundle's supported range.

      -Mode prebuilt  installs a maintained patched build (package
                      app.morphe.android.youtube) next to the stock app. No
                      uninstall, no version constraints.

    Both modes install the microG companion needed for sign-in.

.PARAMETER LdPlayerDir
    LDPlayer install directory (contains adb.exe + ldconsole.exe). Auto-detected.

.PARAMETER Mode
    patch | prebuilt  (default: patch)

.PARAMETER ApkPath
    patch mode only: patch this APK instead of pulling the installed one.

.PARAMETER PatchesUrl
    Override the patch bundle (.rvp).

.PARAMETER PrebuiltUrl
    Override the prebuilt APK used by -Mode prebuilt.

.PARAMETER NoInstall
    Build/download only; do not touch the device.

.EXAMPLE
    .\ytbypass.ps1 -Mode prebuilt

.EXAMPLE
    .\ytbypass.ps1 -Mode patch -NoInstall
#>
[CmdletBinding()]
param(
    [string] $LdPlayerDir = '',
    [ValidateSet('patch', 'prebuilt')]
    [string] $Mode = 'patch',
    [string] $Device = '',
    [string] $ApkPath = '',
    [string] $JavaPath = '',
    [string] $ToolsDir = (Join-Path $env:LOCALAPPDATA 'ytbypass'),
    [string] $WorkDir = (Join-Path $env:TEMP 'ytbypass-build'),
    [string] $CliVersion = '5.0.1',
    [string] $PatchesUrl = '',
    [string] $PrebuiltUrl = '',
    [string] $MicroGUrl = '',
    [switch] $NoInstall,
    [switch] $KeepStockApp
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Info($text) { Write-Host "    $text" -ForegroundColor Gray }
function Write-Ok($text)   { Write-Host "    $text" -ForegroundColor Green }
function Write-Warn2($text) { Write-Host "    $text" -ForegroundColor Yellow }
function Stop-WithError($text) { Write-Host "`n[error] $text" -ForegroundColor Red; exit 1 }

function Get-RemoteFile {
    param([string] $Uri, [string] $OutFile, [switch] $Force)
    if ((Test-Path $OutFile) -and -not $Force) {
        Write-Info "cached: $(Split-Path $OutFile -Leaf)"
        return
    }
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    Write-Info "downloading $(Split-Path $OutFile -Leaf)"
    $tmp = "$OutFile.part"
    & curl.exe -sL -f --retry 3 --retry-delay 3 --max-time 3600 -o $tmp $Uri
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { Stop-WithError "download failed: $Uri" }
    Move-Item -Force $tmp $OutFile
    Write-Ok ("{0:N1} MB" -f ((Get-Item $OutFile).Length / 1MB))
}

function Get-ReleaseAsset {
    param([string] $Repo, [string] $Pattern, [string] $Tag = 'latest')
    $api = "https://api.github.com/repos/$Repo/releases/$Tag"
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'ytbypass'; 'Accept' = 'application/vnd.github+json' }
    $asset = $release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { Stop-WithError "no asset matching '$Pattern' in $Repo $($release.tag_name)" }
    Write-Info "$Repo $($release.tag_name) -> $($asset.name)"
    return $asset.browser_download_url
}

# ---------------------------------------------------------------- adb / device

function Find-LdPlayerDir {
    $candidates = @(
        $LdPlayerDir,
        'E:\LDPlayer\LDPlayer14', 'E:\LDPlayer\LDPlayer9', 'D:\LDPlayer\LDPlayer9',
        'C:\LDPlayer\LDPlayer9', 'C:\LDPlayer\LDPlayer14',
        'C:\Program Files\LDPlayer\LDPlayer9', 'C:\Program Files\LDPlayer\LDPlayer14'
    ) | Where-Object { $_ }
    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir 'adb.exe')) { return $dir }
    }
    $found = Get-ChildItem 'C:\','D:\','E:\' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'LDPlayer' } |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Where-Object { Test-Path (Join-Path $_.FullName 'adb.exe') } |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    Stop-WithError 'LDPlayer not found. Pass -LdPlayerDir "E:\LDPlayer\LDPlayer14".'
}

$LdPlayerDir = Find-LdPlayerDir
$adb = Join-Path $LdPlayerDir 'adb.exe'
Write-Step 'LDPlayer'
Write-Info $LdPlayerDir

if (-not $Device) {
    & $adb start-server 2>$null | Out-Null
    $lines = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    if (-not $lines) {
        Write-Info 'no running instance, trying 127.0.0.1:5555'
        & $adb connect 127.0.0.1:5555 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $lines = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    }
    if (-not $lines) { Stop-WithError 'No LDPlayer device online. Boot an instance first.' }
    $Device = ("$($lines[0])" -split "`t")[0].Trim()
}
Write-Ok "device: $Device"

$release = (& $adb -s $Device shell getprop ro.build.version.release).Trim()
$abi = (& $adb -s $Device shell getprop ro.product.cpu.abi).Trim()
Write-Ok "Android $release / $abi"

function Install-Apk {
    param([string] $Path)
    & $adb -s $Device install -r $Path 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Info "$_" }
    return ($LASTEXITCODE -eq 0)
}

function Start-App {
    param([string] $Package)
    Start-Sleep -Seconds 2
    $activity = (& $adb -s $Device shell "cmd package resolve-activity --brief $Package" 2>$null |
        ForEach-Object { "$_" } |
        Where-Object { $_ -match '^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$' } |
        Select-Object -Last 1)
    if ($activity) {
        & $adb -s $Device shell "am start -n $activity" 2>&1 | Out-Null
        Write-Ok "launched: $activity"
    } else {
        Write-Warn2 "could not resolve a launcher activity for $Package"
    }
}

function Install-MicroG {
    param([switch] $Morphe)
    $has = (& $adb -s $Device shell 'pm list packages | grep "app.revanced.android.gms"').Trim()
    if ($has) { Write-Info 'microG already installed'; return }

    $url = $MicroGUrl
    if (-not $url) {
        if ($Morphe) {
            $url = Get-ReleaseAsset -Repo 'MorpheApp/MicroG-RE' -Pattern 'microg-*.*apk'
        } else {
            $url = Get-ReleaseAsset -Repo 'ReVanced/GmsCore' -Pattern '*-signed.apk'
        }
    }
    $apk = Join-Path $ToolsDir 'microg.apk'
    Get-RemoteFile -Uri $url -OutFile $apk
    if (Install-Apk $apk) { Write-Ok 'microG installed' } else { Write-Warn2 'microG install failed' }
}

New-Item -ItemType Directory -Force $ToolsDir, $WorkDir | Out-Null

# ------------------------------------------------------- mode: prebuilt build

if ($Mode -eq 'prebuilt') {
    Write-Step 'Prebuilt patched build'
    if (-not $PrebuiltUrl) {
        $PrebuiltUrl = Get-ReleaseAsset -Repo 'j-hc/revanced-magisk-module' -Pattern 'youtube-morphe-*-all.apk'
    }
    $apk = Join-Path $ToolsDir 'youtube-prebuilt.apk'
    Get-RemoteFile -Uri $PrebuiltUrl -OutFile $apk

    if ($NoInstall) {
        Write-Step 'Done (no install requested)'
        Write-Ok $apk
        exit 0
    }

    Write-Step 'Installing'
    if (-not (Install-Apk $apk)) { Stop-WithError 'install failed - see the adb output above' }
    Install-MicroG -Morphe
    Start-App -Package 'app.morphe.android.youtube'

    Write-Step 'Done'
    Write-Ok "APK: $apk"
    Write-Info 'Sign in: profile picture -> Add account -> microG prompt.'
    exit 0
}

# ----------------------------------------------------------------------- java

function Resolve-Java {
    if ($JavaPath -and (Test-Path $JavaPath)) { return $JavaPath }
    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cached = Get-ChildItem $ToolsDir -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'bin\\java\.exe$' } | Select-Object -First 1
    if ($cached) { return $cached.FullName }

    Write-Step 'No Java found - downloading a portable JDK 21'
    $zip = Join-Path $ToolsDir 'jdk21.zip'
    $mirrors = @(
        'https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.zip',
        'https://download.bell-sw.com/java/21.0.5+11/bellsoft-jdk21.0.5+11-windows-amd64.zip'
    )
    $ok = $false
    foreach ($url in $mirrors) {
        Get-RemoteFile -Uri $url -OutFile $zip -Force
        if (Test-Path $zip) { $ok = $true; break }
    }
    if (-not $ok) { Stop-WithError 'Could not download a JDK. Install Java 17+ and pass -JavaPath.' }

    $dest = Join-Path $ToolsDir 'jdk'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    $java = Get-ChildItem $dest -Recurse -Filter 'java.exe' | Select-Object -First 1
    if (-not $java) { Stop-WithError 'The downloaded archive did not contain java.exe.' }
    return $java.FullName
}

$java = Resolve-Java
Write-Step 'Java'
Write-Info $java
$javaVersion = (& $java -version 2>&1 | ForEach-Object { "$_" } | Select-Object -First 1)
Write-Ok ($javaVersion -replace '^.*?:\s*', '')

# ---------------------------------------------------------------------- tools

Write-Step 'Toolchain'
$cliJar = Join-Path $ToolsDir "revanced-cli-$CliVersion.jar"
if (-not (Test-Path $cliJar)) {
    $cliUrl = "https://github.com/ReVanced/revanced-cli/releases/download/v$CliVersion/revanced-cli-$CliVersion-all.jar"
    Get-RemoteFile -Uri $cliUrl -OutFile $cliJar
} else { Write-Info "cached: $(Split-Path $cliJar -Leaf)" }

$apkEditor = Join-Path $ToolsDir 'APKEditor.jar'
if (-not (Test-Path $apkEditor)) {
    Get-RemoteFile -Uri (Get-ReleaseAsset -Repo 'REAndroid/APKEditor' -Pattern 'APKEditor-*.jar') -OutFile $apkEditor
} else { Write-Info 'cached: APKEditor.jar' }

$patchesFile = Join-Path $ToolsDir 'patches.rvp'
if ($PatchesUrl) {
    Get-RemoteFile -Uri $PatchesUrl -OutFile $patchesFile
} elseif (-not (Test-Path $patchesFile)) {
    Get-RemoteFile -Uri (Get-ReleaseAsset -Repo 'inotia00/revanced-patches' -Pattern '*.rvp') -OutFile $patchesFile
} else { Write-Info 'cached: patches.rvp' }

# ------------------------------------------------------------------- obtain apk

$sourceApk = $ApkPath
if (-not $sourceApk) {
    Write-Step 'Pulling the installed YouTube APKs'

    $found = (& $adb -s $Device shell 'pm list packages | grep -i "com.google.android.youtube"').Trim()
    if (-not $found) { Stop-WithError 'YouTube is not installed in the emulator, and -ApkPath was not given.' }
    $packageName = ($found -split ':')[-1].Trim()
    Write-Info "package: $packageName"

    $paths = @(& $adb -s $Device shell "pm path $packageName" | ForEach-Object { $_.Trim().Replace('package:', '') })
    $splitDir = Join-Path $WorkDir 'splits'
    if (Test-Path $splitDir) { Remove-Item -Recurse -Force $splitDir }
    New-Item -ItemType Directory -Force $splitDir | Out-Null

    # /data/app is unreadable for a normal shell, so ask adbd for root once.
    & $adb -s $Device root 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $adb -s $Device wait-for-device

    foreach ($p in $paths) {
        $name = Split-Path $p -Leaf
        & $adb -s $Device pull $p (Join-Path $splitDir $name) 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $splitDir $name))) {
            Stop-WithError "could not pull $p (adbd is probably not root)"
        }
        Write-Info "pulled $name"
    }

    Write-Step 'Merging split APKs'
    $sourceApk = Join-Path $WorkDir 'youtube-merged.apk'
    if (Test-Path $sourceApk) { Remove-Item -Force $sourceApk }
    & $java -jar $apkEditor merge -i $splitDir -o $sourceApk 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Info "$_" }
    if (-not (Test-Path $sourceApk)) { Stop-WithError 'APKEditor did not produce a merged APK.' }
    Write-Ok ("merged: {0:N1} MB" -f ((Get-Item $sourceApk).Length / 1MB))
}

# --------------------------------------------------------------------- patch

Write-Step 'Patching'
$patchedApk = Join-Path $WorkDir 'youtube-patched.apk'
$patchLog = Join-Path $WorkDir 'patch.log'
if (Test-Path $patchedApk) { Remove-Item -Force $patchedApk }

$cliArgs = @(
    '-Xmx4G', '-jar', $cliJar, 'patch',
    '--patches', $patchesFile,
    '--out', $patchedApk,
    '--temporary-files-path', (Join-Path $WorkDir 'tmp'),
    $sourceApk
)
$output = & $java @cliArgs 2>&1 | Tee-Object -FilePath $patchLog
$exit = $LASTEXITCODE
if ($exit -ne 0 -or -not (Test-Path $patchedApk)) {
    Write-Warn2 "patch log: $patchLog"
    Stop-WithError "patching failed (exit $exit)"
}

$skipped = @($output | Select-String 'incompatible with')
Write-Ok ("patched: {0:N1} MB" -f ((Get-Item $patchedApk).Length / 1MB))

$noAdsSkipped = @($skipped | Where-Object { $_.Line -match '"Hide ads"' }).Count -gt 0
if ($noAdsSkipped) {
    Write-Warn2 'The ad-removal patch does not support this YouTube version, so the result will still show ads.'
    Write-Warn2 'Use -Mode prebuilt, or pass -ApkPath with a YouTube APK the patch bundle supports.'
} elseif ($skipped.Count -gt 0) {
    Write-Warn2 "$($skipped.Count) optional patches were skipped (version out of range)."
}

if ($NoInstall) {
    Write-Step 'Done (no install requested)'
    Write-Ok $patchedApk
    exit 0
}

# --------------------------------------------------------------------- install

Write-Step 'Installing'

$installed = (& $adb -s $Device shell 'pm list packages | grep -i "com.google.android.youtube"').Trim()
if ($installed -and -not $KeepStockApp) {
    $existing = ($installed -split ':')[-1].Trim()
    Write-Info "uninstalling $existing (signature changed)"
    & $adb -s $Device uninstall $existing 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & $adb -s $Device shell "pm uninstall --user 0 $existing" 2>&1 | Out-Null
    }
}

if (-not (Install-Apk $patchedApk)) { Stop-WithError 'install failed - see the adb output above' }
Install-MicroG
Start-App -Package 'com.google.android.youtube'

Write-Step 'Done'
Write-Ok "APK: $patchedApk"
Write-Info 'Sign in: profile picture -> Add account -> microG prompt.'
Write-Info 'Patch bundle updates: delete patches.rvp from the tools dir and rerun.'
