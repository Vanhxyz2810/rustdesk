# DNUDesk uninstall + xoa sach cau hinh (ID, password, log).
# Chay bang 1 dong (u = uninstall):
#   powershell -c "iex (iwr http://103.77.242.50/dl/u.ps1 -UseBasicParsing)"

$ErrorActionPreference = 'Continue'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$Exe = "$env:ProgramFiles\DNUDesk\DNUDesk.exe"
$Url = 'http://103.77.242.50/dl/u.ps1'

# Tu elevate 1 lan duy nhat (bam Yes o UAC), instance elevated chay lai toan bo script nay.
if (-not (Test-Admin)) {
    Write-Host '[0/3] Can admin — bam Yes o cua so UAC...'
    $cmd = "iex (iwr $Url -UseBasicParsing)"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit', '-EncodedCommand', $enc
    return
}

Write-Host '[1/3] Go DNUDesk...'
if (Test-Path $Exe) {
    $p = Start-Process -FilePath $Exe -ArgumentList '--uninstall' -PassThru
    # Doi uninstall chay xong: process thoat + exe bien mat + service bien mat.
    $deadline = (Get-Date).AddSeconds(90)
    while (((Test-Path $Exe) -and (-not $p.HasExited)) -or (Get-Service -Name 'DNUDesk' -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 500
    }
    # Uninstall co the chan file vi process con song — doi them 1 nhip roi kill du.
    Start-Sleep -Seconds 2
} else {
    Write-Host '[debug] Khong thay exe (da go truoc do?)'
}
foreach ($proc in Get-Process DNUDesk -ErrorAction SilentlyContinue) {
    try { $proc.Kill() } catch { }
}

Write-Host '[2/3] Xoa cau hinh (ID + password + log)...'
$dirs = @(
    "$env:APPDATA\DNUDesk",
    'C:\Windows\System32\config\systemprofile\AppData\Roaming\DNUDesk',
    'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\DNUDesk',
    "$env:ProgramFiles\DNUDesk"
)
foreach ($d in $dirs) {
    if (Test-Path $d) {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $d) { Write-Warning "Khong xoa duoc: $d (file dang bi khoa?)" }
        else { Write-Host "[debug] da xoa $d" }
    }
}
Remove-Item "$env:TEMP\dnudesk-config.*" -Force -ErrorAction SilentlyContinue

Write-Host '[3/3] Kiem tra...'
$left = $dirs | Where-Object { Test-Path $_ }
if ($left) {
    Write-Warning ('Con sot lai: ' + ($left -join ', '))
    Write-Host 'Restart may roi chay lai lenh nay, hoac xoa tay thu muc do.'
} else {
    Write-Host 'SACH — khong con dau vet DNUDesk tren may nay.'
}
Write-Host ''
Write-Host 'Xong. Co the dong cua so nay.'
