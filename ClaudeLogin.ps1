param([switch]$LibraryOnly, [switch]$Force)
# Finds the Claude Code CLI, renews the Claude login, and opens a sign-in window when
# a new sign-in is needed. Dot-source with -LibraryOnly to use the functions only.
# Exit codes: 10 = login is now valid, 0 = nothing changed, 1 = error, 2 = no CLI found.
$ErrorActionPreference = 'Stop'

function Write-LoginLog([string]$Message) {
    try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'AIusagebar.log'), ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Message + "`r`n")) } catch {}
}
function Get-ClaudeCredentialFile {
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    return Join-Path $root '.credentials.json'
}
function Get-ClaudeOauth {
    $path = Get-ClaudeCredentialFile
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).claudeAiOauth } catch { return $null }
}
function Test-ClaudeLoginFresh {
    $oauth = Get-ClaudeOauth
    if (-not $oauth -or [string]::IsNullOrWhiteSpace($oauth.accessToken) -or -not $oauth.expiresAt) { return $false }
    return [int64]$oauth.expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds()
}
function Test-ClaudeCanRefresh {
    # False when only a new sign-in can help (no refresh token, or it has expired).
    $oauth = Get-ClaudeOauth
    if (-not $oauth -or [string]::IsNullOrWhiteSpace($oauth.refreshToken)) { return $false }
    if ($oauth.refreshTokenExpiresAt -and [int64]$oauth.refreshTokenExpiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return $false }
    return $true
}
function Find-ClaudeCli {
    # The desktop app (Store install, then older installer) and the VS Code extension
    # each carry a claude.exe; take the newest one.
    $patterns = @(
        (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code\*\*\claude.exe'),
        (Join-Path $env:APPDATA 'Claude\claude-code\*\*\claude.exe'),
        (Join-Path $env:USERPROFILE '.vscode\extensions\anthropic.claude-code-*\resources\native-binary\claude.exe')
    )
    $found = @()
    foreach ($pattern in $patterns) { $found += @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue) }
    $cmd = Get-Command 'claude.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $found += Get-Item -LiteralPath $cmd.Source }
    return $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function New-ClaudeStartInfo([string]$File, [string]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WorkingDirectory = $env:TEMP
    # A session started from the desktop app leaves variables that confuse a standalone CLI run.
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -match '^(CLAUDE|ANTHROPIC)' -and $name -ne 'CLAUDE_CONFIG_DIR') { $info.EnvironmentVariables.Remove($name) }
    }
    return $info
}
function Invoke-ClaudeCli([string]$Exe, [string]$Arguments, [int]$TimeoutSeconds = 60) {
    $info = New-ClaudeStartInfo $Exe $Arguments
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch {}; return @{ ExitCode = -1; Output = '' } }
    return @{ ExitCode = $process.ExitCode; Output = $out.Result }
}
function Invoke-ClaudeCliRefresh([string]$Exe) {
    # One tiny request makes the CLI renew the login file itself.
    Invoke-ClaudeCli $Exe '-p ok --model haiku --max-turns 1' 60 | Out-Null
    return (Test-ClaudeLoginFresh)
}
function Reset-ClaudeRetryFile {
    try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'AIusagebar-Claude-Retry.json'), '{"retryAfter":0,"failures":0}') } catch {}
}

if ($LibraryOnly) { return }

$statePath = Join-Path $env:TEMP 'AIusagebar-Claude-Login.json'
try {
    $exe = Find-ClaudeCli
    if (-not $exe) { Write-LoginLog 'CLAUDE_LOGIN_HELPER no_cli'; exit 2 }
    $running = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '(?i)\sauth\s+login' }
    if ($running) { Write-LoginLog 'CLAUDE_LOGIN_HELPER already_running'; exit 0 }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $Force -and (Test-Path -LiteralPath $statePath)) {
        try { $last = [int64](Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).lastAttempt } catch { $last = 0 }
        # Do not nag: automatic attempts are at least 30 minutes apart.
        if ($now - $last -lt 1800) { Write-LoginLog 'CLAUDE_LOGIN_HELPER throttled'; exit 0 }
    }
    [IO.File]::WriteAllText($statePath, (@{ lastAttempt = $now } | ConvertTo-Json -Compress))

    $status = (Invoke-ClaudeCli $exe.FullName 'auth status' 30).Output
    try { $loggedIn = [bool]($status | ConvertFrom-Json).loggedIn } catch { Write-LoginLog 'CLAUDE_LOGIN_HELPER status_unknown'; exit 0 }
    if ($loggedIn) {
        if (Invoke-ClaudeCliRefresh $exe.FullName) { Reset-ClaudeRetryFile; Write-LoginLog 'CLAUDE_LOGIN_HELPER refreshed'; exit 10 }
        Write-LoginLog 'CLAUDE_LOGIN_HELPER refresh_failed'
    }

    # Open the sign-in in its own visible console window; the CLI opens the browser.
    Write-LoginLog 'CLAUDE_LOGIN_HELPER prompt'
    $cmd = Join-Path $env:WINDIR 'System32\cmd.exe'
    $info = New-ClaudeStartInfo $cmd ('/c start "Claude sign-in" /wait "' + $exe.FullName + '" auth login --claudeai')
    $window = [Diagnostics.Process]::Start($info)
    $window.WaitForExit(15 * 60 * 1000) | Out-Null
    if (Test-ClaudeLoginFresh) { Reset-ClaudeRetryFile; Write-LoginLog 'CLAUDE_LOGIN_HELPER login_ok'; exit 10 }
    Write-LoginLog 'CLAUDE_LOGIN_HELPER login_incomplete'
    exit 0
} catch {
    Write-LoginLog ('CLAUDE_LOGIN_HELPER error ' + $_.Exception.GetType().Name)
    exit 1
}
