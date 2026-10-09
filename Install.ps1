$ErrorActionPreference = 'Stop'
$installed = Join-Path $env:LOCALAPPDATA 'AIusagebar'
$files = @('AIusagebar.ps1', 'Run-Widget.ps1', 'Start AIusagebar.vbs', 'Start AIusagebar.cmd', 'Uninstall.ps1')
try {
    foreach ($name in $files) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) { throw "패키지 파일 누락: $name (압축을 먼저 풀어주세요)" } }
    $t = $null; $e = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'AIusagebar.ps1'), [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { throw '위젯 스크립트 문법 검사 실패' }

    # Close a running copy so its files can be replaced.
    & (Join-Path $PSScriptRoot 'Uninstall.ps1') -StopOnly
    if ($LASTEXITCODE) { exit 1 }

    New-Item -ItemType Directory -Path $installed -Force | Out-Null
    foreach ($name in $files) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $installed $name
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Unblock-File -LiteralPath $destination
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) { throw "복사 확인 실패: $name" }
    }

    $vbs = Join-Path $installed 'Start AIusagebar.vbs'
    $shell = New-Object -ComObject WScript.Shell
    $programs = [Environment]::GetFolderPath('Programs')
    $startup = [Environment]::GetFolderPath('Startup')

    $shortcut = $shell.CreateShortcut((Join-Path $programs 'AIusagebar.lnk'))
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $shortcut.Arguments = '"' + $vbs + '"'; $shortcut.WorkingDirectory = $installed; $shortcut.Description = 'Claude and ChatGPT usage'
    $shortcut.Save()

    $shortcut = $shell.CreateShortcut((Join-Path $startup 'AIusagebar.lnk'))
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $shortcut.Arguments = '/d /c ""' + (Join-Path $installed 'Start AIusagebar.cmd') + '""'
    $shortcut.WorkingDirectory = $installed; $shortcut.WindowStyle = 7; $shortcut.Description = 'Start AIusagebar at Windows sign-in'
    $shortcut.Save()

    # Run the uninstaller from Temp so it can delete the install folder.
    $shortcut = $shell.CreateShortcut((Join-Path $programs 'AIusagebar 제거.lnk'))
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installed 'Uninstall.ps1') + '"'
    $shortcut.WorkingDirectory = $env:TEMP; $shortcut.Description = 'Uninstall AIusagebar'
    $shortcut.Save()

    Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
    Write-Host 'AIusagebar 설치 완료. 작업 표시줄에 위젯이 나타납니다. (Windows 로그인 시 자동 실행)'

    $claudeRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    if (-not (Test-Path -LiteralPath (Join-Path $claudeRoot '.credentials.json'))) {
        Write-Host '참고: Claude Code 로그인 정보가 없습니다. Claude 줄을 쓰려면 Claude Code(데스크톱 앱 Code 탭 또는 CLI)에서 한 번 로그인하세요.'
    }
} catch {
    Write-Host ('설치 실패: ' + $_.Exception.Message)
    exit 1
}
