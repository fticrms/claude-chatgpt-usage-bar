param([switch]$SmokeTest, [string]$SmokeImagePath)
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct CodexBarRect { public int Left, Top, Right, Bottom; }
public static class CodexBarNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out CodexBarRect rect);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@

[CodexBarNative]::SetProcessDPIAware() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::ThrowException)

$script:version = "1.2.9"
$script:mutex = [System.Threading.Mutex]::new($false, $(if($SmokeTest){"Local\AIusagebar-Verification"}else{"Local\AIusagebar"}))
$created = $false
try { $created = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $created = $true }
if (-not $created) { try { [IO.File]::AppendAllText((Join-Path $env:TEMP "AIusagebar.log"), ([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss") + " WIDGET_MUTEX_BUSY`r`n")) } catch {}; $script:mutex.Dispose(); exit 0 }

$script:server = $null
$script:requestId = 0
$script:refreshing = $false
$script:offsetX = 12
$script:refreshSeconds = 300
$script:lastTip = ""
$script:logPath = Join-Path $env:TEMP "AIusagebar.log"
$script:configDir = Join-Path $env:USERPROFILE ".ai-usage-bar"
$script:configPath = Join-Path $script:configDir "config.json"

$CodexBase = [System.Drawing.Color]::FromArgb(20, 25, 34)
$CodexSurface = [System.Drawing.Color]::FromArgb(47, 52, 65)
$CodexText = [System.Drawing.Color]::White
$CodexMuted = [System.Drawing.Color]::FromArgb(145, 153, 172)
$CodexBlue = [System.Drawing.Color]::FromArgb(76, 201, 240)
$CodexAmber = [System.Drawing.Color]::FromArgb(255, 190, 74)
$CodexRed = [System.Drawing.Color]::FromArgb(255, 82, 82)

function Get-UsageColor([double]$Percent) {
    if ($Percent -ge 90) { return $CodexRed }
    if ($Percent -ge 70) { return $CodexAmber }
    return $CodexBlue
}

function Get-TaskbarRect {
    $hwnd = [CodexBarNative]::FindWindow("Shell_TrayWnd", $null)
    $rect = New-Object CodexBarRect
    if ($hwnd -ne [IntPtr]::Zero -and [CodexBarNative]::GetWindowRect($hwnd, [ref]$rect)) { return $rect }
    return $null
}

function Get-DefaultOffset { return 12 }

function Load-Config {
    try {
        if (Test-Path -LiteralPath $script:configPath) {
            $saved = Get-Content -Raw -LiteralPath $script:configPath | ConvertFrom-Json
            if ($null -ne $saved.offsetX) { $script:offsetX = [int]$saved.offsetX }
            if ($null -ne $saved.refreshSeconds) { $script:refreshSeconds = [Math]::Max(60, [int]$saved.refreshSeconds) }
        } else { $script:offsetX = Get-DefaultOffset }
    } catch { $script:offsetX = Get-DefaultOffset }
}

function Save-Config {
    try {
        if (-not (Test-Path -LiteralPath $script:configDir)) { New-Item -ItemType Directory -Path $script:configDir -Force | Out-Null }
        [ordered]@{ offsetX = $script:offsetX; refreshSeconds = $script:refreshSeconds } |
            ConvertTo-Json | Set-Content -LiteralPath $script:configPath -Encoding utf8
    } catch {}
}

function Find-CodexExecutable {
    foreach ($name in @("codex.exe", "codex.cmd", "codex")) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
    }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"),
        (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin")
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $direct = Join-Path $root "codex.exe"
        if (Test-Path -LiteralPath $direct) { return $direct }
        $candidate = Get-ChildItem -LiteralPath $root -Filter "codex.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $candidate) { return $candidate.FullName }
    }
    throw "CODEX_NOT_FOUND"
}

function Stop-AppServer {
    if ($null -ne $script:server) {
        try { if (-not $script:server.HasExited) { $script:server.Kill(); $script:server.WaitForExit(1000) | Out-Null } } catch {}
        try { $script:server.Dispose() } catch {}
        $script:server = $null
    }
}

function Send-AppRequest([string]$Method, [object]$Params, [switch]$NoParams) {
    $script:requestId++
    $request = [ordered]@{ id = $script:requestId; method = $Method }
    if (-not $NoParams) { $request.params = $Params }
    $script:server.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress))
    $script:server.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($true) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'App Server response timeout' }
        $read = $script:server.StandardOutput.ReadLineAsync()
        if (-not $read.Wait(10000)) { throw "App Server response timeout" }
        $line = $read.Result
        if ([string]::IsNullOrWhiteSpace($line)) { throw "App Server closed the stream" }
        $response = $line | ConvertFrom-Json
        if ($response.id -eq $script:requestId) {
            if ($null -ne $response.error) { throw (($response.error | ConvertTo-Json -Compress)) }
            return $response.result
        }
    }
}

function Start-AppServer {
    Stop-AppServer
    $exe = Find-CodexExecutable
    $info = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -match '\.cmd$') {
        # npm installs a .cmd shim, which has to go through cmd.exe.
        $info.FileName = $env:ComSpec
        $info.Arguments = "/d /c `"`"$exe`" app-server --stdio`""
    } else {
        $info.FileName = $exe
        $info.Arguments = "app-server --stdio"
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $script:server = New-Object System.Diagnostics.Process
    $script:server.StartInfo = $info
    if (-not $script:server.Start()) { throw "Could not start App Server" }
    # Nobody reads stderr; drain it so a chatty server cannot block on a full pipe.
    $script:server.BeginErrorReadLine()
    $init = @{ clientInfo = @{ name = "ai-usage-bar"; title = "AIusagebar"; version = $script:version } }
    Send-AppRequest "initialize" $init | Out-Null
    $script:server.StandardInput.WriteLine('{"method":"initialized","params":{}}')
    $script:server.StandardInput.Flush()
}

function Get-RateLimits {
    if ($null -eq $script:server -or $script:server.HasExited) { Start-AppServer }
    Send-AppRequest "account/rateLimits/read" $null -NoParams
}

function Get-WeeklyWindow($Limits) {
    foreach ($window in @($Limits.primary, $Limits.secondary)) {
        if ($null -ne $window -and $window.windowDurationMins -eq 10080) { return $window }
    }
    return $null
}

function Format-Reset($UnixSeconds) {
    if ($null -eq $UnixSeconds) { return "--/-- --:--" }
    return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).LocalDateTime).ToString("MM/dd HH:mm")
}

Load-Config
$taskbarRect = Get-TaskbarRect
if ($null -eq $taskbarRect -and $SmokeTest) { $script:smokeRect = [pscustomobject]@{Left=0;Right=1920;Top=0;Bottom=48}; $taskbarRect=$script:smokeRect; function Get-TaskbarRect { return $script:smokeRect }; Write-Output "SIMULATED_TASKBAR: sandbox desktop cannot inspect the real taskbar" }; if ($null -eq $taskbarRect) { [System.Windows.Forms.MessageBox]::Show("Taskbar not found.", "AIusagebar") | Out-Null; exit 1 }
$barHeight = [Math]::Max(34, ($taskbarRect.Bottom - $taskbarRect.Top) - 8)
$barWidth = 335
$labelX = 8; $labelW = 62; $gaugeX = 76; $gaugeH = 7
$percentW = 90; $resetW = 84; $rightMargin = 10
$gaugeW = $barWidth - $gaugeX - 6 - $percentW - 8 - $resetW - $rightMargin
$percentX = $gaugeX + $gaugeW + 6; $resetX = $percentX + $percentW + 8

$form = New-Object System.Windows.Forms.Form
$form.Text = "AIusagebar"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false; $form.TopMost = $true; $form.BackColor = $CodexBase
$form.ClientSize = New-Object System.Drawing.Size($barWidth, $barHeight)
$form.Region = [System.Drawing.Region]::FromHrgn([CodexBarNative]::CreateRoundRectRgn(0, 0, $form.Width, $form.Height, 12, 12))
$rowHeight = [int][Math]::Floor(($barHeight - 4) / 2); $row1Y = 2; $row2Y = 2 + $rowHeight

function New-CodexRow([string]$Name, [int]$Y) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Name; $label.ForeColor = $CodexText; $label.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $label.AutoSize = $false; $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.Location = New-Object System.Drawing.Point($labelX, $Y); $label.Size = New-Object System.Drawing.Size($labelW, $rowHeight); $form.Controls.Add($label)
    $track = New-Object System.Windows.Forms.Panel
    $track.BackColor = $CodexSurface; $track.Location = New-Object System.Drawing.Point($gaugeX, ($Y + [int](($rowHeight - $gaugeH) / 2))); $track.Size = New-Object System.Drawing.Size($gaugeW, $gaugeH); $form.Controls.Add($track)
    $fill = New-Object System.Windows.Forms.Panel
    $fill.BackColor = $CodexBlue; $fill.Location = New-Object System.Drawing.Point(0, 0); $fill.Size = New-Object System.Drawing.Size(0, $gaugeH); $track.Controls.Add($fill)
    $percent = New-Object System.Windows.Forms.Label
    $percent.Text = "--% used / 7d"; $percent.ForeColor = $CodexMuted; $percent.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9); $percent.AutoSize = $false; $percent.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $percent.Location = New-Object System.Drawing.Point($percentX, $Y); $percent.Size = New-Object System.Drawing.Size($percentW, $rowHeight); $form.Controls.Add($percent)
    $reset = New-Object System.Windows.Forms.Label
    $reset.Text = "--/-- --:--"; $reset.ForeColor = $CodexMuted; $reset.Font = New-Object System.Drawing.Font("Segoe UI", 8); $reset.AutoSize = $false; $reset.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $reset.Location = New-Object System.Drawing.Point($resetX, $Y); $reset.Size = New-Object System.Drawing.Size($resetW, $rowHeight); $form.Controls.Add($reset)
    return @{ Label=$label; Track=$track; Fill=$fill; Percent=$percent; Reset=$reset }
}

$rowSeven = New-CodexRow "ChatGPT" $row1Y
$rowClaude = New-CodexRow "Claude" $row2Y
$allRows = @($rowSeven, $rowClaude)
$rowSeven.BrandColor = [System.Drawing.Color]::FromArgb(245,245,245)
$rowClaude.BrandColor = [System.Drawing.ColorTranslator]::FromHtml("#D97757")
foreach ($row in $allRows) { $row.Label.ForeColor = $row.BrandColor; $row.Fill.BackColor = $row.BrandColor }

$tooltip = New-Object System.Windows.Forms.ToolTip; $tooltip.AutoPopDelay = 12000; $tooltip.InitialDelay = 300
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$refreshItem = $menu.Items.Add("Refresh now"); $detailsItem = $menu.Items.Add("Details"); $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null; $exitItem = $menu.Items.Add("Exit")
$form.ContextMenuStrip = $menu

function Update-BarLayout($Rect) {
    if ($null -eq $Rect) { return }
    $taskHeight = $Rect.Bottom - $Rect.Top
    $graphics = $form.CreateGraphics()
    try { $scale = $graphics.DpiX / 96.0 } finally { $graphics.Dispose() }
    $height = [Math]::Max(2, $taskHeight - [int][Math]::Round(4 * $scale))
    # Re-layout when the reset column text changes so its width tracks the content.
    $resetKey = ($allRows | ForEach-Object { $_.Reset.Text }) -join '|'
    if ($script:lastLayoutHeight -eq $height -and $script:lastLayoutScale -eq $scale -and $script:lastLayoutResetKey -eq $resetKey) { return }
    $script:lastLayoutHeight = $height; $script:lastLayoutScale = $scale; $script:lastLayoutResetKey = $resetKey
    $padding = [Math]::Max(1, [int][Math]::Round(2 * $scale))
    $rowH = [Math]::Max(1, [int][Math]::Floor(($height - 2 * $padding) / 2))
    # Use pixel fonts and actual text measurements, including label padding.
    $fontPx = [Math]::Max(1, [Math]::Min(12 * $scale, $rowH - 4 * $scale))
    $font = [Drawing.Font]::new('Segoe UI Semibold', [single]$fontPx, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $small = [Drawing.Font]::new('Segoe UI', [single]([Math]::Max(1,$fontPx-1)), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $oldFonts = @($allRows[0].Label.Font, $allRows[0].Percent.Font, $allRows[0].Reset.Font, $allRows[1].Label.Font, $allRows[1].Percent.Font, $allRows[1].Reset.Font)
    $gap = [Math]::Max(2, [int][Math]::Round(6 * $scale))
    $nameW = [Windows.Forms.TextRenderer]::MeasureText('ChatGPT', $font).Width + 4
    $pctW = [Windows.Forms.TextRenderer]::MeasureText('100% used / 7d', $font).Width + 4
    # Size the reset column to the date, widening only while a longer message is shown.
    $dateW = [Windows.Forms.TextRenderer]::MeasureText('12/31 23:59', $small).Width
    foreach ($r in $allRows) { $dateW = [Math]::Max($dateW, [Windows.Forms.TextRenderer]::MeasureText([string]$r.Reset.Text, $small).Width) }
    $dateW += 2
    $gaugeWidth = [int][Math]::Round(48 * $scale)
    $gaugeHeight = [Math]::Max(1, [Math]::Min([int][Math]::Round(6 * $scale), $rowH - 2))
    $width = $nameW + $pctW + $dateW + $gaugeWidth + 4 * $gap + $padding
    $form.ClientSize = [Drawing.Size]::new($width, $height)
    for ($i=0; $i -lt $allRows.Count; $i++) {
        $row = $allRows[$i]; $y = $padding + $i * $rowH
        $row.Label.Font = $font; $row.Percent.Font = $font; $row.Reset.Font = $small
        $row.Label.SetBounds($gap,$y,$nameW,$rowH)
        $row.Track.SetBounds((2*$gap+$nameW),($y+[int](($rowH-$gaugeHeight)/2)),$gaugeWidth,$gaugeHeight)
        $row.Fill.Height = $gaugeHeight
        $row.Percent.SetBounds((3*$gap+$nameW+$gaugeWidth),$y,$pctW,$rowH)
        $row.Reset.SetBounds((4*$gap+$nameW+$gaugeWidth+$pctW),$y,$dateW,$rowH)
        $used = 0.0
        if ($row.Percent.Text -match '^(\d+)%') { $used = [double]$Matches[1] }
        $row.Fill.Width = [int][Math]::Round($gaugeWidth * $used / 100)
    }
    # Remove the fixed rounded clipping region after resizing.
    $oldRegion = $form.Region; $form.Region = $null
    if ($oldRegion) { $oldRegion.Dispose() }
    foreach ($oldFont in $oldFonts | Select-Object -Unique) { if ($oldFont -ne $font -and $oldFont -ne $small) { $oldFont.Dispose() } }
}
function Set-BarPosition {
    $rect = Get-TaskbarRect
    if ($null -eq $rect) { return }
    Update-BarLayout $rect
    $h = $rect.Bottom - $rect.Top
    $top = $rect.Top + [Math]::Max(0, [int](($h - $form.ClientSize.Height) / 2))
    # Keep the strip on screen if the saved offset came from a wider display.
    $maxX = [Math]::Max(0, ($rect.Right - $rect.Left) - $form.Width)
    $x = [Math]::Min([Math]::Max(0, $script:offsetX), $maxX)
    $form.Location = New-Object System.Drawing.Point($x, $top)
}
function Assert-TopMost { [CodexBarNative]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null }

function Test-FullscreenForeground {
    # Step aside while a game or full-screen video is in front.
    $fg = [CodexBarNative]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero -or $fg -eq $form.Handle) { return $false }
    $rect = New-Object CodexBarRect
    if (-not [CodexBarNative]::GetWindowRect($fg, [ref]$rect)) { return $false }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    return (($rect.Right - $rect.Left) -ge $screen.Width -and ($rect.Bottom - $rect.Top) -ge $screen.Height)
}

function Set-BarRow($Row, $Window) {
    if ($null -eq $Window) { $Row.Percent.Text = "--% used / 7d"; $Row.Percent.ForeColor = $CodexMuted; $Row.Fill.Width = 0; $Row.Reset.Text = "--/-- --:--"; $Row.Reset.ForeColor = $CodexMuted; return }
    $used = [Math]::Max(0, [Math]::Min(100, [double]$Window.usedPercent))
    $color = $Row.BrandColor
    $Row.Percent.Text = ("{0}% used / 7d" -f [int][Math]::Round($used)); $Row.Percent.ForeColor = $color; $Row.Fill.BackColor = $color; $Row.Fill.Width = [int][Math]::Round($Row.Track.ClientSize.Width * $used / 100); $Row.Reset.Text = Format-Reset $Window.resetsAt; $Row.Reset.ForeColor = $color
}

function Show-Message([string]$Text, $Color) {
    # The strip has no spare row, so problems are spelled out in the reset
    # column where they cannot be missed.
    $rowSeven.Reset.Text = $Text; $rowSeven.Reset.ForeColor = $Color
}

function Convert-ClaudeWeeklyWindow($Usage) {
    $weekly = $Usage.seven_day
    if ($null -eq $weekly -or $null -eq $weekly.utilization) { return $null }
    $reset = $null
    if ($weekly.resets_at) { $reset = ([DateTimeOffset]::Parse([string]$weekly.resets_at)).ToUnixTimeSeconds() }
    return @{usedPercent=[double]$weekly.utilization; resetsAt=$reset; windowDurationMins=10080}
}
function Get-ClaudeRetryPath { return Join-Path $env:TEMP 'AIusagebar-Claude-Retry.json' }
function Get-ClaudeRetryState {
    $state = @{retryAfter=0L; failures=0}
    try {
        if (Test-Path -LiteralPath (Get-ClaudeRetryPath)) {
            $saved = Get-Content -LiteralPath (Get-ClaudeRetryPath) -Raw | ConvertFrom-Json
            $state.retryAfter = [Math]::Max(0L, [int64]$saved.retryAfter)
            $state.failures = [Math]::Max(0, [Math]::Min(5, [int]$saved.failures))
        }
    } catch {}
    if ($script:claudeRetryUntil -gt $state.retryAfter) { $state.retryAfter = $script:claudeRetryUntil }
    if ($script:claudeRetryFailures -gt $state.failures) { $state.failures = $script:claudeRetryFailures }
    return $state
}
function Get-ClaudeRetrySeconds {
    return [Math]::Max(0L, ((Get-ClaudeRetryState).retryAfter - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
}
function Get-ClaudeRetryMessage {
    $remaining = Get-ClaudeRetrySeconds
    if ($remaining -gt 0) { return ('wait {0}m' -f [int][Math]::Ceiling($remaining / 60.0)) }
    return 'retry pending'
}
function Assert-ClaudeRetryAllowed {
    if ((Get-ClaudeRetrySeconds) -gt 0) { throw 'CLAUDE_RATE_LIMIT' }
}
function Set-ClaudeRetryDelay($Response) {
    $state = Get-ClaudeRetryState
    $failures = [Math]::Min(5, $state.failures + 1)
    $seconds = [int][Math]::Min(600, (60 * [Math]::Pow(2, $failures - 1)))
    try {
        $header = [string]$Response.Headers['Retry-After']
        $parsed = 0
        $date = [DateTimeOffset]::MinValue
        if ([int]::TryParse($header,[ref]$parsed)) { $seconds = [Math]::Max($seconds,$parsed) }
        elseif ([DateTimeOffset]::TryParse($header,[ref]$date)) { $seconds = [Math]::Max($seconds,[int][Math]::Ceiling(($date-[DateTimeOffset]::UtcNow).TotalSeconds)) }
    } catch {}
    $script:claudeRetryUntil = [Math]::Max($state.retryAfter, ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $seconds))
    $script:claudeRetryFailures = $failures
    try { [IO.File]::WriteAllText((Get-ClaudeRetryPath), (@{retryAfter=$script:claudeRetryUntil;failures=$failures} | ConvertTo-Json -Compress)) } catch {}
    Write-UsageStatus ('CLAUDE_COOLDOWN seconds=' + $seconds + ' failures=' + $failures)
}
function Reset-ClaudeRetryDelay {
    $script:claudeRetryUntil = 0L
    $script:claudeRetryFailures = 0
    try { [IO.File]::WriteAllText((Get-ClaudeRetryPath), '{"retryAfter":0,"failures":0}') } catch {}
}
function Get-ClaudeCredentialPath {
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    return Join-Path $root '.credentials.json'
}
function Read-ClaudeCredentials([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw 'CLAUDE_LOGIN' }
    try { $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw 'CLAUDE_LOGIN' }
    if ([string]::IsNullOrWhiteSpace($data.claudeAiOauth.accessToken)) { throw 'CLAUDE_LOGIN' }
    return $data
}
function Write-ClaudeFailure([string]$Stage, $Failure) {
    $exception = $Failure.Exception
    $status = 'none'
    if ($null -ne $exception.Response) { $status = [string][int]$exception.Response.StatusCode }
    $transport = if ($exception -is [Net.WebException]) { [string]$exception.Status } else { $exception.GetType().Name }
    Write-UsageStatus ('CLAUDE_HTTP_FAILURE stage=' + $Stage + ' http=' + $status + ' transport=' + $transport)
    if ($status -eq '429') {
        $retryHeader = [string]$exception.Response.Headers['Retry-After']
        $seconds = 0L
        $date = [DateTimeOffset]::MinValue
        if ([int64]::TryParse($retryHeader,[ref]$seconds)) { Write-UsageStatus ('CLAUDE_SERVER_RETRY seconds=' + $seconds) }
        elseif ([DateTimeOffset]::TryParse($retryHeader,[ref]$date)) { Write-UsageStatus ('CLAUDE_SERVER_RETRY until=' + $date.ToString('o')) }
        else { Write-UsageStatus 'CLAUDE_SERVER_RETRY unspecified' }
    }
}
function Get-ClaudeAccessToken([switch]$Force, [string]$RejectedToken) {
    $path = Get-ClaudeCredentialPath
    $lock = [Threading.Mutex]::new($false, 'Local\AIusagebar-ClaudeRefresh')
    $locked = $false
    $temp = $null
    try {
        try { $locked = $lock.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'CLAUDE_CONNECTION' }
        $data = Read-ClaudeCredentials $path
        $oauth = $data.claudeAiOauth
        if ($Force -and $RejectedToken -and $oauth.accessToken -ne $RejectedToken) { return $oauth.accessToken }
        $nearExpiry = $null -ne $oauth.expiresAt -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000 -ge [int64]$oauth.expiresAt
        if (-not $Force -and -not $nearExpiry) { return $oauth.accessToken }
        Assert-ClaudeRetryAllowed
        if ([string]::IsNullOrWhiteSpace($oauth.refreshToken)) { throw 'CLAUDE_LOGIN' }
        if ($oauth.refreshTokenExpiresAt -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge [int64]$oauth.refreshTokenExpiresAt) { throw 'CLAUDE_LOGIN' }
        $oldRefresh = $oauth.refreshToken
        $oldAccess = $oauth.accessToken
        # Match the installed Claude Code OAuth client. Never print credentials.
        $body = @{ grant_type = 'refresh_token'; refresh_token = $oldRefresh; client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e' }
        if ($oauth.scopes.Count -gt 0) { $body.scope = $oauth.scopes -join ' ' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            # Identify this client explicitly rather than PowerShell's default browser UA.
            $reply = Invoke-RestMethod -Method Post -Uri 'https://platform.claude.com/v1/oauth/token' -UserAgent 'AIusagebar/1.2.9' -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 15
        } catch {
            Write-ClaudeFailure 'refresh' $_
            $latest = Read-ClaudeCredentials $path
            if ($latest.claudeAiOauth.accessToken -ne $oldAccess) { return $latest.claudeAiOauth.accessToken }
            if ($null -ne $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                if ($status -in @(400,401,403)) { throw 'CLAUDE_LOGIN' }
                if ($status -eq 429) { Set-ClaudeRetryDelay $_.Exception.Response; throw 'CLAUDE_RATE_LIMIT' }
            }
            throw 'CLAUDE_CONNECTION'
        }
        if ([string]::IsNullOrWhiteSpace($reply.access_token) -or [double]$reply.expires_in -le 0) { throw 'CLAUDE_CONNECTION' }
        # Preserve unrelated settings and a newer login written by Claude Code.
        $data = Read-ClaudeCredentials $path
        if ($data.claudeAiOauth.refreshToken -ne $oldRefresh -or $data.claudeAiOauth.accessToken -ne $oldAccess) { return $data.claudeAiOauth.accessToken }
        $oauth = $data.claudeAiOauth
        $oauth | Add-Member -NotePropertyName accessToken -NotePropertyValue $reply.access_token -Force
        $oauth | Add-Member -NotePropertyName expiresAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [int64]([double]$reply.expires_in * 1000)) -Force
        if ($reply.refresh_token) { $oauth | Add-Member -NotePropertyName refreshToken -NotePropertyValue $reply.refresh_token -Force }
        if ($reply.scope) { $oauth | Add-Member -NotePropertyName scopes -NotePropertyValue @($reply.scope -split ' ') -Force }
        if ($null -ne $reply.refresh_token_expires_in) { $oauth | Add-Member -NotePropertyName refreshTokenExpiresAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [int64]([double]$reply.refresh_token_expires_in * 1000)) -Force }
        $temp = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temp, ($data | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
            # Match the original access rules before atomic replacement.
            $acl = [IO.File]::GetAccessControl($path)
            $tempAcl = [IO.File]::GetAccessControl($temp)
            $section = [Security.AccessControl.AccessControlSections]::Access
            if ($acl.GetSecurityDescriptorSddlForm($section) -ne $tempAcl.GetSecurityDescriptorSddlForm($section)) { [IO.File]::SetAccessControl($temp, $acl) }
            [IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value, $true)
            $temp = $null
        } catch { throw 'CLAUDE_CREDENTIAL_WRITE' }
        return $reply.access_token
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($locked) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}
function Get-ClaudeWeeklyUsage {
    Assert-ClaudeRetryAllowed
    $token = Get-ClaudeAccessToken
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $usage = Invoke-RestMethod -Method Get -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers @{Authorization=('Bearer '+$token);'anthropic-beta'='oauth-2025-04-20'} -TimeoutSec 15
            Reset-ClaudeRetryDelay
            return Convert-ClaudeWeeklyWindow $usage
        } catch {
            Write-ClaudeFailure 'usage' $_
            if ($null -ne $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                if ($status -eq 401 -and $attempt -eq 0) { $token = Get-ClaudeAccessToken -Force -RejectedToken $token; continue }
                if ($status -eq 401 -or $status -eq 403) { throw 'CLAUDE_LOGIN' }
                if ($status -eq 429) { Set-ClaudeRetryDelay $_.Exception.Response; throw 'CLAUDE_RATE_LIMIT' }
            }
            throw 'CLAUDE_CONNECTION'
        }
    }
}
function Write-UsageStatus([string]$Message) {
    try {
        if ((Test-Path -LiteralPath $script:logPath) -and (Get-Item -LiteralPath $script:logPath).Length -gt 102400) { [IO.File]::WriteAllText($script:logPath,'') }
        [IO.File]::AppendAllText($script:logPath, ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')+' v'+$script:version+' '+$Message+"`r`n"))
    } catch {}
}
function Update-Usage {
    if ($script:refreshing) { return }
    $script:refreshing = $true
    Write-UsageStatus 'REFRESH_STARTED'
    $rowClaude.Reset.Text = 'connecting...'
    $form.Refresh()
    $lines = @()
    try {
        try {
            $snapshot = Get-RateLimits
            $limits = $snapshot.rateLimits
            if ($null -ne $snapshot.rateLimitsByLimitId.codex) { $limits = $snapshot.rateLimitsByLimitId.codex }
            $weekly = Get-WeeklyWindow $limits
            Set-BarRow $rowSeven $weekly
            if ($null -ne $weekly) { $lines += "GPT (Codex) weekly: $([int][Math]::Round([double]$weekly.usedPercent))% used - resets $(Format-Reset $weekly.resetsAt)" }
            else { Show-Message 'no weekly data' $CodexAmber; $lines += 'GPT: No 7-day usage window was returned.' }
        } catch {
            Stop-AppServer
            Set-BarRow $rowSeven $null
            $message = 'connection error'
            if ($_.Exception.Message -eq 'CODEX_NOT_FOUND') { $message = 'install Codex CLI' }
            elseif ($_.Exception.Message -match 'auth|login|401|credential|token') { $message = 'codex login' }
            Show-Message $message $CodexRed
            $lines += "GPT: $message"
        }
        try {
            Write-UsageStatus 'CLAUDE_REQUEST_STARTED'
            $weekly = Get-ClaudeWeeklyUsage
            Write-UsageStatus ('CLAUDE_REQUEST_OK weekly=' + ($null -ne $weekly))
            Set-BarRow $rowClaude $weekly
            $script:lastClaudeWindow = $weekly
            $script:lastClaudeUpdated = [DateTimeOffset]::Now
            $script:claudeWaiting = $false
            if ($null -ne $weekly) { $lines += "Claude weekly (all models): $([int][Math]::Round([double]$weekly.usedPercent))% used - resets $(Format-Reset $weekly.resetsAt)" }
            else { $rowClaude.Reset.Text='no weekly data'; $rowClaude.Reset.ForeColor=$CodexAmber; $lines += 'Claude: No overall 7-day usage window was returned.' }
        } catch {
            Write-UsageStatus ('CLAUDE_ERROR ' + $(if ($_.Exception.Message -like 'CLAUDE_*') { $_.Exception.Message } else { $_.Exception.GetType().Name }))
            $script:claudeWaiting = $_.Exception.Message -eq 'CLAUDE_RATE_LIMIT'
            $temporary = $_.Exception.Message -in @('CLAUDE_RATE_LIMIT','CLAUDE_CONNECTION')
            if ($temporary -and $null -ne $script:lastClaudeWindow) {
                Set-BarRow $rowClaude $script:lastClaudeWindow
                $rowClaude.Percent.ForeColor = $CodexMuted
                $rowClaude.Fill.BackColor = $CodexMuted
                $lines += ('Claude: showing previous data from ' + $script:lastClaudeUpdated.ToString('MM/dd HH:mm'))
            } else { Set-BarRow $rowClaude $null }
            $message = switch ($_.Exception.Message) {
                'CLAUDE_LOGIN' { 'Claude login' }
                'CLAUDE_RATE_LIMIT' { Get-ClaudeRetryMessage }
                'CLAUDE_CREDENTIAL_WRITE' { 'login file locked' }
                default { 'connection error' }
            }
            $rowClaude.Reset.Text=$message; $rowClaude.Reset.ForeColor=$CodexRed
            $lines += "Claude: $message"
            if ($script:claudeWaiting) {
                $resume = [DateTimeOffset]::FromUnixTimeSeconds((Get-ClaudeRetryState).retryAfter).ToLocalTime().ToString('MM/dd HH:mm:ss')
                $lines += "Claude server request limit: automatic retry after $resume. Refresh now also respects this wait."
                $rowClaude.Reset.ForeColor = $CodexAmber
            }
            if ($_.Exception.Message -eq 'CLAUDE_LOGIN') { $lines += 'Open Claude Code to refresh login; sign in again if needed.' }
        }
        Write-UsageStatus "REFRESH_COMPLETED"
        $script:lastTip = $lines -join "`n"
        foreach ($target in @($form)) { $tooltip.SetToolTip($target,$script:lastTip) }
        foreach ($row in $allRows) { foreach ($target in @($row.Label,$row.Track,$row.Fill,$row.Percent,$row.Reset)) { $tooltip.SetToolTip($target,$script:lastTip) } }
    } finally { $script:refreshing=$false }
}

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = ($script:refreshSeconds * 1000); $timer.Add_Tick({ Update-Usage })
$keeper = New-Object System.Windows.Forms.Timer; $keeper.Interval = 3000
$keeper.Add_Tick({
    if ($script:claudeWaiting) {
        $rowClaude.Reset.Text = Get-ClaudeRetryMessage
        if ((Get-ClaudeRetrySeconds) -eq 0 -and -not $script:refreshing) { Update-Usage }
    }
    if (Test-FullscreenForeground) { if ($form.Visible) { $form.Hide() }; return }
    if (-not $form.Visible) { [CodexBarNative]::ShowWindow($form.Handle, 8) | Out-Null }
    Set-BarPosition; Assert-TopMost
})
$refreshItem.Add_Click({ Update-Usage })
$detailsItem.Add_Click({ [System.Windows.Forms.MessageBox]::Show($(if($script:lastTip){$script:lastTip}else{"No data yet."}), "AIusagebar $($script:version)") | Out-Null })
$exitItem.Add_Click({ $form.Close() })

$dragging = $false; $dragOrigin = 0
$dragDown = { param($s,$e) if($e.Button -eq [System.Windows.Forms.MouseButtons]::Left){$script:dragging=$true;$script:dragOrigin=[System.Windows.Forms.Cursor]::Position.X-$form.Location.X} }
$dragMove = { if($script:dragging){$x=[System.Windows.Forms.Cursor]::Position.X-$script:dragOrigin;if($x-lt 0){$x=0};$script:offsetX=$x;$form.Location=New-Object System.Drawing.Point($x,$form.Location.Y)} }
$dragUp = { if($script:dragging){$script:dragging=$false;Save-Config} }
foreach($c in @($form,$rowSeven.Label,$rowSeven.Percent,$rowSeven.Reset,$rowClaude.Label,$rowClaude.Percent,$rowClaude.Reset)){ $c.Add_MouseDown($dragDown);$c.Add_MouseMove($dragMove);$c.Add_MouseUp($dragUp) }

$form.Add_FormClosed({ $timer.Stop();$keeper.Stop();Stop-AppServer;Save-Config;try{$script:mutex.ReleaseMutex()}catch{};$script:mutex.Dispose() })
$handle = $form.Handle; $ex = [CodexBarNative]::GetWindowLong($handle,-20); [CodexBarNative]::SetWindowLong($handle,-20,($ex -bor 0x80 -bor 0x08000000)) | Out-Null
Set-BarPosition; $form.Add_Shown({ Update-Usage; $timer.Start(); $keeper.Start(); Set-BarPosition; Assert-TopMost })
if ($SmokeTest) {
    try {
        $script:logPath = Join-Path $env:TEMP 'AIusagebar-verification.log'
        $script:smokeCodexCalls = 0; $script:smokeClaudeCalls = 0
        function Get-RateLimits { $script:smokeCodexCalls++; return @{rateLimits=@{primary=@{usedPercent=42;resetsAt=1791586800;windowDurationMins=10080}}} }
        function Get-ClaudeWeeklyUsage { $script:smokeClaudeCalls++; return @{usedPercent=67;resetsAt=1791586800;windowDurationMins=10080} }
        $form.Opacity = 0
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        Set-BarPosition
        if ($script:smokeCodexCalls -ne 1 -or $script:smokeClaudeCalls -ne 1) { throw 'Startup did not refresh both providers.' }
        if ($rowSeven.Percent.Text -notmatch '^42%' -or $rowClaude.Percent.Text -notmatch '^67%') { throw ('Startup did not display usage: '+$script:lastTip) }
        foreach ($row in $allRows) {
            foreach ($key in @('Label','Percent','Reset')) {
                $label = $row[$key]
                if ($label.Right -gt $form.ClientSize.Width -or $label.Bottom -gt $form.ClientSize.Height) { throw 'Control extends past widget boundary.' }
                if ([Windows.Forms.TextRenderer]::MeasureText($label.Text,$label.Font).Width -gt $label.Width) { throw 'Text does not fit its control.' }
                if ($label.Font.GetHeight() -gt $label.Height) { throw 'Font does not fit row height.' }
            }
        }
        $rect = Get-TaskbarRect
        if ($form.Height -gt ($rect.Bottom-$rect.Top)) { throw 'Widget taller than taskbar.' }
        function Get-ClaudeRetryState { return @{retryAfter=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+300);failures=1} }
        function Get-ClaudeRetryMessage { return 'wait 5m' }
        function Get-ClaudeWeeklyUsage { throw 'CLAUDE_RATE_LIMIT' }
        Update-Usage
        if ($rowClaude.Percent.Text -notmatch '^67%' -or $rowClaude.Reset.Text -ne 'wait 5m' -or $script:lastTip -notmatch 'showing previous data') { throw 'Cooldown did not preserve and label previous usage.' }
        function Get-ClaudeWeeklyUsage { throw 'CLAUDE_LOGIN' }
        Update-Usage
        if ($rowClaude.Percent.Text -notmatch '^--%' -or $rowClaude.Reset.Text -ne 'Claude login') { throw 'Login failure did not clear previous usage.' }
        function Get-ClaudeWeeklyUsage { return @{usedPercent=67;resetsAt=1791586800;windowDurationMins=10080} }
        Update-Usage
        if ($script:claudeWaiting -or $rowClaude.Percent.Text -notmatch '^67%' -or $rowClaude.Percent.ForeColor -ne $rowClaude.BrandColor) { throw 'Recovery did not restore live usage styling.' }
        if ($SmokeImagePath) {
            $bitmap = [Drawing.Bitmap]::new($form.Width,$form.Height)
            try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($SmokeImagePath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        }
        Write-Output ('SMOKE_PASS: '+$form.Width+'x'+$form.Height+'; startup, cooldown cache, login failure, recovery and text fit verified; provider requests mocked')
    } finally { $script:mutex.ReleaseMutex(); $script:mutex.Dispose(); $form.Dispose() }
    exit 0
}
[System.Windows.Forms.Application]::Run($form)
