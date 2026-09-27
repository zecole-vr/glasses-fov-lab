param(
    [ValidateSet('Menu','Enable','Disable','Check')][string]$Action = 'Menu',
    [string]$DeviceId
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $root '.tools\metavr'
$cli = Join-Path $toolDir 'metavr.exe'
try {
    Write-Host '  * Glasses FoV Lab *  made by zecole' -ForegroundColor Magenta
    Write-Host '  Other games / 다른 게임용 시야 설정'
    Write-Host '  Quest 3 / 3S / Pro · USB debugging required'
    Write-Host ''
    if ($Action -eq 'Menu') {
        Write-Host '  1  글래스 시야 적용 (70 x 66도)'
        Write-Host '  2  기본 퀘스트 시야 복원'
        Write-Host '  3  연결 확인'
        Write-Host '  0  종료'
        switch (Read-Host '선택') {
            '1' { $Action = 'Enable' }
            '2' { $Action = 'Disable' }
            '3' { $Action = 'Check' }
            '0' { exit 0 }
            default { throw '잘못된 선택입니다. 기기 설정을 변경하지 않았습니다.' }
        }
    }
    if (-not (Test-Path -LiteralPath $cli)) {
        Write-Host 'Meta 공식 CLI를 이 폴더에 다운로드합니다. 최초 한 번 인터넷이 필요합니다.'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $info = Invoke-RestMethod 'https://www.oculus.com/binary-info/26548836238067195/latest/'
        if ($info.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '공식 다운로드 검증 정보를 확인할 수 없습니다. 다시 실행해주세요.' }
        New-Item -ItemType Directory -Force $toolDir | Out-Null
        $archive = Join-Path $toolDir 'download.zip'
        Invoke-WebRequest 'https://www.oculus.com/download_app/?id=26548836238067195' -OutFile $archive -UseBasicParsing
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $info.sha256) {
            throw 'CLI 다운로드 해시가 일치하지 않습니다. 다운로드 파일을 실행하지 않습니다.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $toolDir -Force
        if (-not (Test-Path -LiteralPath $cli)) { throw '공식 압축 파일에서 metavr.exe를 찾지 못했습니다.' }
    }
    $errorLog = Join-Path $toolDir 'last-stderr.log'
    # Redirect native warnings to a log rather than mixing them into JSON.
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $json = & $cli device list --json 2> $errorLog
    $listCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    if ($listCode -ne 0) { throw "기기 목록 확인 실패. $errorLog" }
    $devices = @((($json -join "`n") | ConvertFrom-Json) | Where-Object { $_.state -eq 'device' -and $_.id -notmatch '[.:]' -and ($_.model -match 'Quest' -or $_.device -in @('eureka','panther','cambria','hollywood')) })
    if ($devices.Count -eq 0) { throw 'Quest를 USB로 연결하고, 헤드셋 안에서 USB 디버깅을 허용한 뒤 다시 실행해주세요.' }
    Write-Host (($devices | Select-Object id, model | Format-Table -AutoSize | Out-String).Trim())
    # Always select explicitly; never silently use a CLI global default device.
    $ids = @($devices | ForEach-Object {
        if ($_.id) { [string]$_.id }
        elseif ($_.serial) { [string]$_.serial }
        elseif ($_.device_id) { [string]$_.device_id }
        else { throw '알 수 없는 CLI 기기 목록 형식입니다. 기기 설정을 변경하지 않았습니다.' }
    })
    if (-not $DeviceId) {
        if ($ids.Count -eq 1) { $DeviceId = $ids[0] }
        else {
            for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host ("{0}. {1}" -f ($i + 1), $ids[$i]) }
            $index = 0
            if (-not [int]::TryParse((Read-Host '기기 번호'), [ref]$index) -or $index -lt 1 -or $index -gt $ids.Count) { throw '잘못된 기기 번호입니다.' }
            $DeviceId = $ids[$index - 1]
        }
    }
    if ($DeviceId -notin $ids) { throw '선택한 기기가 연결 목록에 없습니다.' }
    if ($Action -eq 'Check') { Write-Host '연결 확인 완료. 시야 설정은 변경하지 않았습니다.' -ForegroundColor Green; exit 0 }
    $command = if ($Action -eq 'Enable') { 'enable' } else { 'disable' }
    $ErrorActionPreference = 'Continue'
    & $cli device fov-sim $command --device $DeviceId 2> $errorLog
    $result = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($result -ne 0) { Get-Content $errorLog; throw '시야 설정 실패. 현재 기기/OS에서 지원되는지 확인해주세요.' }
    if ($Action -eq 'Enable') {
        Write-Host '적용 명령이 완료됐습니다. 체험 앱을 종료하고 원하는 게임을 실행하세요.' -ForegroundColor Green
        Write-Host '컨트롤러 입력을 가로채거나 게임 위에 조작 UI를 띄우지 않습니다.'
    } else {
        Write-Host '기본 시야 복원 명령이 완료됐습니다.' -ForegroundColor Green
    }
    Write-Host '기기 안에서 결과를 확인하세요. 즉시 반영되지 않으면 게임을 다시 실행하거나 절전 후 깨워주세요.'
    Write-Host 'Restore-Quest-FoV.cmd로 해제할 수 있습니다. 헤드셋을 재부팅해도 초기화됩니다.'
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
