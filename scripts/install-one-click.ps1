param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
try {
    $root = Split-Path -Parent $PSScriptRoot
    $apk = Join-Path $root 'Builds\GlassesFoVLab.apk'
    if (-not (Test-Path -LiteralPath $apk)) { throw 'APK not found in Builds\GlassesFoVLab.apk.' }

    # Prefer a bundled platform-tools folder for portable distribution.
    $candidates = @(
        (Join-Path $root 'platform-tools\adb.exe'),
        'C:\Program Files\Unity\Hub\Editor\6000.6.3f1\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\platform-tools\adb.exe',
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
    )
    if ($env:ANDROID_HOME) { $candidates += Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }
    if ($env:ANDROID_SDK_ROOT) { $candidates += Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe' }
    $fromPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($fromPath) { $candidates += $fromPath.Source }
    $adb = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $adb) {
        if ($CheckOnly) { throw 'ADB not found. Normal installation can download official Android platform-tools.' }
        Write-Host 'Android platform-tools (ADB) is needed on this PC.'
        Write-Host 'Official download: https://developer.android.com/tools/releases/platform-tools'
        Write-Host 'Terms: https://developer.android.com/studio/terms'
        $accept = Read-Host 'Accept the Android SDK terms and download platform-tools? (Y/N)'
        if ($accept -notmatch '^[Yy]$') { throw 'Download cancelled. No app was installed.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $downloadDir = Join-Path $root '.installer-cache'
        New-Item -ItemType Directory -Force $downloadDir | Out-Null
        $archive = Join-Path $downloadDir 'platform-tools.zip'
        Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
        $adb = Join-Path $root 'platform-tools\adb.exe'
        if (-not (Test-Path -LiteralPath $adb)) { throw 'Download did not contain adb.exe.' }
    }
    Write-Host 'Glasses FoV Lab - Quest USB installer' -ForegroundColor Cyan
    Write-Host 'Checking USB devices...'
    $lines = & $adb devices -l
    if ($LASTEXITCODE -ne 0) { throw 'Could not communicate with ADB.' }
    $quests = @()
    $unauthorized = $false
    foreach ($line in $lines) {
        if ($line -match '^\S+\s+unauthorized\b') { $unauthorized = $true }
        if ($line -notmatch '^(\S+)\s+device\b') { continue }
        $serial = $Matches[1]
        $model = ((& $adb -s $serial shell getprop ro.product.model) -join '').Trim()
        if ($LASTEXITCODE -ne 0) { continue }
        if ($model -notmatch 'Quest') { continue }
        $quests += [PSCustomObject]@{ Serial = $serial; Model = $model }
    }
    if ($quests.Count -eq 0) {
        if ($unauthorized) { throw 'Put on your Quest and ALLOW USB debugging, then double-click Install-Quest.cmd again.' }
        throw 'No ready Quest found. Enable developer mode, connect a USB data cable, and allow USB debugging in the headset.'
    }
    $selected = $quests[0]
    if ($quests.Count -gt 1) {
        Write-Host 'Multiple Quest devices found:'
        for ($i = 0; $i -lt $quests.Count; $i++) { Write-Host ("{0}. {1} ({2})" -f ($i + 1), $quests[$i].Model, $quests[$i].Serial) }
        if ($CheckOnly) { Write-Host 'Check passed. Device selection will be required during installation.'; exit 0 }
        $choice = 0
        $answer = Read-Host 'Enter the device number'
        if (-not [int]::TryParse($answer, [ref]$choice) -or $choice -lt 1 -or $choice -gt $quests.Count) { throw 'Invalid device number. No app was installed.' }
        $selected = $quests[$choice - 1]
    }
    Write-Host ("Target: {0} ({1})" -f $selected.Model, $selected.Serial)
    if ($CheckOnly) { Write-Host 'Check passed. Ready to install.' -ForegroundColor Green; exit 0 }
    Write-Host 'Installing / updating the app...'
    & $adb -s $selected.Serial install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'Installation failed. See the ADB message above.' }
    & $adb -s $selected.Serial shell am start -n 'com.glasseslab.fov/com.unity3d.player.UnityPlayerGameActivity'
    if ($LASTEXITCODE -ne 0) { throw 'Installed, but automatic launch failed. Open Glasses FoV Lab in the headset.' }
    Write-Host 'Done! Put on your Quest. Glasses FoV Lab is ready.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
