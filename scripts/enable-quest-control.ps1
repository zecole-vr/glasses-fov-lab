param([string]$Serial)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
try {
    $paths=@((Join-Path $root 'platform-tools\adb.exe'), 'C:\Program Files\Unity\Hub\Editor\6000.6.3f1\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\platform-tools\adb.exe', (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
    $found=Get-Command adb.exe -ErrorAction SilentlyContinue
    if($found) { $paths+=$found.Source }
    $adb=$paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if(-not $adb) { throw 'Run Install-Quest.cmd first to install the app and ADB.' }
    # Accept both USB serials and wireless ADB (ip:port) devices.
    function Get-ReadySerials { @(& $adb devices | ForEach-Object { if($_ -match '^(\S+)\s+device$') { $Matches[1] } }) }
    $ready=@(Get-ReadySerials)
    if($ready.Count -eq 0) {
        # Try already-paired wireless debugging devices advertised over mDNS.
        Write-Host 'No device connected. Looking for a paired wireless-debugging Quest...'
        $ErrorActionPreference='Continue'
        # A freshly started ADB server needs a few seconds to discover mDNS services.
        for($scan=0; $scan -lt 6; $scan++) {
            $found=@(& $adb mdns services 2>$null | Where-Object { $_ -match '_adb-tls-connect\._tcp' })
            if($found.Count -gt 0) { break }
            Start-Sleep -Seconds 2
        }
        foreach($line in $found) {
            if($line -match '_adb-tls-connect\._tcp\s+(\d{1,3}(?:\.\d{1,3}){3}:\d+)') { & $adb connect $Matches[1] | Out-Host }
        }
        $ErrorActionPreference='Stop'
        # A freshly connected device can report "offline" for a moment.
        for($try=0; $try -lt 5; $try++) { $ready=@(Get-ReadySerials); if($ready.Count -gt 0) { break }; Start-Sleep -Seconds 1 }
    }
    if(-not $Serial -and $ready.Count -eq 1) { $Serial=$ready[0] }
    if(-not $Serial -and $ready.Count -gt 1) { $Serial=Read-Host ('Enter device ID: '+($ready -join ', ')) }
    if($Serial -notin $ready) { throw 'Connect Quest by USB or wireless debugging, and allow debugging in the headset.' }
    $model=(& $adb -s $Serial shell getprop ro.product.model).Trim()
    if($model -notmatch 'Quest') { throw 'Selected device is not a Quest.' }
    $dex=Join-Path $root 'bridge\bin\classes.dex'
    if(-not (Test-Path $dex)) { throw 'Missing bridge/bin/classes.dex. Extract the complete ZIP.' }
    & $adb -s $Serial shell run-as com.glasseslab.fov mkdir -p files
    if($LASTEXITCODE -ne 0) { throw 'Install the Glasses FoV Lab development APK first.' }
    # The same private key is reused when this helper is already running.
    $ErrorActionPreference='Continue'
    $key=((& $adb -s $Serial shell run-as com.glasseslab.fov cat files/fov-control.key 2>$null) -join '').Trim()
    $ErrorActionPreference='Stop'
    if($key -notmatch '^[a-f0-9]{64}$') {
        $bytes=New-Object byte[] 32
        $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes); $rng.Dispose()
        $key=([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
        $key | & $adb -s $Serial shell "run-as com.glasseslab.fov sh -c 'cat > files/fov-control.key'"
        if($LASTEXITCODE -ne 0) { throw 'Could not store app-private pairing key.' }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'game-fov.ps1') -Action Check -DeviceId $Serial
    if($LASTEXITCODE -ne 0) { throw 'Meta CLI connection failed.' }
    $cli=Join-Path $root '.tools\metavr\metavr.exe'
    $props=@('debug.oculus.eyeFovUp','debug.oculus.eyeFovDown','debug.oculus.eyeFovInward','debug.oculus.eyeFovOutward','debug.oculus.headsetOverride')
    $baseline=@($props | ForEach-Object { ((& $adb -s $Serial shell getprop $_) -join '').Trim() })
    foreach($value in $baseline) { if($value -notmatch '^[0-9.]*$') { throw 'Unrecognized existing FoV values; no settings changed.' } }
    try {
        & $cli device fov-sim enable --device $Serial
        if($LASTEXITCODE -ne 0) { throw 'This headset does not support official device FoV simulation.' }
        $angles=@($props[0..3] | ForEach-Object { ((& $adb -s $Serial shell getprop $_) -join '').Trim() })
        foreach($angle in $angles) { if($angle -notmatch '^[0-9]+(\.[0-9]+)?$' -or [double]$angle -le 0 -or [double]$angle -gt 90) { throw 'Invalid official FoV profile.' } }
    } finally {
        for($i=0;$i -lt $props.Count;$i++) {
            & $adb -s $Serial shell "setprop $($props[$i]) '$($baseline[$i])'"
            if($LASTEXITCODE -ne 0) { throw 'Could not restore original FoV after setup. Reboot the headset.' }
        }
    }
    $configDir=Join-Path $root '.tools\device-control'
    # Match the SDK 207 Unity mask's asymmetric angular split. This is our
    # adjusted device profile, not the CLI's default 31/35 split on Quest 3.
    $angles=@('25','41','35','35')
    New-Item -ItemType Directory -Force $configDir | Out-Null
    $config=Join-Path $configDir 'bridge.config'
    [IO.File]::WriteAllText($config, (($key)+"`n"+($angles -join "`n")+"`n"),[Text.Encoding]::ASCII)
    # Replace only this exact helper process when upgrading its implementation.
    $processes = & $adb -s $Serial shell ps -A -o PID,ARGS
    foreach ($line in $processes) {
        if ($line -match '^\s*(\d+)\s+app_process /system/bin com\.glasseslab\.bridge\.FovServer /data/local/tmp/glasses-fov\.config\s*$') {
            & $adb -s $Serial shell kill $Matches[1]
            if ($LASTEXITCODE -ne 0) { throw 'Could not stop the previous FoV helper.' }
        }
    }
    & $adb -s $Serial push $dex /data/local/tmp/glasses-fov.dex
    if($LASTEXITCODE -ne 0) { throw 'Helper upload failed.' }
    & $adb -s $Serial push $config /data/local/tmp/glasses-fov.config
    if($LASTEXITCODE -ne 0) { throw 'Profile upload failed.' }
    & $adb -s $Serial shell chmod 600 /data/local/tmp/glasses-fov.config
    if($LASTEXITCODE -ne 0) { throw 'Could not restrict pairing key permissions.' }
    & $adb -s $Serial shell 'CLASSPATH=/data/local/tmp/glasses-fov.dex nohup app_process /system/bin com.glasseslab.bridge.FovServer /data/local/tmp/glasses-fov.config >/data/local/tmp/glasses-fov.log 2>&1 </dev/null &'
    if($LASTEXITCODE -ne 0) { throw 'Could not start device helper.' }
    $link=if($Serial -match ':') { 'Wireless' } else { 'USB' }
    Write-Host "$link setup sent. Open Glasses FoV Lab and check OTHER GAMES status." -ForegroundColor Green
    Write-Host 'Use the GLASSES VIEW switch on the app panel (laser + trigger). The display briefly sleeps and wakes automatically.'
    Write-Host 'You may disconnect the PC. Repeat this setup after headset reboot.'
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}


