$ErrorActionPreference='Stop'
$log=Join-Path $env:TEMP 'AIusagebar.log'
function Write-Log([string]$Message) { [IO.File]::AppendAllText($log,([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')+' '+$Message+"`r`n")) }
function Update-ClaudeLogin {
    # The desktop app keeps its own login and never renews the login file, so let the
    # Claude Code CLI renew it before the widget reads it. A new sign-in, when one is
    # needed, is requested by the widget itself so startup is never held up.
    . (Join-Path $PSScriptRoot 'ClaudeLogin.ps1') -LibraryOnly
    if (Test-ClaudeLoginFresh) { return }
    if (-not (Test-ClaudeCanRefresh)) { Write-Log 'CLAUDE_PRELAUNCH_REFRESH needs_login'; return }
    $exe = Find-ClaudeCli
    if (-not $exe) { Write-Log 'CLAUDE_PRELAUNCH_REFRESH no_cli'; return }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Invoke-ClaudeCliRefresh $exe.FullName) {
            Reset-ClaudeRetryFile
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
