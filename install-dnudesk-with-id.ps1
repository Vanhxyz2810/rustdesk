# DNUDesk install + unattended-support setup + copy ID/password to clipboard
# Mở rộng từ lệnh install 1 dòng của user.
# Chạy bằng user thường (có quyền clipboard); các bước cần admin tự elevate.

$ErrorActionPreference = 'Stop'

# ===== CONFIG — sửa cho đúng môi trường =====
$DownloadUrl  = 'http://103.77.242.50/dl/DNUDesk-install.exe'
$Exe          = "$env:ProgramFiles\DNUDesk\DNUDesk.exe"
$PermPassword = 'DNU-2026-lab'   # password cố định — bạn tự chọn, gửi cho người connect
$SupportId    = ''               # ID máy của NGƯỜI CONNECT (mở DNUDesk trên máy họ để xem ID).
                                # Để trống '' nếu chưa biết — khi đó không set whitelist,
                                # session vẫn auto-accept bằng password (CM tự minimize sau 3s).
# =============================================

# Script này có thể đang chạy trong PowerShell đã elevate sẵn (VD chạy từ
# PowerShell "Run as Administrator"). Khi đó -Verb RunAs sẽ treo vì không
# còn cửa sổ UAC nào để hiện — bỏ qua UAC nếu đã là admin.
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Invoke-Elevated {
    param([string]$FilePath, [string]$ArgumentList)
    if ($script:IsAdmin) {
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -WindowStyle Hidden
    } else {
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -Wait -WindowStyle Hidden
    }
}

$f = "$env:TEMP\DNUDesk-install.exe"

Write-Host '[1/5] Downloading installer...'
Invoke-WebRequest -Uri $DownloadUrl -OutFile $f -UseBasicParsing

Write-Host '[2/5] Silent install (elevated)...'
Invoke-Elevated -FilePath $f -ArgumentList '--silent-install'
Remove-Item $f -Force -ErrorAction SilentlyContinue

# Lần cài đầu cần vài giây để service lên + sinh ID; chờ tới 60s
Write-Host '[3/5] Waiting for service / ID generation (first install is slow)...'
$Id = ''
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $out = & $Exe --get-id 2>$null
    if ($LASTEXITCODE -eq 0 -and $out -match '^\s*\d{6,}\s*$') { $Id = $out.Trim(); break }
}
if (-not $Id) { Write-Warning "ID not readable yet (got: '$out'). Clipboard will only have the password." }

# Các lệnh CLI (--password, --option) yêu cầu is_installed + is_root.
# Gộp thành MỘT lệnh elevated duy nhất qua cmd chain cho đỡ bật nhiều UAC.
Write-Host '[4/5] Configuring (one UAC prompt)...'
$opts = @(
    @('--password', $PermPassword),
    @('--option', 'approve-mode'), @('--option', 'password'),
    @('--option', 'verification-method'), @('--option', 'use-permanent-password')
)
if ($SupportId -match '^\d{6,}$') {
    # Chỉ set whitelist khi đã biết ID máy của người connect:
    # có whitelist thì unattended-support mới bật minimize-im-lặng được.
    $opts += @('--option', 'id-whitelist'), @('--option', $SupportId)
    $opts += @('--option', 'unattended-support'), @('--option', 'Y')
}
$chain = ($opts | ForEach-Object { "`"$Exe`" $($_ -join ' ')" }) -join ' && '
Invoke-Elevated -FilePath cmd.exe -ArgumentList '/c', $chain

Write-Host '[5/5] Copying ID + password to clipboard...'
$info = "ID: $Id`nPassword: $PermPassword"
Set-Clipboard -Value $info
Write-Host $info
Write-Host '=> Da copy vao clipboard. Dan vao Address Book / ghi chu ngay.'

# Mở app lần đầu (tuỳ chọn — xóa dòng này nếu không muốn hiện cửa sổ)
Start-Process $Exe
