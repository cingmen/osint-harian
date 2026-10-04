# =============================================================================
#  osint-harian — penjaga harian (keep-alive, Windows / PowerShell 5.1+)
#
#  Menjalankan tracker-harian.ps1 secara otomatis setiap tengah malam (00:00
#  waktu lokal) SELAMA jendela PowerShell ini tetap terbuka.
#
#  Pemakaian:
#    powershell -ExecutionPolicy Bypass -File .\jaga-harian.ps1
#    powershell -ExecutionPolicy Bypass -File .\jaga-harian.ps1 -Sekarang
#
#  Berhenti: tekan Ctrl+C.
#  Log: data\logs\jaga-<YYYY-MM-DD>.log (tidak di-commit).
# =============================================================================
#requires -Version 5.1
param([switch]$Sekarang)

$BASE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BASE_DIR) { $BASE_DIR = (Get-Location).Path }
$RUNNER  = Join-Path $BASE_DIR 'tracker-harian.ps1'
$LOG_DIR = Join-Path $BASE_DIR 'data\logs'
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

function Jalankan {
  $logfile = Join-Path $LOG_DIR ('jaga-' + (Get-Date).ToString('yyyy-MM-dd') + '.log')
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "[$stamp] == Menjalankan tracker harian ==" | Tee-Object -FilePath $logfile -Append
  $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RUNNER *>&1
  $kode = $LASTEXITCODE
  $out | Tee-Object -FilePath $logfile -Append
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "[$stamp] == Selesai (exit $kode) ==" | Tee-Object -FilePath $logfile -Append
}

if ($Sekarang) { Jalankan }

while ($true) {
  $now  = Get-Date
  $next = $now.Date.AddDays(1)                 # besok 00:00 waktu lokal
  $sisa = [int]($next - $now).TotalSeconds
  "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Tidur $sisa detik sampai 00:00 berikutnya. Tekan Ctrl+C untuk berhenti."
  if ($sisa -gt 0) { Start-Sleep -Seconds $sisa }
  Jalankan
  Start-Sleep -Seconds 60                      # hindari dobel-jalan tepat 00:00
}
