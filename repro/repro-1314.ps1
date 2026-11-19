param(
    [Parameter(Mandatory)] [string] $Exe,
    [int] $Port = 7991,
    [ValidateSet('main-only', 'main-then-pop', 'pop-then-main')] [string] $Order = 'main-only',
    [int] $FlushAfter = -1,
    [int] $WaitMinimized = 2,
    [switch] $Keep
)
$ErrorActionPreference = 'Stop'
if (-not ('Win' -as [type])) {
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Win {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public static List<KeyValuePair<IntPtr,string>> Windows(int target) {
    var r = new List<KeyValuePair<IntPtr,string>>();
    EnumWindows((h,l)=>{ int pid; GetWindowThreadProcessId(h,out pid); var c=new StringBuilder(64); GetClassName(h,c,64);
      if(pid==target && c.ToString()=="Window Class"){ var t=new StringBuilder(256); GetWindowText(h,t,256); r.Add(new KeyValuePair<IntPtr,string>(h,t.ToString())); } return true; }, IntPtr.Zero);
    return r;
  }
}
'@
}

$env:MAILCRAFT_NO_PREFS = '1'
$env:MAILCRAFT_REPORT_URL = ''
if ($FlushAfter -ge 0) { $env:MAILCRAFT_FLUSH_AFTER_SECS = "$FlushAfter" } else { Remove-Item Env:MAILCRAFT_FLUSH_AFTER_SECS -ErrorAction SilentlyContinue }
$proc = Start-Process -FilePath $Exe -ArgumentList '--sample', '--control', "$Port" -PassThru
$client = $null
try {
    $keyFile = Join-Path $env:APPDATA "MailCraft\control-key.local-$Port"
    for ($i = 0; $i -lt 60 -and -not (Test-Path $keyFile); $i++) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Seconds 3
    $key = (Get-Content $keyFile -Raw).Trim()
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream); $writer.AutoFlush = $true
    $reader = New-Object System.IO.StreamReader($stream)
    $script:n = 0
    function Send($method, $params) {
        $script:n++
        $line = @{ id = $script:n; key = $key; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 8
        $writer.WriteLine($line)
        return ($reader.ReadLine() | ConvertFrom-Json)
    }
    $dismissed = Send 'engine.execute' @{ command = 'ui.dismissReminder'; params = @{ all = $true } }
    Write-Host "dismiss reminders: $($dismissed | ConvertTo-Json -Compress -Depth 5)"
    Start-Sleep -Seconds 1
    $list = Send 'engine.execute' @{ command = 'mail.list'; params = @{ limit = 1 } }
    $id = $list.result.messages[0].id
    [void](Send 'engine.execute' @{ command = 'ui.openWindow'; params = @{ message = $id } })
    Start-Sleep -Seconds 3

    $wins = [Win]::Windows($proc.Id)
    $main = ($wins | Where-Object { $_.Value -like '*MailCraft*' } | Select-Object -First 1).Key
    $pop = ($wins | Where-Object { $_.Value -notlike '*MailCraft*' -and $_.Value -ne '' } | Select-Object -First 1)
    if (-not $pop) { throw 'no pop-out window' }

    switch ($Order) {
        'main-only' { [void][Win]::ShowWindow($main, 6); Start-Sleep -Seconds $WaitMinimized }
        'main-then-pop' { [void][Win]::ShowWindow($main, 6); Start-Sleep -Seconds 1; [void][Win]::ShowWindow($pop.Key, 6); Write-Host "both minimized at $([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"; Start-Sleep -Seconds $WaitMinimized; Write-Host "restoring at $([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"; [void][Win]::ShowWindow($pop.Key, 9); Start-Sleep -Seconds 2 }
        'pop-then-main' { [void][Win]::ShowWindow($pop.Key, 6); Start-Sleep -Seconds 1; [void][Win]::ShowWindow($main, 6); Start-Sleep -Seconds $WaitMinimized; [void][Win]::ShowWindow($pop.Key, 9); Start-Sleep -Seconds 2 }
    }
    Write-Host "order=$Order flushAfter=$FlushAfter popout iconic=$([Win]::IsIconic($pop.Key)) main iconic=$([Win]::IsIconic($main))"

    [void][Win]::PostMessage($pop.Key, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Seconds 3
    $still = [Win]::Windows($proc.Id) | Where-Object { $_.Key -eq $pop.Key }
    if ($still) { Write-Host 'RESULT: pop-out is STILL OPEN (bug)' } else { Write-Host 'RESULT: pop-out closed' }
} finally {
    if ($client) { $client.Close() }
    if (-not $Keep) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } else { Write-Host "kept running: pid $($proc.Id)" }
}
