param([switch]$StopOnly)
$ErrorActionPreference = 'Stop'
$installed = Join-Path $env:LOCALAPPDATA 'AIusagebar'
try {
    # Close the widget window first so it can exit cleanly.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class UsageBarUninstallNative {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
}
'@
    $h = [UsageBarUninstallNative]::FindWindow($null, 'AIusagebar')
    if ($h -ne [IntPtr]::Zero) {
        [UsageBarUninstallNative]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        for ($i = 0; $i -lt 50; $i++) { Start-Sleep -Milliseconds 200; if ([UsageBarUninstallNative]::FindWindow($null, 'AIusagebar') -eq [IntPtr]::Zero) { break } }
    }
    # A previous instance may still be running without a visible window.
    foreach ($process in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
        if ($process.ProcessId -ne $PID -and $process.CommandLine -match '(?i)-File\s+"?[^"\r\n]*\\(?:AIusagebar|Run-Widget)\.ps1(?:"|\s|$)') {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    $mutex = [Threading.Mutex]::new($false, 'Local\AIusagebar')
    $free = $false
    try {
        try { $free = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $free = $true }
        if (-not $free) { throw '실행 중인 AIusagebar를 종료하지 못했습니다. 위젯을 우클릭해 Exit 후 다시 시도하세요.' }
    } finally { if ($free) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    if ($StopOnly) { return }

    $programs = [Environment]::GetFolderPath('Programs')
    $startup = [Environment]::GetFolderPath('Startup')
    foreach ($link in @((Join-Path $programs 'AIusagebar.lnk'), (Join-Path $programs 'AIusagebar 제거.lnk'), (Join-Path $startup 'AIusagebar.lnk'))) {
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
    }
    if (Test-Path -LiteralPath $installed) { Remove-Item -LiteralPath $installed -Recurse -Force }
    # Widget position, log and Claude retry state. Claude/Codex logins are left alone.
    foreach ($path in @((Join-Path $env:USERPROFILE '.ai-usage-bar'), (Join-Path $env:TEMP 'AIusagebar.log'), (Join-Path $env:TEMP 'AIusagebar-Claude-Retry.json'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    Write-Host 'AIusagebar 제거 완료. (Claude / ChatGPT 로그인 정보는 그대로 유지됩니다.)'
} catch {
    Write-Host ('제거 실패: ' + $_.Exception.Message)
    exit 1
}
