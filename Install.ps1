$ErrorActionPreference = 'Stop'
$installed = Join-Path $env:LOCALAPPDATA 'AIusagebar'
$files = @('AIusagebar.ps1', 'Run-Widget.ps1', 'Start AIusagebar.vbs', 'Start AIusagebar.cmd', 'Uninstall.ps1')
try {
    foreach ($name in $files) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) { throw "Missing package file: $name (unzip the package first)" } }
    $t = $null; $e = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'AIusagebar.ps1'), [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { throw 'Widget script syntax check failed.' }

    # Close a running copy so its files can be replaced.
    & (Join-Path $PSScriptRoot 'Uninstall.ps1') -StopOnly
    if ($LASTEXITCODE) { exit 1 }

    New-Item -ItemType Directory -Path $installed -Force | Out-Null
    foreach ($name in $files) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $installed $name
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Unblock-File -LiteralPath $destination
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) { throw "Copy verification failed: $name" }
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
    $shortcut = $shell.CreateShortcut((Join-Path $programs 'Uninstall AIusagebar.lnk'))
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installed 'Uninstall.ps1') + '"'
    $shortcut.WorkingDirectory = $env:TEMP; $shortcut.Description = 'Uninstall AIusagebar'
    $shortcut.Save()

    Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"')
    Write-Host 'AIusagebar installed. The widget will appear on your taskbar and start automatically at Windows sign-in.'

    $claudeRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    if (-not (Test-Path -LiteralPath (Join-Path $claudeRoot '.credentials.json'))) {
        Write-Host 'Note: no Claude Code login found. To use the Claude row, sign in once in Claude Code (desktop app Code tab or CLI).'
    }
} catch {
    Write-Host ('Install failed: ' + $_.Exception.Message)
    exit 1
}
