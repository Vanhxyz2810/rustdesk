# DNUDesk install + unattended-support setup + copy ID/password to clipboard
# Chạy bằng user thường hoặc admin đều được; các bước cần admin tự elevate.

$ErrorActionPreference = 'Stop'

# ===== CONFIG — sửa cho đúng môi trường =====
$DownloadUrl  = 'http://103.77.242.50/dl/DNUDesk-install.exe'
$Exe          = "$env:ProgramFiles\DNUDesk\DNUDesk.exe"
$PermPassword = 'DNU-2026-lab'   # password cố định — bạn tự chọn, gửi cho người connect
$SupportId    = ''               # ID máy của NGƯỜI CONNECT (mở DNUDesk trên máy họ để xem ID).
                                # Để trống '' nếu chưa biết — khi đó không set whitelist,
                                # session vẫn auto-accept bằng password (CM tự minimize sau 3s).
# =============================================

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$IsAdmin = Test-Admin
Write-Host "[debug] running as admin: $IsAdmin"

# Chạy tiến trình rồi POLL HasExited với timeout.
# KHÔNG dùng Start-Process -Wait: installer spawn Windows service (kế thừa handle)
# khiến -Wait treo vĩnh viễn dù installer đã thoát.
function Invoke-Proc {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [int]$TimeoutSec = 240,
        [string]$StepName = 'step'
    )
    if ($IsAdmin) {
        Write-Host "[debug] $StepName : running directly (admin)"
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    } else {
        Write-Host "[debug] $StepName : elevating via UAC..."
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -PassThru -WindowStyle Hidden
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Write-Host "[debug] $StepName : timeout ${TimeoutSec}s — tiếp tục (tiến trình có thể vẫn chạy nền)"
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "[debug] $StepName : exited, code=$($p.ExitCode)"
}

# --- [1/5] Download ---
if (Test-Path $Exe) {
    Write-Host '[1/5] Already installed — skipping download + install.'
} else {
    $f = "$env:TEMP\DNUDesk-install.exe"
    Write-Host '[1/5] Downloading installer...'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $f -UseBasicParsing
    Write-Host "[debug] downloaded: $((Get-Item $f).Length) bytes"

    # --- [2/5] Install ---
    Write-Host '[2/5] Silent install...'
    Invoke-Proc -FilePath $f -ArgumentList '--silent-install' -TimeoutSec 300 -StepName 'install'
    Remove-Item $f -Force -ErrorAction SilentlyContinue

    # Packer spawn tiến trình cài thật rồi exit ngay (code=0) — việc copy file
    # vẫn đang chạy nền. Poll chờ exe xuất hiện thay vì check 1 lần.
    Write-Host '[2/5] Waiting for install to finish (file copy runs in background)...'
    $ok = $false
    for ($i = 1; $i -le 60; $i++) {
        if (Test-Path $Exe) { $ok = $true; Write-Host "[debug] $Exe appeared after $($i*2)s"; break }
        Start-Sleep -Seconds 2
        if ($i % 5 -eq 0) { Write-Host "[debug] still copying... ($($i*2)s)" }
    }
    if (-not $ok) {
        Write-Host "[ERROR] $Exe still not found after 120s — install có thể đã thất bại."
        Write-Host 'Nếu DNUDesk đã có trong Start menu, chạy lại script (nó sẽ skip install).'
        exit 1
    }
}

# --- [3/5] Wait for service + ID ---
Write-Host '[3/5] Waiting for DNUDesk service + ID generation...'
$svc = Get-Service -Name 'DNUDesk' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Write-Host "[debug] service status: $($svc.Status) — starting..."
    try { Start-Service -Name 'DNUDesk' -ErrorAction Stop } catch { Write-Host "[debug] start-service: $_" }
}
for ($i = 1; $i -le 30; $i++) {
    $svc = Get-Service -Name 'DNUDesk' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Write-Host '[debug] service Running'; break }
    Start-Sleep -Seconds 2
    if ($i % 5 -eq 0) { Write-Host "[debug] service still: $($svc.Status) ($($i*2)s)" }
}

# ID chỉ được ghi vào user config sau khi GUI spawn tiến trình --server user-mode
# (nó là bên đăng ký với hbbs). Mở app rồi ẨN NGAY — server spawn lúc startup,
# không cần cửa sổ visible để đăng ký ID. Máy thi không thấy cửa sổ nào.
Write-Host '[3/5] Launching app (hidden) to trigger ID registration...'
Start-Process $Exe
Start-Sleep -Seconds 3
foreach ($p in Get-Process DNUDesk -ErrorAction SilentlyContinue) {
    if ($p.CloseMainWindow()) {
        Write-Host '[debug] app window hidden to tray'
    }
}

# DNUDesk.exe là app GUI (WIN32 subsystem): `$x = & $Exe --get-id` không đảm bảo
# PowerShell 5.1 cấp pipe stdout cho nó -> println! của Rust rơi vào handle rỗng,
# $x luôn trống. Tự tạo Process với RedirectStandardOutput để chắc chắn có pipe.
# (Không đọc được ID từ DNUDesk.toml: file chỉ chứa enc_id đã mã hoá theo máy.)
function Get-DNUDeskId {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = '--get-id'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # Đọc async: tránh treo nếu tiến trình con nào đó giữ pipe.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(15000)) {
            try { $p.Kill() } catch { }
            return @{ Id = ''; Raw = '(timeout 15s)' }
        }
        $null = $outTask.Wait(3000)
        $null = $errTask.Wait(1000)
        $raw = ''
        if ($outTask.IsCompleted) { $raw = $outTask.Result }
        $id = ''
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*(\d{6,})\s*$') { $id = $Matches[1] }
        }
        $errText = ''
        if ($errTask.IsCompleted) { $errText = $errTask.Result.Trim() }
        return @{ Id = $id; Raw = "exit=$($p.ExitCode) out='$($raw.Trim())' err='$errText'" }
    } catch {
        return @{ Id = ''; Raw = "exception: $_" }
    }
}

$Id = ''
$out = ''
for ($i = 1; $i -le 90; $i++) {
    $r = Get-DNUDeskId
    $out = $r.Raw
    if ($r.Id) {
        $Id = $r.Id
        Write-Host "[debug] got ID via --get-id after $($i*2)s"
        break
    }
    # Dự phòng: cách upstream RustDesk dùng — pipeline cũng buộc PS redirect stdout.
    $alt = $null
    try {
        $alt = (& $Exe --get-id 2>$null | Write-Output) | Where-Object { $_ -match '^\s*\d{6,}\s*$' } | Select-Object -Last 1
    } catch { }
    if ($alt) {
        $Id = "$alt".Trim()
        Write-Host "[debug] got ID via --get-id pipeline after $($i*2)s"
        break
    }
    if ($i -eq 1) { Write-Host "[debug] first --get-id attempt: $out" }
    Start-Sleep -Seconds 2
    if ($i % 5 -eq 0) { Write-Host "[debug] waiting for ID... ($($i*2)s, got: '$out')" }
}
if (-not $Id) {
    Write-Warning "ID not readable after 180s (last: '$out'). Clipboard sẽ chỉ có password."
    Write-Host "Gợi ý: ID hiển thị trên cửa sổ DNUDesk đang mở — copy tay từ đó."
}

# --- [4/5] Configure ---
Write-Host '[4/5] Configuring password + options...'
$opts = @(
    @('--password', $PermPassword),
    @('--option', 'approve-mode'), @('--option', 'password'),
    @('--option', 'verification-method'), @('--option', 'use-permanent-password')
)
if ($SupportId -match '^\d{6,}$') {
    $opts += @('--option', 'id-whitelist'), @('--option', $SupportId)
    $opts += @('--option', 'unattended-support'), @('--option', 'Y')
}
$q = [char]34  # double-quote, tránh escape lồng
$chain = ($opts | ForEach-Object { "$q$Exe$q $($_ -join ' ')" }) -join ' && '
Invoke-Proc -FilePath cmd.exe -ArgumentList '/c', $chain -TimeoutSec 120 -StepName 'config'

# --- [5/5] Clipboard ---
Write-Host '[5/5] Copying ID + password to clipboard...'
$info = "ID: $Id`nPassword: $PermPassword"
try { Set-Clipboard -Value $info } catch { Write-Warning "Clipboard failed: $_ (copy thủ công từ dòng dưới)" }
Write-Host $info
Write-Host '=> Da copy vao clipboard. Dan vao Zalo/tele ngay.'

# Đóng cửa sổ chính: app chỉ ẩn vào tray (giống user bấm X) — server vẫn chạy,
# không hiện cửa sổ trên máy thi. Icon tray vẫn còn để quản lý nếu cần.
foreach ($p in Get-Process DNUDesk -ErrorAction SilentlyContinue) {
    $null = $p.CloseMainWindow()
}
Write-Host '[done] OK — cửa sổ đã ẩn vào tray, chỉ còn icon tray gần đồng hồ.'
