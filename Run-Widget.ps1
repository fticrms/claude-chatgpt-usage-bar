$ErrorActionPreference='Stop'
$log=Join-Path $env:TEMP 'AIusagebar.log'
function Write-Log([string]$Message) { [IO.File]::AppendAllText($log,([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')+' '+$Message+"`r`n")) }
function Get-ClaudeExpiry {
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $path = Join-Path $root '.credentials.json'
    if (-not (Test-Path -LiteralPath $path)) { return 0L }
    try { return [int64](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).claudeAiOauth.expiresAt } catch { return 0L }
}
function Test-ClaudeLoginFresh { return (Get-ClaudeExpiry) -gt [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds() }
function Update-ClaudeLogin {
    # The desktop app keeps its own login and never renews this file, so let the
    # bundled Claude Code CLI renew it before the widget reads it.
    if (Test-ClaudeLoginFresh) { return }
    $exe = Get-ChildItem (Join-Path $env:APPDATA 'Claude\claude-code') -Recurse -Depth 2 -Filter 'claude.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    # Fall back to a standalone Claude Code install (native installer puts claude.exe on PATH).
    if (-not $exe) { $cmd = Get-Command 'claude.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cmd) { $exe = Get-Item -LiteralPath $cmd.Source } }
    if (-not $exe) { Write-Log 'CLAUDE_PRELAUNCH_REFRESH no_cli'; return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $info = New-Object Diagnostics.ProcessStartInfo $exe.FullName, '-p ok --model haiku --max-turns 1'
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WorkingDirectory = $env:TEMP
        foreach ($name in @($info.EnvironmentVariables.Keys)) { if ($name -match '^(CLAUDE|ANTHROPIC)') { $info.EnvironmentVariables.Remove($name) } }
        $process = [Diagnostics.Process]::Start($info)
        if (-not $process.WaitForExit(60000)) { try { $process.Kill() } catch {} }
        if (Test-ClaudeLoginFresh) {
            [IO.File]::WriteAllText((Join-Path $env:TEMP 'AIusagebar-Claude-Retry.json'),'{"retryAfter":0,"failures":0}')
            Write-Log ('CLAUDE_PRELAUNCH_REFRESH ok attempt=' + $attempt)
            return
        }
        Write-Log ('CLAUDE_PRELAUNCH_REFRESH failed attempt=' + $attempt)
        # The network may still be coming up right after Windows sign-in.
        if ($attempt -lt 3) { Start-Sleep -Seconds 20 }
    }
}
try {
    Write-Log 'WIDGET_PROCESS_STARTED v1.2.9'
    try { Update-ClaudeLogin } catch { Write-Log ('CLAUDE_PRELAUNCH_REFRESH error ' + $_.Exception.GetType().Name) }
    & (Join-Path $PSScriptRoot 'AIusagebar.ps1')
} catch {
    $message=$_.Exception.GetType().Name+' at line '+$_.InvocationInfo.ScriptLineNumber
    Write-Log ('WIDGET_FATAL '+$message)
    exit 1
}
