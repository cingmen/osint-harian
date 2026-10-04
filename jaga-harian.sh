#!/usr/bin/env bash
# =============================================================================
#  osint-harian — penjaga harian (keep-alive)
#
#  Menjalankan tracker-harian.sh secara otomatis setiap tengah malam (00:00
#  waktu lokal) SELAMA terminal ini tetap terbuka. Cocok untuk PC yang menyala
#  24 jam sehingga Anda tidak perlu mengetik perintah tiap hari.
#
#  Pemakaian:
#    ./jaga-harian.sh              # tunggu sampai 00:00 berikutnya, lalu tiap hari
#    ./jaga-harian.sh --sekarang   # jalankan SEKARANG, lalu lanjut tiap 00:00
#
#  Berhenti: tekan Ctrl+C.
#  Log: data/logs/jaga-<YYYY-MM-DD>.log (tidak di-commit; lihat .gitignore).
#
#  Catatan: script tracker sudah menangani lock (.lock), jadi Ctrl+C di tengah
#  run lalu menjalankan lagi tidak akan menumpuk proses.
# =============================================================================
set -u

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$BASE_DIR/tracker-harian.sh"
LOG_DIR="$BASE_DIR/data/logs"
mkdir -p "$LOG_DIR"

SEKARANG=0
[ "${1:-}" = "--sekarang" ] && SEKARANG=1

# Deteksi keluarga `date` SEKALI (GNU vs BSD) — sama seperti script tracker.
_IS_GNU_DATE=""
if date -v-1d +%s >/dev/null 2>&1; then _IS_GNU_DATE=0; else _IS_GNU_DATE=1; fi

detik_ke_tengah_malam() {
  # Selisih detik dari sekarang ke 00:00 berikutnya (waktu lokal).
  local now next
  now="$(date +%s)"
  if [ "$_IS_GNU_DATE" = "1" ]; then
    next="$(date -d 'tomorrow 00:00' +%s)"
  else
    next="$(date -v+1d -v0H -v0M -v0S +%s)"
  fi
  printf '%d' "$(( next - now ))"
}

jalankan() {
  local tanggal logfile
  tanggal="$(date +%Y-%m-%d)"
  logfile="$LOG_DIR/jaga-${tanggal}.log"
  printf '[%s] == Menjalankan tracker harian ==\n' "$(date '+%F %T')" | tee -a "$logfile"
  # Jalankan tracker; teruskan keluaran ke layar + log. Jangan matikan penjaga
  # bila tracker gagal (biarkan loop menunggu tengah malam berikutnya).
  bash "$RUNNER" 2>&1 | tee -a "$logfile"
  local kode="${PIPESTATUS[0]}"
  printf '[%s] == Selesai (exit %s) ==\n' "$(date '+%F %T')" "$kode" | tee -a "$logfile"
}

if [ "$SEKARANG" = "1" ]; then
  jalankan
fi

while true; do
  sisa="$(detik_ke_tengah_malam)"
  printf '[%s] Tidur %s detik sampai 00:00 berikutnya. Tekan Ctrl+C untuk berhenti.\n' \
    "$(date '+%F %T')" "$sisa"
  sleep "$sisa"
  jalankan
  # Jeda kecil agar tidak dobel-jalan bila jam tepat 00:00.
  sleep 60
done
