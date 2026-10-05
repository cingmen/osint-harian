#!/usr/bin/env bash
# =============================================================================
#  osint-harian — tracker data publik harian (Indonesia + global)
#  Deterministik, TANPA API LLM. Dependensi runtime: curl + git (standar).
#  Kode: MIT (LICENSE) · Data: CC-BY 4.0 (LICENSE-DATA)
#
#  Panggunaan:
#    ./tracker-harian.sh              # run harian normal
#    ./tracker-harian.sh --cek        # diagnostik: tes semua sumber, tanpa commit
#    ./tracker-harian.sh --uji-error  # uji sistem error (URL palsu), tanpa commit
#
#  Prinsip (Bagian 1): hanya data publik resmi; tanpa login; tanpa bypass
#  paywall; tanpa data pribadi perorangan (UU PDP). Berita TIGA TIER:
#    full    : dokumen resmi/lisensi terbuka → boleh commit teks penuh
#    snippet : media komersial → commit HANYA judul + link + kutipan <=300 char
#    lokal   : FETCH_FULL_TEXT=1 → teks penuh HANYA ke data/news-full/ (gitignored)
#  Bukan nasihat hukum. Lihat README.md.
# =============================================================================

# Jangan `set -e`: satu sumber gagal tidak boleh mematikan seluruh run.
set -u

# -----------------------------------------------------------------------------
#  BAGIAN 3 — KONFIGURASI (semua pengaturan ada di blok ini)
# -----------------------------------------------------------------------------

# --- Identitas (ubah hanya di sini) ---
PROJECT_NAME="osint-harian"
CONTACT="https://cingmen.github.io/osint-harian"       # kontak di User-Agent (URL situs)
SITE_BASE="https://cingmen.github.io/osint-harian"     # URL absolut untuk feed.xml
USER_AGENT="${PROJECT_NAME}/1.0 (+https://github.com/${PROJECT_NAME}; kontak: ${CONTACT})"

# --- Ambang & retensi ---
ANOMALI_THRESHOLD=3        # kali rata-rata 7 hari agar pageviews dianggap ANOMALI
RETENTION_DAYS=90          # retensi data/news-full/
RSS_MAX_ITEMS=50           # maks entri di docs/feed.xml
TELEGRAM_LIMIT=4000        # batas karakter pesan Telegram
SNIPPET_MAX=300            # panjang kutipan maksimum (tier snippet)

# --- Kata kunci pemantauan (case-insensitive), bisa diedit ---
KEYWORDS_WATCH=("sanction" "eruption" "zero-day")

# --- Daftar sumber statis ---
#   Format: folder|nama|label|url|tier|jadwal|ext
#     tier   : full | snippet | lokal
#     jadwal : daily | senin | env:NAMA_ENV   (env harus terisi agar dijalankan)
#     token URL yang disubstitusi saat run:
#       {TODAY} {TODAY_DASH} {FROM_ISO} {TO_ISO} {FROM_ISO_ENC} {TO_ISO_ENC} {FIRMS_KEY}
SOURCES=$(cat <<'EOF'
bmkg|autogempa|BMKG Gempa Terkini|https://data.bmkg.go.id/DataMKG/TEWS/autogempa.json|full|daily|json
bmkg|gempadirasakan|BMKG Gempa Dirasakan|https://data.bmkg.go.id/DataMKG/TEWS/gempadirasakan.json|full|daily|json
ofac|sdn|OFAC SDN (daftar sanksi)|https://www.treasury.gov/ofac/downloads/sdn.csv|full|senin|csv
cisa|kev|CISA KEV (kerentanan aktif)|https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json|full|daily|json
cisa|advisories|CISA Advisories|https://www.cisa.gov/cybersecurity-advisories/all.xml|full|daily|xml
nvd|cve|NVD CVE 24 jam|https://services.nvd.nist.gov/rest/json/cves/2.0?pubStartDate={FROM_ISO_ENC}&pubEndDate={TO_ISO_ENC}|full|daily|json
ransomware|live|Ransomware.live (korban terbaru)|https://api-pro.ransomware.live/victims/recent|full|env:RANSOMWARE_API_KEY|json
who|don|WHO Disease Outbreak News|https://www.who.int/api/news/diseaseoutbreaknews|full|daily|json
usgs|m25hari|USGS Gempa M2.5+ 24 jam|https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.csv|full|daily|csv
nws|alerts|NWS Peringatan Aktif (AS)|https://api.weather.gov/alerts/active?status=actual|full|daily|json
firms|hotspot|NASA FIRMS Hotspot (Indonesia)|https://firms.modaps.eosdis.nasa.gov/api/area/csv/{FIRMS_KEY}/VIIRS_SNPP_NRT/94,-11,142,6/1|full|env:FIRMS_KEY|csv
opensky|states|OpenSky Penerbangan (Indonesia)|https://opensky-network.org/api/states/all?lamin=-11&lomin=94&lamax=6&lomax=141|full|env:OPENSKY_USER|json
github|dmca|GitHub DMCA Commit 24 jam|https://api.github.com/repos/github/dmca/commits?since={FROM_ISO_ENC}&per_page=100|full|daily|json
faa|notam|FAA NOTAM (contoh: WIII)|https://api.faa.gov/notamapi/v1/notams?icaoLocation=WIII|full|env:FAA_CLIENT_ID|json
EOF
)

# --- Artikel Wikipedia (pageviews 7 hari). Format: label|judul_artikel ---
WIKI_ARTICLES=$(cat <<'EOF'
Indonesia|Indonesia
Ibu Kota Nusantara|Ibu_Kota_Nusantara
Bank Sentral Asia|Bank_Central_Asia
EOF
)
WIKI_PROJECT="id.wikipedia"

# --- RSS berita (tier snippet). Format: nama|url ---
RSS_FEEDS=$(cat <<'EOF'
bbc|https://feeds.bbci.co.uk/news/world/rss.xml
aljazeera|https://www.aljazeera.com/xml/rss/all.xml
guardian|https://www.theguardian.com/world/rss
cna|https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml
cnbcindonesia|https://www.cnbcindonesia.com/rss
cnnindonesia|https://www.cnnindonesia.com/rss
antara|https://www.antaranews.com/rss/top-news
EOF
)

# -----------------------------------------------------------------------------
#  Variabel runtime (jangan diubah kecuali tahu akibatnya)
# -----------------------------------------------------------------------------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$BASE_DIR/data"
ERRORS_DIR="$DATA_DIR/errors"
HISTORY_DIR="$DATA_DIR/history"
NEWSFULL_DIR="$DATA_DIR/news-full"
DOCS_DIR="$BASE_DIR/docs"
LOCK_FILE="$BASE_DIR/.lock"
TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t osint-harian)"
STATE_FILE="$TMPD/state.tsv"       # folder|nama|label|tier|status|http|laten|diff|pesan|saran
ANOMALI_FILE="$TMPD/anomali.txt"
WATCH_FILE="$TMPD/watch.txt"
RINGKAS_FILE="$TMPD/ringkas.txt"   # ringkasan perubahan untuk commit & telegram

MODE="harian"
[ "${1:-}" = "--cek" ] && MODE="cek"
[ "${1:-}" = "--uji-error" ] && MODE="uji"

# --- Waktu (lokal untuk nama file, UTC untuk API) ---
TODAY="$(date +%Y%m%d)"
TODAY_DASH="$(date +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_JAM="$(date +%H:%M:%S)"
CHANGES_FILE="$DATA_DIR/CHANGES-${TODAY}.md"
THISMONTH="$(date +%Y-%m)"

# =============================================================================
#  UTILITAS
# =============================================================================

# Escape nilai agar aman di dalam string JSON (tanpa kutip pembungkus).
jesc() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\r'/}
  s=${s//$'\t'/ }
  printf '%s' "$s"
}

# URL-encode karakter minimal yang mengganggu query (mis. ':' pada ISO).
urlenc() {
  printf '%s' "$1" | sed -e 's/:/%3A/g' -e 's/ /%20/g'
}

# Deteksi keluarga `date` (GNU/BSD) SEKALI saja. Di Windows (MSYS2) setiap
# fork proses memakan ~0,2 detik, jadi deteksi berulang sangat mahal.
_IS_GNU_DATE=""
_deteksi_date() {
  [ -n "$_IS_GNU_DATE" ] && return
  if date -v-1d +%s >/dev/null 2>&1; then _IS_GNU_DATE=0; else _IS_GNU_DATE=1; fi
}

# `date` portabel: kurangi N hari, format GNU/BSD.
date_minus_days() { # $1=hari $2=format (format memakai '+')
  local n="$1" fmt="$2"
  _deteksi_date
  if [ "$_IS_GNU_DATE" = "1" ]; then
    date -d "${n} days ago" "$fmt"
  else
    date -v-"${n}"d "$fmt"
  fi
}

iso_minus24() { # ISO UTC 24 jam lalu (untuk NVD & GitHub)
  _deteksi_date
  if [ "$_IS_GNU_DATE" = "1" ]; then
    date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

# NVD memakai format ISO tanpa 'Z'.
iso_minus24_nvd() {
  _deteksi_date
  if [ "$_IS_GNU_DATE" = "1" ]; then
    date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%S.000"
  else
    date -u -v-24H +"%Y-%m-%dT%H:%M:%S.000"
  fi
}

# Deret tanggal (0..31 hari ke belakang) dihitung SEKALI lalu dipakai berulang,
# agar manifest & feed tidak memanggil `date` ratusan kali.
HARI_YMD=()
HARI_DASH=()
_siapkan_hari() {
  [ "${#HARI_YMD[@]}" -gt 0 ] && return
  local i=0 line
  while [ "$i" -le 31 ]; do
    line="$(date_minus_days "$i" "+%Y%m%d %Y-%m-%d")"
    HARI_YMD[$i]="${line%% *}"
    HARI_DASH[$i]="${line#* }"
    i=$((i+1))
  done
}

# Menulis log ke layar + mengumpulkan baris untuk CHANGES.
log() { printf '%s\n' "$*"; }

info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*"; }

# Menyimpan baris status ke CHANGES (dan terminal).
changes() { # $1=STATUS  $2=label  $3=pesan
  local line="[${NOW_JAM}] $1 : $2 — $3"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$CHANGES_FILE"
}

# Menyimpan baris ke file state (dibaca untuk manifest).
simpan_state() { # folder nama label tier status http latenn diff pesan saran
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >> "$STATE_FILE"
}

# =============================================================================
#  BAGIAN 5 — LOCK (cegah double-run)
# =============================================================================
ambil_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || echo '')"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      warn "Proses lain masih berjalan (PID $pid). Keluar agar tidak tumpang tindih."
      warn "Jika yakin tidak ada, hapus file .lock secara manual."
      exit 3
    fi
    warn "Lock basi (PID $pid tidak hidup). Menghapus .lock dan lanjut."
    rm -f "$LOCK_FILE"
  fi
  printf '%s\n' "$$" > "$LOCK_FILE"
}
lepas_lock() { rm -f "$LOCK_FILE"; }

# =============================================================================
#  BAGIAN 6 — HTTP + TERJEMAHAN ERROR
# =============================================================================

# Header tambahan per folder (auth API key dsb). Mengembalikan string argumen curl.
extra_curl() { # $1=folder
  case "$1" in
    nvd)
      [ -n "${NVD_API_KEY:-}" ] && printf '%s' "-H apiKey:${NVD_API_KEY}"
      ;;
    github)
      local h="-H Accept:application/vnd.github+json"
      [ -n "${GITHUB_TOKEN:-}" ] && h="$h -H Authorization:Bearer ${GITHUB_TOKEN}"
      printf '%s' "$h"
      ;;
    ransomware)
      [ -n "${RANSOMWARE_API_KEY:-}" ] && printf '%s' "-H X-API-KEY:${RANSOMWARE_API_KEY}"
      ;;
  esac
}

# curl_get: menjalankan curl dan mengisi CURL_EXIT, CURL_HTTP, CURL_TIME.
# $1=url $2=outfile $3=extra-args(string) $4=userpass
curl_get() {
  local url="$1" out="$2" extra="${3:-}" auth="${4:-}"
  local w
  if [ -n "$auth" ]; then
    w=$(curl -fsSL --retry 3 --retry-delay 5 --max-time 90 \
          -A "$USER_AGENT" -u "$auth" $extra \
          -o "$out" -w '%{http_code}|%{time_total}' "$url" 2>/dev/null)
  else
    w=$(curl -fsSL --retry 3 --retry-delay 5 --max-time 90 \
          -A "$USER_AGENT" $extra \
          -o "$out" -w '%{http_code}|%{time_total}' "$url" 2>/dev/null)
  fi
  CURL_EXIT=$?
  CURL_HTTP="${w%%|*}"
  CURL_TIME="${w##*|}"
  [ -z "$CURL_HTTP" ] && CURL_HTTP="000"
  [ -z "$CURL_TIME" ] && CURL_TIME="0"
}

# Terjemahan exit code curl → pesan + saran (bahasa Indonesia).
terjemah_error() { # $1 = exit code curl ; $2 = kode HTTP
  local ec="$1" http="$2"
  case "$ec" in
    0)
      if [ "$http" -ge 400 ] 2>/dev/null; then
        saran_http "$http"
      else
        printf 'OK|'
      fi
      ;;
    6)  printf 'Host tidak ditemukan (DNS gagal)|Periksa koneksi internet / DNS; pastikan URL sumber benar.' ;;
    7)  printf 'Koneksi ditolak|Host memblokir atau layanan sedang down; coba lagi nanti.' ;;
    22) saran_http "$http" ;;
    28) printf 'Timeout (>90s)|Layanan lambat/jaringan buruk; coba lagi atau naikkan --max-time.' ;;
    35) printf 'SSL/TLS gagal|Sertifikat bermasalah; perbarui CA atau hindari host tsb.' ;;
    *)  printf 'Gagal curl (exit %s)|Periksa URL, jaringan, dan opsi curl.' "$ec" ;;
  esac
}
saran_http() { # $1=kode http → "pesan|saran"
  case "$1" in
    400) printf 'HTTP 400 (permintaan tidak valid)|Periksa parameter/query pada URL sumber.' ;;
    401) printf 'HTTP 401 (butuh autentikasi)|Sediakan API key/kredensial lewat env.' ;;
    403) printf 'HTTP 403 (diblokir / User-Agent ditolak)|Perbaiki User-Agent (isi kontak) atau sediakan API key.' ;;
    404) printf 'HTTP 404 (endpoint pindah)|Perbarui URL sumber di konfigurasi.' ;;
    429) printf 'HTTP 429 (rate limit)|Tunggu, atau sediakan API key (mis. NVD_API_KEY).' ;;
    5*)  printf 'HTTP %s (kesalahan server sumber)|Coba lagi nanti.' "$1" ;;
    *)   printf 'HTTP %s (respons tak terduga)|Periksa endpoint dan kredensial.' "$1" ;;
  esac
}

# Validasi konten (Bagian 5): <100 byte / JSON-XML rusak/tidak lengkap → GAGAL.
validasi_konten() { # $1=file $2=ext → mengembalikan 0 valid, 1 rusak
  local f="$1" ext="${2:-}"
  [ -s "$f" ] || return 1
  # Karakter pertama/terakhir diambil dari potongan 256 byte lalu spasi/BOM/
  # newline dibuang, agar berkas sah yang berakhir newline tidak salah tolak.
  local first last
  first="$(head -c 256 "$f" | tr -d '[:space:]' | head -c 1)"
  last="$(tail -c 256 "$f" | tr -d '[:space:]' | tail -c 1)"
  # JSON kosong yang SAH ([] / {}) berarti "tidak ada hasil", bukan rusak.
  if [ "$ext" = "json" ] \
     && { [ "$first" = "[" ] || [ "$first" = "{" ]; } \
     && { [ "$last" = "]" ] || [ "$last" = "}" ]; }; then
    case "$(tr -d '[:space:]' < "$f")" in "[]"|"{}") return 0 ;; esac
  fi
  local sz
  sz="$(wc -c < "$f" | tr -d '[:space:]')"
  [ "${sz:-0}" -ge 100 ] || return 1
  case "$ext" in
    json)
      { [ "$first" = "{" ] || [ "$first" = "[" ]; } || return 1
      { [ "$last" = "}" ] || [ "$last" = "]" ]; } || return 1
      ;;
    xml)
      grep -q '<' "$f" || return 1
      [ "$last" = ">" ] || return 1
      ;;
    csv)
      # CSV: minimal ada 2 baris.
      [ "$(wc -l < "$f" | tr -d '[:space:]')" -ge 2 ] || return 1
      ;;
  esac
  return 0
}

# =============================================================================
#  DIFF TERSTRUKTUR (Bagian 5)
# =============================================================================
# Semua fungsi diff mengembalikan teks ringkas bahasa Indonesia (tanpa pipe).
diff_jumlah_baris() { # $1 old $2 new
  local a b
  a="$(wc -l < "$1" | tr -d '[:space:]')"
  b="$(wc -l < "$2" | tr -d '[:space:]')"
  printf 'baris %s → %s (%+d)' "$a" "$b" "$((b - a))"
}

diff_ofac() { # $1 old $2 new → jumlah entri
  local a b
  a="$(grep -c '^' "$1" 2>/dev/null || echo 0)"
  b="$(grep -c '^' "$2" 2>/dev/null || echo 0)"
  printf 'entri sanksi %s → %s (%+d)' "$a" "$b" "$((b - a))"
}

cve_ids() { grep -o 'CVE-[0-9][0-9-]*' "$1" 2>/dev/null | sort -u; }

diff_kev() { # $1 old $2 new → CVE baru
  local baru
  baru="$(comm -13 <(cve_ids "$1") <(cve_ids "$2") 2>/dev/null | paste -sd, -)"
  if [ -n "$baru" ]; then
    printf 'CVE baru masuk KEV: %s' "$baru"
  else
    printf 'tidak ada CVE baru di KEV (jumlah tetap %s)' "$(cve_ids "$2" | wc -l | tr -d '[:space:]')"
  fi
}

diff_bmkg() { # $1 old $2 new → jumlah + magnitudo tertinggi
  local n max
  n="$(grep -o '"Magnitude"' "$2" 2>/dev/null | wc -l | tr -d '[:space:]')"
  max="$(grep -o '"Magnitude":"[0-9.]*"' "$2" 2>/dev/null | sed 's/[^0-9.]//g' | sort -g | tail -1)"
  printf 'kejadian: %s · magnitudo tertinggi: %s' "${n:-0}" "${max:-n/a}"
}

diff_usgs() { # $1 old $2 new → jumlah + magnitudo tertinggi (kolom 5)
  local n max
  n="$(( $(wc -l < "$2" | tr -d '[:space:]') - 1 ))"
  [ "$n" -lt 0 ] && n=0
  max="$(tail -n +2 "$2" | awk -F',' '{if ($5+0>m) m=$5+0} END{print m}' 2>/dev/null)"
  printf 'kejadian: %s · magnitudo tertinggi: %s' "$n" "${max:-n/a}"
}

diff_pageviews() { # $1 old $2 new → views terakhir vs sebelumnya
  local a b
  a="$(grep -o '"views":[0-9]*' "$2" 2>/dev/null | sed 's/[^0-9]//g' | tail -2 | head -1)"
  b="$(grep -o '"views":[0-9]*' "$2" 2>/dev/null | sed 's/[^0-9]//g' | tail -1)"
  if [ -n "$a" ] && [ "${a:-0}" -gt 0 ] 2>/dev/null; then
    local pct=$(( (b - a) * 100 / a ))
    printf 'views %s → %s (%+d%%)' "$a" "$b" "$pct"
  else
    printf 'views terakhir: %s' "${b:-n/a}"
  fi
}

diff_rss() { # $1 old $2 new → jumlah link baru
  local baru
  baru="$(comm -13 <(link_unik "$1") <(link_unik "$2") 2>/dev/null | grep -c '.' || true)"
  printf 'item baru: %s' "${baru:-0}"
}
link_unik() { grep -o '"link":"[^"]*"' "$1" 2>/dev/null | sort -u; }

# Dispatcher diff per sumber.
diff_sumber() { # folder nama old new
  local folder="$1" nama="$2" old="$3" new="$4"
  case "$folder/$nama" in
    ofac/sdn)          diff_ofac "$old" "$new" ;;
    cisa/kev)          diff_kev "$old" "$new" ;;
    bmkg/autogempa|bmkg/gempadirasakan) diff_bmkg "$old" "$new" ;;
    usgs/m25hari)      diff_usgs "$old" "$new" ;;
    firms/hotspot)     diff_jumlah_baris "$old" "$new" ;;
    wiki/pageviews_*)  diff_pageviews "$old" "$new" ;;
    rss/*)             diff_rss "$old" "$new" ;;
    *)                 diff_jumlah_baris "$old" "$new" ;;
  esac
}

# =============================================================================
#  SNAPSHOT
# =============================================================================
# Pencarian snapshot memakai glob bawaan bash (tanpa proses luar) — jauh lebih
# cepat di Windows. Nama snapshot selalu diawali 8 digit tanggal.
_terbaru_snapshot() { # $1=folder $2=nama → path snapshot terbaru (kosong bila tak ada)
  local folder="$1" nama="$2" last="" f
  for f in "$DATA_DIR/$folder"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-"$nama".*; do
    [ -e "$f" ] || continue
    if [ -z "$last" ] || [[ "$f" > "$last" ]]; then last="$f"; fi
  done
  printf '%s' "$last"
}

_jumlah_snapshot() { # $1=folder $2=nama → jumlah snapshot
  local folder="$1" nama="$2" n=0 f
  for f in "$DATA_DIR/$folder"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-"$nama".*; do
    [ -e "$f" ] && n=$((n+1))
  done
  printf '%d' "$n"
}

snapshot_terakhir() { # $1=folder $2=nama → snapshot terbaru SEBELUM hari ini (atau kosong)
  local folder="$1" nama="$2" last="" f base
  for f in "$DATA_DIR/$folder"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-"$nama".*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      "${TODAY}-"*) continue ;;
    esac
    if [ -z "$last" ] || [[ "$f" > "$last" ]]; then last="$f"; fi
  done
  printf '%s' "$last"
}

jumlah_file() { # $1=folder $2=nama
  _jumlah_snapshot "$1" "$2"
}

# =============================================================================
#  PROSES SATU SUMBER
# =============================================================================
proses_sumber() { # folder nama label url tier jadwal ext
  local folder="$1" nama="$2" label="$3" url="$4" tier="$5" jadwal="$6" ext="$7"

  # Gating jadwal.
  case "$jadwal" in
    senin)
      if [ "$(date +%u)" != "1" ]; then
        info "LEWAT : $label (khusus Senin)"
        simpan_state "$folder" "$nama" "$label" "$tier" "LEWAT" "000" "0" "" "khusus Senin" ""
        return
      fi
      ;;
    env:*)
      local evn="${jadwal#env:}"
      if [ -z "$(eval "printf '%s' \"\${$evn:-}\"")" ]; then
        info "LEWAT : $label (butuh env $evn)"
        simpan_state "$folder" "$nama" "$label" "$tier" "LEWAT" "000" "0" "" "butuh env $evn" ""
        return
      fi
      ;;
  esac

  # Substitusi token URL.
  url="${url//\{TODAY\}/$TODAY}"
  url="${url//\{TODAY_DASH\}/$TODAY_DASH}"
  url="${url//\{FROM_ISO\}/$(iso_minus24)}"
  url="${url//\{TO_ISO\}/$NOW_ISO}"
  url="${url//\{FROM_ISO_ENC\}/$(urlenc "$(iso_minus24_nvd)")}"
  url="${url//\{TO_ISO_ENC\}/$(urlenc "$(date -u +%Y-%m-%dT%H:%M:%S.000)")}"
  url="${url//\{FIRMS_KEY\}/${FIRMS_KEY:-}}"

  mkdir -p "$DATA_DIR/$folder"
  local target="$DATA_DIR/$folder/${TODAY}-${nama}.${ext}"
  local extra auth=""
  extra="$(extra_curl "$folder")"
  if [ "$folder" = "opensky" ] && [ -n "${OPENSKY_USER:-}" ] && [ -n "${OPENSKY_PASS:-}" ]; then
    auth="${OPENSKY_USER}:${OPENSKY_PASS}"
  fi

  info "AMBIL : $label …"
  curl_get "$url" "$target" "$extra" "$auth"

  # Gagal koneksi / HTTP error.
  if [ "$CURL_EXIT" -ne 0 ]; then
    local ter pesan saran
    ter="$(terjemah_error "$CURL_EXIT" "$CURL_HTTP")"
    pesan="${ter%%|*}"; saran="${ter##*|}"
    rm -f "$target"
    warn "GAGAL : $label (exit $CURL_EXIT, HTTP $CURL_HTTP) — $pesan"
    changes "GAGAL" "$label" "$pesan (HTTP $CURL_HTTP, exit $CURL_EXIT)"
    catat_error "$label" "$url" "$CURL_EXIT" "$CURL_HTTP" "$pesan" "$saran"
    simpan_state "$folder" "$nama" "$label" "$tier" "GAGAL" "$CURL_HTTP" "$CURL_TIME" "" "$pesan" "$saran"
    return
  fi

  # Validasi konten.
  if ! validasi_konten "$target" "$ext"; then
    warn "RUSAK : $label (konten <100B atau rusak/tidak lengkap)"
    changes "RUSAK" "$label" "konten rusak atau tidak lengkap (HTTP $CURL_HTTP)"
    catat_error "$label" "$url" "$CURL_EXIT" "$CURL_HTTP" "Konten rusak/tidak lengkap" "Cek endpoint; mungkin butuh header/auth atau server mengirim halaman error."
    rm -f "$target"
    simpan_state "$folder" "$nama" "$label" "$tier" "RUSAK" "$CURL_HTTP" "$CURL_TIME" "" "konten rusak" "cek endpoint/auth"
    return
  fi

  # Dedup.
  local prev
  prev="$(snapshot_terakhir "$folder" "$nama")"
  if [ -n "$prev" ] && cmp -s "$prev" "$target"; then
    rm -f "$target"
    info "SAMA  : $label"
    changes "SAMA" "$label" "identik dengan snapshot terakhir"
    simpan_state "$folder" "$nama" "$label" "$tier" "SAMA" "$CURL_HTTP" "$CURL_TIME" "" "" ""
    return
  fi

  # Ada perubahan → jalankan mesin diff.
  local ringkasan="snapshot baru"
  if [ -n "$prev" ]; then
    ringkasan="$(diff_sumber "$folder" "$nama" "$prev" "$target")"
    printf '%s\n' "- PERUBAHAN $label: $ringkasan" >> "$RINGKAS_FILE"
    printf '\n## PERUBAHAN — %s\n- %s\n' "$label" "$ringkasan" >> "$CHANGES_FILE"
    changes "PERUBAHAN" "$label" "$ringkasan"
  else
    changes "OK" "$label" "snapshot pertama (HTTP $CURL_HTTP, ${CURL_TIME}s)"
  fi

  # Anomali pageviews (khusus *_pageviews_*).
  if [ "$nama" = "pageviews" ]; then
    periksa_anomali "$label" "$target"
  fi

  # Pemantauan kata kunci (headline baru).
  if [ "$ext" = "json" ] && [ "$tier" = "snippet" ]; then
    pindai_watch "$label" "$prev" "$target"
  fi

  simpan_state "$folder" "$nama" "$label" "$tier" "OK" "$CURL_HTTP" "$CURL_TIME" "$ringkasan" "" ""
}

# =============================================================================
#  ANOMALI PAGEVIEWS
# =============================================================================
periksa_anomali() { # $1=label $2=file
  local label="$1" file="$2"
  local vals rata terakhir
  vals="$(grep -o '"views":[0-9]*' "$file" 2>/dev/null | sed 's/[^0-9]//g')"
  [ -z "$vals" ] && return
  terakhir="$(printf '%s\n' "$vals" | tail -1)"
  rata="$(printf '%s\n' "$vals" | awk '{s+=$1; n++} END{if(n>0) printf "%d", s/n; else print 0}')"
  [ "${rata:-0}" -le 0 ] && return
  local x=$(( terakhir * 100 / rata ))
  if [ "$x" -ge $(( ANOMALI_THRESHOLD * 100 )) ]; then
    local msg="$label — ${x}% rata-rata (nilai $terakhir vs rata $rata)"
    printf '%s\n' "$msg" >> "$ANOMALI_FILE"
    printf '%s\n' "- ANOMALI : $msg" >> "$RINGKAS_FILE"
    changes "ANOMALI" "$label" "${x}% rata-rata (nilai $terakhir vs rata $rata)"
  fi
}

# =============================================================================
#  WATCH (kata kunci pemantauan)
# =============================================================================
pindai_watch() { # $1=label $2=old $3=new
  local label="$1" old="$2" new="$3"
  # Ambil judul dari snapshot baru yang belum ada di lama.
  local judul lama
  judul="$(grep -o '"title":"[^"]*"' "$new" 2>/dev/null | sed 's/^"title":"//; s/"$//' | sort -u)"
  [ -z "$judul" ] && return
  if [ -n "$old" ] && [ -f "$old" ]; then
    lama="$(grep -o '"title":"[^"]*"' "$old" 2>/dev/null | sed 's/^"title":"//; s/"$//' | sort -u)"
    judul="$(comm -13 <(printf '%s\n' "$lama") <(printf '%s\n' "$judul") 2>/dev/null)"
  fi
  local kw lower
  while IFS= read -r j; do
    [ -z "$j" ] && continue
    lower="$(printf '%s' "$j" | tr '[:upper:]' '[:lower:]')"
    for kw in "${KEYWORDS_WATCH[@]}"; do
      local kl
      kl="$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in
        *"$kl"*)
          local m="WATCH : $kw — $j"
          printf '%s\n' "$m" >> "$WATCH_FILE"
          printf '%s\n' "- $m" >> "$RINGKAS_FILE"
          changes "WATCH" "$kl" "$j"
          ;;
      esac
    done
  done <<EOF
$judul
EOF
}

# =============================================================================
#  LAPORAN ERROR TERSTRUKTUR (data/errors/ DI-COMMIT)
# =============================================================================
catat_error() { # label url exit http pesan saran
  mkdir -p "$ERRORS_DIR"
  local f="$ERRORS_DIR/${TODAY}.md"
  [ -f "$f" ] || printf '# Laporan error — %s\n\n' "$TODAY_DASH" > "$f"
  {
    printf -- '## [%s] %s\n' "$NOW_JAM" "$1"
    printf -- '- URL: %s\n' "$2"
    printf -- '- Exit code: %s · HTTP: %s\n' "$3" "$4"
    printf -- '- Pesan: %s\n' "$5"
    printf -- '- Saran: %s\n\n' "$6"
  } >> "$f"
}

# =============================================================================
#  PROSES WIKIPEDIA PAGEVIEWS
# =============================================================================
proses_wiki() {
  local mulai akhir
  mulai="$(date_minus_days 7 +%Y%m%d)"
  akhir="$(date +%Y%m%d)"
  local baris
  baris="$(printf '%s\n' "$WIKI_ARTICLES" | grep -v '^[[:space:]]*$')"
  local IFS_OLD="$IFS"
  IFS='
'
  for ent in $baris; do
    IFS="$IFS_OLD"
    local label="${ent%%|*}" art="${ent##*|}"
    [ -z "$art" ] && art="$label"
    local folder="wiki" nama="pageviews_${art}"
    local url="https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/${WIKI_PROJECT}/all-access/user/${art}/daily/${mulai}/${akhir}"
    mkdir -p "$DATA_DIR/$folder"
    local target="$DATA_DIR/$folder/${TODAY}-${nama}.json"
    info "AMBIL : Wikipedia pageviews ($label) …"
    curl_get "$url" "$target" "$(extra_curl wiki)" ""
    if [ "$CURL_EXIT" -ne 0 ]; then
      local ter pesan saran; ter="$(terjemah_error "$CURL_EXIT" "$CURL_HTTP")"
      pesan="${ter%%|*}"; saran="${ter##*|}"
      rm -f "$target"
      changes "GAGAL" "Wikipedia $label" "$pesan (HTTP $CURL_HTTP)"
      catat_error "Wikipedia $label" "$url" "$CURL_EXIT" "$CURL_HTTP" "$pesan" "$saran"
      simpan_state "$folder" "$nama" "Wikipedia: $label" "full" "GAGAL" "$CURL_HTTP" "$CURL_TIME" "" "$pesan" "$saran"
      continue
    fi
    if ! validasi_konten "$target" json; then
      changes "RUSAK" "Wikipedia $label" "respons pageviews rusak"
      catat_error "Wikipedia $label" "$url" "$CURL_EXIT" "$CURL_HTTP" "Konten rusak" "Cek judul artikel & rentang tanggal."
      rm -f "$target"
      simpan_state "$folder" "$nama" "Wikipedia: $label" "full" "RUSAK" "$CURL_HTTP" "$CURL_TIME" "" "rusak" "cek judul"
      continue
    fi
    local prev; prev="$(snapshot_terakhir "$folder" "$nama")"
    if [ -n "$prev" ] && cmp -s "$prev" "$target"; then
      rm -f "$target"; changes "SAMA" "Wikipedia $label" "identik"
      simpan_state "$folder" "$nama" "Wikipedia: $label" "full" "SAMA" "$CURL_HTTP" "$CURL_TIME" "" "" ""
      continue
    fi
    local ring="snapshot pertama"
    if [ -n "$prev" ]; then
      ring="$(diff_pageviews "$prev" "$target")"
      printf '\n## PERUBAHAN — Wikipedia %s\n- %s\n' "$label" "$ring" >> "$CHANGES_FILE"
    fi
    changes "OK" "Wikipedia $label" "$ring"
    periksa_anomali "Wikipedia $label" "$target"
    simpan_state "$folder" "$nama" "Wikipedia: $label" "full" "OK" "$CURL_HTTP" "$CURL_TIME" "$ring" "" ""
  done
  IFS="$IFS_OLD"
}

# =============================================================================
#  PROSES RSS BERITA (tier snippet; FETCH_FULL_TEXT → lokal)
# =============================================================================
# Ekstrak item RSS → JSON {title,link,snippet,wayback} satu per baris (array).
rss_ke_json() { # $1=xml $2=nama → cetak array JSON
  awk -v MAX="$SNIPPET_MAX" '
    function bersih(s){
      gsub(/<!\[CDATA\[/,"",s); gsub(/\]\]>/,"",s);
      gsub(/<[^>]*>/,"",s);
      gsub(/&amp;/,"\\&",s); gsub(/&lt;/,"<",s); gsub(/&gt;/,">",s);
      gsub(/&quot;/,"\"",s); gsub(/&#39;/,sprintf("%c",39),s);
      gsub(/[\t\r\n]+/," ",s); sub(/^ +/,"",s); sub(/ +$/,"",s);
      if (length(s)>MAX) s=substr(s,1,MAX);
      return s;
    }
    function esc(s){
      gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s);
      gsub(/\t/," ",s); gsub(/[\r\n]/," ",s);
      return s;
    }
    BEGIN{ print "["; n=0; inItem=0; title=""; link=""; desc="" }
    /<item>/ { inItem=1; title=""; link=""; desc=""; next }
    /<\/item>/ {
      if(inItem){
        t=bersih(title); l=bersih(link); d=bersih(desc);
        if(l!=""){
          way="https://web.archive.org/web/" l;
          if(n>0) print ",";
          printf "  {\"title\":\"%s\",\"link\":\"%s\",\"snippet\":\"%s\",\"wayback\":\"%s\"}", esc(t), esc(l), esc(d), esc(way);
          n++;
        }
      }
      inItem=0; next
    }
    inItem && /<title>/ { x=$0; sub(/.*<title/,"",x); sub(/>/,"",x); title=x }
    inItem && /<link>/  { x=$0; sub(/.*<link/,"",x); sub(/>/,"",x); link=x }
    inItem && /<description>/ { x=$0; sub(/.*<description/,"",x); sub(/>/,"",x); desc=x }
    END{ printf "\n]\n" }
  ' "$1"
}

proses_rss() {
  local baris
  baris="$(printf '%s\n' "$RSS_FEEDS" | grep -v '^[[:space:]]*$')"
  local IFS_OLD="$IFS"
  IFS='
'
  for ent in $baris; do
    IFS="$IFS_OLD"
    local nama="${ent%%|*}" url="${ent##*|}"
    local folder="rss"
    # Nama berkas memakai awalan rss_ agar SAMA dengan `nama` di state/manifest,
    # sehingga dedup, diff, dan pencarian snapshot menemukan berkasnya.
    local target="$DATA_DIR/$folder/${TODAY}-rss_${nama}.json"
    mkdir -p "$DATA_DIR/$folder"
    info "AMBIL : RSS $nama (tier snippet) …"
    local raw="$TMPD/rss_${nama}.xml"
    curl_get "$url" "$raw" "" ""
    if [ "$CURL_EXIT" -ne 0 ]; then
      local ter pesan saran; ter="$(terjemah_error "$CURL_EXIT" "$CURL_HTTP")"
      pesan="${ter%%|*}"; saran="${ter##*|}"
      rm -f "$raw"
      changes "GAGAL" "RSS $nama" "$pesan (HTTP $CURL_HTTP)"
      catat_error "RSS $nama" "$url" "$CURL_EXIT" "$CURL_HTTP" "$pesan" "$saran"
      simpan_state "$folder" "rss_${nama}" "RSS: $nama" "snippet" "GAGAL" "$CURL_HTTP" "$CURL_TIME" "" "$pesan" "$saran"
      continue
    fi
    if ! grep -q '<item' "$raw" 2>/dev/null; then
      changes "RUSAK" "RSS $nama" "feed tanpa item / rusak"
      catat_error "RSS $nama" "$url" "$CURL_EXIT" "$CURL_HTTP" "Feed kosong/rusak" "Verifikasi URL feed di browser."
      rm -f "$raw"
      simpan_state "$folder" "rss_${nama}" "RSS: $nama" "snippet" "RUSAK" "$CURL_HTTP" "$CURL_TIME" "" "feed rusak" "verifikasi URL"
      continue
    fi
    rss_ke_json "$raw" "$nama" > "$target"
    rm -f "$raw"

    # TIER-LOKAL: opsional unduh teks penuh ke data/news-full/ (gitignored).
    if [ "${FETCH_FULL_TEXT:-0}" = "1" ]; then
      unduh_teks_penuh "$nama" "$target"
    fi

    local prev; prev="$(snapshot_terakhir "$folder" "rss_${nama}")"
    if [ -n "$prev" ] && cmp -s "$prev" "$target"; then
      rm -f "$target"; changes "SAMA" "RSS $nama" "identik"
      simpan_state "$folder" "rss_${nama}" "RSS: $nama" "snippet" "SAMA" "$CURL_HTTP" "$CURL_TIME" "" "" ""
      continue
    fi
    local ring="snapshot pertama"
    if [ -n "$prev" ]; then
      ring="$(diff_rss "$prev" "$target")"
      printf '\n## PERUBAHAN — RSS %s\n- %s\n' "$nama" "$ring" >> "$CHANGES_FILE"
    fi
    changes "OK" "RSS $nama" "$ring"
    pindai_watch "RSS $nama" "$prev" "$target"
    simpan_state "$folder" "rss_${nama}" "RSS: $nama" "snippet" "OK" "$CURL_HTTP" "$CURL_TIME" "$ring" "" ""
  done
  IFS="$IFS_OLD"
}

# TIER-LOKAL: unduh halaman artikel ke data/news-full/ (TIDAK pernah di-commit).
unduh_teks_penuh() { # $1=nama feed $2=file json feed
  local nama="$1" feed="$2"
  mkdir -p "$NEWSFULL_DIR/$TODAY"
  local n=0
  grep -o '"link":"[^"]*"' "$feed" 2>/dev/null | sed 's/^"link":"//; s/"$//' | head -20 | while IFS= read -r link; do
    case "$link" in
      *paywall*|*subscribe*) continue ;;
    esac
    sleep 1  # rate-limit 1 req/detik per domain
    local out="$NEWSFULL_DIR/$TODAY/${nama}_$(printf '%s' "$link" | cksum | awk '{print $1}').html"
    curl -fsSL --max-time 30 -A "$USER_AGENT" -o "$out" "$link" 2>/dev/null || rm -f "$out"
    n=$((n+1))
  done
  info "TIER-LOKAL: teks penuh $nama disimpan di data/news-full/$TODAY/ (gitignored)"
}

# =============================================================================
#  RETENSI (hapus news-full lebih tua dari RETENTION_DAYS)
# =============================================================================
retensi() {
  [ -d "$NEWSFULL_DIR" ] || return
  local batas dihapus=0 d
  batas="$(date_minus_days "$RETENTION_DAYS" +%Y%m%d)"
  for d in "$NEWSFULL_DIR"/*; do
    [ -d "$d" ] || continue
    local nama; nama="$(basename "$d")"
    case "$nama" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        if [ "$nama" -lt "$batas" ]; then rm -rf "$d"; dihapus=$((dihapus+1)); fi ;;
    esac
  done
  info "RETENSI: menghapus $dihapus folder news-full (> $RETENTION_DAYS hari)"
}

# =============================================================================
#  SKOR KESEHATAN 30 HARI (parse CHANGES-*.md)
# =============================================================================
# Indeks skor dibangun SEKALI (satu proses awk untuk 30 file CHANGES), lalu
# tiap label cukup satu pencarian — banyak lebih cepat daripada 60 grep.
SKOR_INDEXED=0
_indeks_skor() {
  [ "$SKOR_INDEXED" = "1" ] && return
  SKOR_INDEXED=1
  _siapkan_hari
  local files="" i f
  for i in $(seq 0 29); do
    f="$DATA_DIR/CHANGES-${HARI_YMD[$i]}.md"
    [ -f "$f" ] && files="$files $f"
  done
  : > "$TMPD/skor.tsv"
  [ -z "$files" ] && return
  # shellcheck disable=SC2086
  awk '
    /^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] / {
      line=substr($0,12)
      p=index(line," : "); if (p==0) next
      st=substr(line,1,p-1)
      rest=substr(line,p+3)
      q=index(rest," \342\200\224 "); if (q>0) lab=substr(rest,1,q-1); else lab=rest
      total[lab]++
      if (st=="OK" || st=="SAMA") ok[lab]++
    }
    END { for (l in total) printf "%s\t%d\t%d\n", l, ok[l]+0, total[l]+0 }
  ' $files > "$TMPD/skor.tsv"
}

skor_kesehatan() { # $1=label → % OK (0-100)
  _indeks_skor
  local label="$1" res
  res="$(awk -F'\t' -v l="$label" '$1==l { printf "%d", ($3>0 ? $2*100/$3 : 0); exit }' "$TMPD/skor.tsv" 2>/dev/null)"
  printf '%s' "${res:-0}"
}

# =============================================================================
#  BAGIAN 7 — MANIFEST (docs/data.json & docs/data.js)
# =============================================================================
riwayat_30() { # $1=folder $2=nama $3=ext → deret 1/0 (30 hari)
  _siapkan_hari
  local folder="$1" nama="$2" ext="$3" i d out=""
  for i in $(seq 29 -1 0); do
    d="${HARI_YMD[$i]}"
    if [ -f "$DATA_DIR/$folder/${d}-${nama}.${ext}" ]; then out="$out 1"; else out="$out 0"; fi
  done
  printf '%s' "$out"
}

status_count() { # $1=status → hitung di STATE_FILE (selalu satu angka)
  local n; n="$(grep -c "|$1|" "$STATE_FILE" 2>/dev/null)"; printf '%s' "${n:-0}"
}

build_manifest() {
  mkdir -p "$DOCS_DIR"
  local jml_ok jml_sama jml_gagal jml_rusak jml_lewat jml_anomali jml_watch
  jml_ok="$(status_count OK)"
  jml_sama="$(status_count SAMA)"
  jml_gagal="$(status_count GAGAL)"
  jml_rusak="$(status_count RUSAK)"
  jml_lewat="$(status_count LEWAT)"
  jml_anomali="$( [ -f "$ANOMALI_FILE" ] && wc -l < "$ANOMALI_FILE" | tr -d '[:space:]' || echo 0 )"
  jml_watch="$( [ -f "$WATCH_FILE" ] && wc -l < "$WATCH_FILE" | tr -d '[:space:]' || echo 0 )"

  {
    printf '{\n'
    printf '  "proyek": "%s",\n' "$(jesc "$PROJECT_NAME")"
    printf '  "tanggal": "%s",\n' "$TODAY_DASH"
    printf '  "dibuat": "%s",\n' "$NOW_ISO"
    printf '  "situs": "%s",\n' "$(jesc "$SITE_BASE")"
    printf '  "ringkasan": { "ok": %s, "sama": %s, "gagal": %s, "rusak": %s, "lewat": %s, "anomali": %s, "watch": %s },\n' \
      "$jml_ok" "$jml_sama" "$jml_gagal" "$jml_rusak" "$jml_lewat" "$jml_anomali" "$jml_watch"

    # --- daftar sumber ---
    printf '  "sumber": [\n'
    local first=1
    if [ -f "$STATE_FILE" ]; then
      while IFS='|' read -r folder nama label tier status http latenn diff pesan saran; do
        [ -z "$folder" ] && continue
        local ext="json"
        case "$folder" in
          ofac|usgs|firms) ext="csv" ;;
          cisa) ext="$( [ "$nama" = "advisories" ] && echo xml || echo json )" ;;
        esac
        # Pencarian snapshot lewat glob bash (tanpa ls|grep|sort|tail) — jauh
        # lebih cepat di Windows; nama berkas diambil dari basename.
        local snap; snap="$(_terbaru_snapshot "$folder" "$nama")"; snap="${snap##*/}"
        local jumlah; jumlah="$(jumlah_file "$folder" "$nama")"
        local skor; skor="$(skor_kesehatan "$label")"
        local riwayat; riwayat="$(riwayat_30 "$folder" "$nama" "$ext")"
        local riwayat_arr="${riwayat// /,}"; riwayat_arr="${riwayat_arr#,}"
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        printf '    { "folder":"%s","nama":"%s","label":"%s","tier":"%s","status":"%s","http":"%s","laten":%s,' \
          "$(jesc "$folder")" "$(jesc "$nama")" "$(jesc "$label")" "$(jesc "$tier")" "$(jesc "$status")" "$(jesc "$http")" "${latenn:-0}"
        printf '"snapshot":"%s","jumlah_file":%s,"skor":%s,"riwayat":[%s],' \
          "$(jesc "$snap")" "${jumlah:-0}" "${skor:-0}" "$riwayat_arr"
        printf '"diff":"%s","pesan_error":"%s","saran":"%s" }' \
          "$(jesc "${diff:-}")" "$(jesc "${pesan:-}")" "$(jesc "${saran:-}")"
      done < "$STATE_FILE"
    fi
    printf '\n  ],\n'

    # --- anomali ---
    printf '  "anomali": ['
    if [ -f "$ANOMALI_FILE" ]; then
      local fa=1
      while IFS= read -r a; do
        [ -z "$a" ] && continue
        [ "$fa" -eq 0 ] && printf ','
        fa=0
        printf ' "%s"' "$(jesc "$a")"
      done < "$ANOMALI_FILE"
    fi
    printf ' ],\n'

    # --- watch ---
    printf '  "watch": ['
    if [ -f "$WATCH_FILE" ]; then
      local fw=1
      while IFS= read -r w; do
        [ -z "$w" ] && continue
        [ "$fw" -eq 0 ] && printf ','
        fw=0
        printf ' "%s"' "$(jesc "$w")"
      done < "$WATCH_FILE"
    fi
    printf ' ],\n'

    # --- log 14 hari ---
    printf '  "log": [\n'
    _siapkan_hari
    local fl=1 i
    for i in $(seq 0 13); do
      local d="${HARI_YMD[$i]}"
      local f="$DATA_DIR/CHANGES-${d}.md"
      [ -f "$f" ] || continue
      local ok=0 ggl=0 ln
      while IFS= read -r ln; do
        case "$ln" in
          *" OK : "*|*" SAMA : "*) ok=$((ok+1)) ;;
          *" GAGAL : "*|*" RUSAK : "*) ggl=$((ggl+1)) ;;
        esac
      done < "$f"
      [ "$fl" -eq 0 ] && printf ',\n'
      fl=0
      printf '    { "tanggal":"%s","ok":%s,"gagal":%s,"file":"data/CHANGES-%s.md" }' "${HARI_DASH[$i]}" "$ok" "$ggl" "$d"
    done
    printf '\n  ],\n'

    # --- tabel: gempa, cve, kev, rss ---
    printf '  "tabel": {\n'
    tabel_gempa
    printf ',\n'
    tabel_cve
    printf ',\n'
    tabel_kev
    printf ',\n'
    tabel_rss
    printf '\n  }\n'
    printf '}\n'
  } > "$DOCS_DIR/data.json"

  # data.js identik isi
  { printf 'window.DATA = '; cat "$DOCS_DIR/data.json"; printf ';\n'; } > "$DOCS_DIR/data.js"
  info "MANIFEST: docs/data.json + docs/data.js ditulis ulang."
}

# Helper tabel (masing-masing mencetak properti JSON tanpa pembungkus objek luar).
ambil_latest() { # $1=folder $2=nama $3=ext → path terbaru (termasuk hari ini), kosong bila tak ada
  _terbaru_snapshot "$1" "$2"
}

tabel_gempa() {
  printf '    "gempa": ['
  local first=1 f row mag wil tgl
  f="$(ambil_latest bmkg autogempa json)"
  if [ -n "$f" ] && [ -f "$f" ]; then
    mag="$(grep -o '"Magnitude":"[^"]*"' "$f" | head -1 | sed 's/.*:"//; s/"//')"
    wil="$(grep -o '"Wilayah":"[^"]*"' "$f" | head -1 | sed 's/.*:"//; s/"//')"
    tgl="$(grep -o '"Tanggal":"[^"]*"' "$f" | head -1 | sed 's/.*:"//; s/"//')"
    printf ' {"sumber":"BMKG","magnitudo":"%s","lokasi":"%s","waktu":"%s"}' "$(jesc "$mag")" "$(jesc "$wil")" "$(jesc "$tgl")"
    first=0
  fi
  local fu; fu="$(ambil_latest usgs m25hari csv)"
  if [ -n "$fu" ] && [ -f "$fu" ]; then
    # 5 gempa terkuat. Loop memakai process substitution agar variabel `first`
    # (koma pemisah JSON) tidak hilang di dalam subshell pipa.
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      local t m place
      t="$(printf '%s' "$row" | cut -d',' -f1)"
      m="$(printf '%s' "$row" | cut -d',' -f5)"
      # `place` adalah field ber-kutip (kolom 14) dan boleh memuat koma.
      place="$(printf '%s' "$row" | grep -o '"[^"]*"' | head -1 | sed 's/^"//; s/"$//')"
      [ "$first" -eq 0 ] && printf ','
      printf ' {"sumber":"USGS","magnitudo":"%s","lokasi":"%s","waktu":"%s"}' "$(jesc "$m")" "$(jesc "$place")" "$(jesc "$t")"
      first=0
    done < <(tail -n +2 "$fu" | sort -t',' -k5 -g | tail -5)
  fi
  printf ' ]'
}

tabel_cve() {
  printf '    "cve": ['
  local f; f="$(ambil_latest nvd cve json)"
  if [ -n "$f" ] && [ -f "$f" ]; then
    local first=1 id
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      [ "$first" -eq 0 ] && printf ','
      printf ' {"id":"%s"}' "$(jesc "$id")"
      first=0
    done < <(grep -o '"id":"CVE-[0-9][0-9-]*"' "$f" | sed 's/.*:"//; s/"//' | sort -u | head -40)
  fi
  printf ' ]'
}

tabel_kev() {
  printf '    "kev": ['
  local f; f="$(ambil_latest cisa kev json)"
  if [ -n "$f" ] && [ -f "$f" ]; then
    # CISA KEV = JSON rapi (multi-baris, ada spasi setelah ':'), jadi regex
    # satu-baris tidak cocok. Ambil id & vendor terpisah (urutannya sejajar per
    # entri) lalu pasangkan.
    local first=1 cid ven
    local ids vens
    ids="$(grep -o '"cveID"[[:space:]]*:[[:space:]]*"CVE-[0-9-]*"' "$f" 2>/dev/null | sed 's/.*"\(CVE-[0-9-]*\)"/\1/' | head -20)"
    vens="$(grep -o '"vendorProject"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | head -20)"
    while IFS='|' read -r cid ven; do
      [ -z "$cid" ] && continue
      [ "$first" -eq 0 ] && printf ','
      printf ' {"id":"%s","vendor":"%s"}' "$(jesc "$cid")" "$(jesc "$ven")"
      first=0
    done < <(paste -d'|' <(printf '%s\n' "$ids") <(printf '%s\n' "$vens"))
  fi
  printf ' ]'
}

tabel_rss() {
  printf '    "rss": ['
  local first=1 nama f it
  for nama in bbc aljazeera guardian cna cnbcindonesia cnnindonesia antara; do
    f="$(ambil_latest rss "rss_${nama}" json)"
    [ -n "$f" ] && [ -f "$f" ] || continue
    # 5 item pertama per feed.
    while IFS= read -r it; do
      [ -z "$it" ] && continue
      [ "$first" -eq 0 ] && printf ','
      # `${it#\{}` sudah memuat kurung tutup milik item, jadi jangan ditambah '}'.
      printf ' {"feed":"%s",%s' "$(jesc "$nama")" "${it#\{}"
      first=0
    done < <(grep -o '{"title":"[^"]*","link":"[^"]*","snippet":"[^"]*","wayback":"[^"]*"}' "$f" 2>/dev/null | head -5)
  done
  printf ' ]'
}

# =============================================================================
#  BAGIAN 7 — FEED RSS TRACKER (docs/feed.xml)
# =============================================================================
build_feed() {
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<rss version="2.0"><channel>\n'
    printf '  <title>%s — tracker perubahan</title>\n' "$(jesc "$PROJECT_NAME")"
    printf '  <link>%s</link>\n' "$(jesc "$SITE_BASE")"
    printf '  <description>Ringkasan harian perubahan, kegagalan, anomali, dan kata kunci pemantauan.</description>\n'
    printf '  <language>id</language>\n'
    # Kumpulkan item dari CHANGES terbaru (maks RSS_MAX_ITEMS).
    _siapkan_hari
    local emitted=0 i pub
    pub="$(date -R 2>/dev/null || date)"
    for i in $(seq 0 30); do
      [ "$emitted" -ge "$RSS_MAX_ITEMS" ] && break
      local d f
      d="${HARI_YMD[$i]}"
      f="$DATA_DIR/CHANGES-${d}.md"
      [ -f "$f" ] || continue
      while IFS= read -r line; do
        [ "$emitted" -ge "$RSS_MAX_ITEMS" ] && break
        case "$line" in
          *" PERUBAHAN : "*|*" GAGAL : "*|*" ANOMALI : "*|*" WATCH : "*|*" RUSAK : "*)
            local jud="${line#*] }"
            printf '  <item>\n'
            printf '    <title>%s</title>\n' "$(jesc "$jud")"
            printf '    <link>%s#log</link>\n' "$(jesc "$SITE_BASE")"
            printf '    <guid isPermaLink="false">%s-%s</guid>\n' "$d" "$emitted"
            printf '    <pubDate>%s</pubDate>\n' "$pub"
            printf '  </item>\n'
            emitted=$((emitted+1))
            ;;
        esac
      done < "$f"
    done
    printf '</channel></rss>\n'
  } > "$DOCS_DIR/feed.xml"
  info "FEED: docs/feed.xml ditulis ulang ($emitted item)."
}

# =============================================================================
#  BAGIAN 5 — TELEGRAM DIGEST (opsional)
# =============================================================================
telegram_digest() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    info "TELEGRAM: dilewati (env tidak diisi)."
    return
  fi
  local pesan
  pesan="Ringkasan harian $PROJECT_NAME ($TODAY_DASH)
OK: $(status_count OK) · SAMA: $(status_count SAMA) · GAGAL: $(status_count GAGAL) · RUSAK: $(status_count RUSAK)

GAGAL:
$(grep '^GAGAL|' "$STATE_FILE" 2>/dev/null | awk -F'|' '{print "- "$3": "$9" ("$10")"}' | head -20)

PERUBAHAN/ANOMALI/WATCH:
$( [ -f "$RINGKAS_FILE" ] && head -c 1500 "$RINGKAS_FILE" || echo '-')"

  pesan="$(printf '%s' "$pesan" | cut -c1-$TELEGRAM_LIMIT)"
  local resp
  resp="$(curl -fsSL --max-time 30 -A "$USER_AGENT" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${pesan}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>/dev/null)"
  if [ $? -eq 0 ]; then info "TELEGRAM: digest terkirim."; else warn "TELEGRAM: gagal kirim (dilanjutkan)."; fi
}

# =============================================================================
#  BAGIAN 5 — TAG BULANAN
# =============================================================================
tag_bulanan() {
  local ada
  ada="$(git tag -l "$THISMONTH" 2>/dev/null)"
  if [ -n "$ada" ]; then info "TAG: $THISMONTH sudah ada."; return; fi
  # Hanya jika ada commit.
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git tag "$THISMONTH" 2>/dev/null && info "TAG: $THISMONTH dibuat."
    git push origin "$THISMONTH" 2>/dev/null || warn "TAG: push tag gagal (dilanjutkan)."
  fi
}

# =============================================================================
#  BAGIAN 5 — GIT FINALIZE
# =============================================================================
git_finalize() {
  cd "$BASE_DIR" || return
  # Pengaman: hanya urus repo MILIK folder ini. Jika tidak ada .git di sini
  # (mis. folder ini berada di dalam repo lain), JANGAN jalankan git add -A —
  # itu bisa menyapu seluruh work tree repo induk. Lewati dengan pesan jelas.
  if [ ! -d "$BASE_DIR/.git" ] && [ ! -f "$BASE_DIR/.git" ]; then
    warn "GIT: $BASE_DIR bukan root repositori git — lewati commit/push."
    warn "     Jalankan 'git init' di folder ini (lihat README) lalu coba lagi."
    return
  fi
  git add -A 2>/dev/null
  if git diff --cached --quiet 2>/dev/null; then
    info "GIT: tidak ada perubahan — keluar tanpa commit."
    return
  fi
  local stat ringkas
  stat="$(git diff --cached --stat | tail -1)"
  ringkas="$( [ -f "$RINGKAS_FILE" ] && head -c 1500 "$RINGKAS_FILE" || echo '-')"
  git commit -q -m "Update harian ${TODAY_DASH}

${ringkas}

${stat}" 2>/dev/null && info "GIT: commit dibuat."

  if git push origin HEAD 2>/dev/null; then
    info "GIT: push origin HEAD berhasil."
  else
    warn "GIT: push gagal. Lakukan login lalu push manual:"
    warn "  gh auth login   (atau gunakan PAT)"
    warn "  git push origin HEAD"
  fi

  # REMOTE_EXTRA opsional.
  if [ -n "${REMOTE_EXTRA:-}" ]; then
    git push "$REMOTE_EXTRA" HEAD 2>/dev/null && info "GIT: push $REMOTE_EXTRA berhasil." || warn "GIT: push $REMOTE_EXTRA gagal."
  fi
  tag_bulanan
}

# =============================================================================
#  BAGIAN 6 — MODE --cek (diagnostik)
# =============================================================================
do_cek() {
  mkdir -p "$DATA_DIR" "$ERRORS_DIR"
  printf '%-32s %-10s %-6s %-8s %s\n' "SUMBER" "STATUS" "HTTP" "LATEN(s)" "SKOR30"
  printf '%s\n' "------------------------------------------------------------------------"
  local laporan="$ERRORS_DIR/cek-${TODAY}.md"
  printf '# Diagnostik %s\n\n' "$TODAY_DASH" > "$laporan"
  local baris; baris="$(printf '%s\n' "$SOURCES" | grep -v '^[[:space:]]*$')"
  local IFS_OLD="$IFS"; IFS='
'
  for ent in $baris; do
    IFS="$IFS_OLD"
    local folder nama label url tier jadwal ext
    folder="${ent%%|*}"; ent="${ent#*|}"
    nama="${ent%%|*}";   ent="${ent#*|}"
    label="${ent%%|*}";  ent="${ent#*|}"
    url="${ent%%|*}";    ent="${ent#*|}"
    tier="${ent%%|*}";   ent="${ent#*|}"
    jadwal="${ent%%|*}"; ext="${ent##*|}"
    # Substitusi token.
    url="${url//\{TODAY\}/$TODAY}"; url="${url//\{TODAY_DASH\}/$TODAY_DASH}"
    url="${url//\{FROM_ISO\}/$(iso_minus24)}"; url="${url//\{TO_ISO\}/$NOW_ISO}"
    url="${url//\{FROM_ISO_ENC\}/$(urlenc "$(iso_minus24_nvd)")}"; url="${url//\{TO_ISO_ENC\}/$(urlenc "$(date -u +%Y-%m-%dT%H:%M:%S.000)")}"
    url="${url//\{FIRMS_KEY\}/${FIRMS_KEY:-}}"
    if [ "${jadwal#env:}" != "$jadwal" ]; then
      local evn="${jadwal#env:}"
      if [ -z "$(eval "printf '%s' \"\${$evn:-}\"")" ]; then
        printf '%-32s %-10s\n' "$label" "LEWAT (butuh $evn)"
        printf -- '- %s: LEWAT (butuh env %s)\n' "$label" "$evn" >> "$laporan"
        continue
      fi
    fi
    local out="$TMPD/cek_${nama}"
    curl_get "$url" "$out" "$(extra_curl "$folder")" ""
    local status="OK"
    [ "$CURL_EXIT" -ne 0 ] && status="GAGAL"
    local skor; skor="$(skor_kesehatan "$label")"
    printf '%-32s %-10s %-6s %-8s %s%%\n' "$label" "$status" "$CURL_HTTP" "$CURL_TIME" "$skor"
    printf -- '- %s: %s (HTTP %s, %ss, skor %s%%)\n' "$label" "$status" "$CURL_HTTP" "$CURL_TIME" "$skor" >> "$laporan"
    rm -f "$out"
  done
  IFS="$IFS_OLD"
  info "Laporan diagnostik: $laporan (tidak di-commit)."
  info "Selesai --cek. Tidak ada snapshot/commit."
}

# =============================================================================
#  BAGIAN 6 — MODE --uji-error
# =============================================================================
do_uji_error() {
  mkdir -p "$DATA_DIR" "$ERRORS_DIR"
  log "== UJI SISTEM ERROR =="
  log "Menyuntik SATU URL palsu lewat pipeline yang sama (tanpa menulis file commit)."
  local url="https://sumber-palsu.invalid/tidak-ada.json"
  local out="$TMPD/uji_error.json"
  curl_get "$url" "$out" "" ""
  local ter pesan saran; ter="$(terjemah_error "$CURL_EXIT" "$CURL_HTTP")"
  pesan="${ter%%|*}"; saran="${ter##*|}"
  log "exit code : $CURL_EXIT"
  log "kode HTTP : $CURL_HTTP"
  log "latensi   : ${CURL_TIME}s"
  log "pesan     : $pesan"
  log "saran     : $saran"
  log ""
  log "Contoh entri yang AKAN ditulis ke data/errors/<YYYYMMDD>.md saat run nyata:"
  log "## [${NOW_JAM}] UJI-ERROR"
  log "- URL: $url"
  log "- Exit code: $CURL_EXIT · HTTP: $CURL_HTTP"
  log "- Pesan: $pesan"
  log "- Saran: $saran"
  rm -f "$out"
  info "Selesai --uji-error. Tidak ada file yang di-commit."
}

# =============================================================================
#  RINGKASAN / MAIN
# =============================================================================
proses_semua_sumber() {
  local baris; baris="$(printf '%s\n' "$SOURCES" | grep -v '^[[:space:]]*$')"
  local IFS_OLD="$IFS"; IFS='
'
  for ent in $baris; do
    IFS="$IFS_OLD"
    local folder nama label url tier jadwal ext
    folder="${ent%%|*}"; ent="${ent#*|}"
    nama="${ent%%|*}";   ent="${ent#*|}"
    label="${ent%%|*}";  ent="${ent#*|}"
    url="${ent%%|*}";    ent="${ent#*|}"
    tier="${ent%%|*}";   ent="${ent#*|}"
    jadwal="${ent%%|*}"; ext="${ent##*|}"
    proses_sumber "$folder" "$nama" "$label" "$url" "$tier" "$jadwal" "$ext"
  done
  IFS="$IFS_OLD"
}

main() {
  case "$MODE" in
    cek) do_cek; return ;;
    uji) do_uji_error; return ;;
  esac

  mkdir -p "$DATA_DIR" "$ERRORS_DIR" "$HISTORY_DIR" "$NEWSFULL_DIR" "$DOCS_DIR"
  : > "$STATE_FILE"; : > "$ANOMALI_FILE"; : > "$WATCH_FILE"; : > "$RINGKAS_FILE"
  printf '# Perubahan & status — %s\n\n' "$TODAY_DASH" > "$CHANGES_FILE"

  ambil_lock
  trap lepas_lock EXIT

  info "== $PROJECT_NAME — run $TODAY_DASH ($NOW_ISO) =="
  proses_semua_sumber
  proses_wiki
  proses_rss

  retensi
  build_manifest
  build_feed
  telegram_digest
  git_finalize

  info "== Selesai. OK=$(status_count OK) SAMA=$(status_count SAMA) GAGAL=$(status_count GAGAL) RUSAK=$(status_count RUSAK) =="
}

main "$@"
