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

    if (-not (Test-Path $Exe)) {
        Write-Host "[ERROR] $Exe not found after install — cài có thể đã thất bại."
        Write-Host 'Kiểm tra lại trong Start menu; nếu DNUDesk đã có thì chạy lại script lần nữa (nó sẽ skip install).'
        exit 1
    }
    Write-Host "[debug] installed OK: $Exe"
}

# --- [3/5] Wait for ID ---
Write-Host '[3/5] Waiting for service / ID generation...'
$Id = ''
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    $out = & $Exe --get-id 2>$null
    if ($LASTEXITCODE -eq 0 -and $out -match '^\s*\d{6,}\s*$') {
        $Id = $out.Trim()
        Write-Host "[debug] got ID after $($i*2)s"
        break
    }
    if ($i % 5 -eq 0) { Write-Host "[debug] still waiting... ($($i*2)s, --get-id returned: '$out')" }
}
if (-not $Id) { Write-Warning "ID not readable yet (got: '$out'). Clipboard will only have the password." }

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
$chain = ($opts | ForEach-Object { "`\"$Exe`\" $($_ -join ' ')" }) -join ' && '
Invoke-Proc -FilePath cmd.exe -ArgumentList '/c', $chain -TimeoutSec 120 -StepName 'config'

# --- [5/5] Clipboard ---
Write-Host '[5/5] Copying ID + password to clipboard...'
$info = "ID: $Id`nPassword: $PermPassword"
try { Set-Clipboard -Value $info } catch { Write-Warning "Clipboard failed: $_ (copy thủ công từ dòng dưới)" }
Write-Host $info
Write-Host '=> Da copy vao clipboard. Dan vao Zalo/tele ngay.'

Start-Process $Exe
Write-Host '[done] OK.'
