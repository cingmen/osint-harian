#requires -version 5
# =============================================================================
#  osint-harian — tracker data publik harian (Windows / PowerShell)
#  Deterministik, TANPA API LLM. Perilaku identik dengan tracker-harian.sh.
#  Dependensi: curl.exe (bawaan Windows 10+) + git.
#  Kode: MIT (LICENSE) · Data: CC-BY 4.0 (LICENSE-DATA)
#
#  Penggunaan:
#    powershell -ExecutionPolicy Bypass -File tracker-harian.ps1            # harian
#    powershell -ExecutionPolicy Bypass -File tracker-harian.ps1 -Cek       # diagnostik
#    powershell -ExecutionPolicy Bypass -File tracker-harian.ps1 -UjiError  # uji error
#
#  Prinsip (Bagian 1): hanya data publik resmi; tanpa login; tanpa bypass
#  paywall; tanpa data pribadi perorangan (UU PDP). Berita TIGA TIER:
#    full    : dokumen resmi/lisensi terbuka -> boleh commit teks penuh
#    snippet : media komersial -> commit HANYA judul + link + kutipan <=300 char
#    lokal   : FETCH_FULL_TEXT=1 -> teks penuh HANYA ke data/news-full/ (gitignored)
#  Bukan nasihat hukum. Lihat README.md.
# =============================================================================

[CmdletBinding()]
param(
  [switch]$Cek,
  [switch]$UjiError
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# Karakter non-ASCII ditulis lewat kode agar skrip aman di PowerShell 5.1 (ANSI).
$DASH  = [string][char]0x2014   # em dash
$DOT   = [string][char]0x00B7   # middle dot
$ARROW = [string][char]0x2192   # panah kanan

# -----------------------------------------------------------------------------
#  BAGIAN 3 — KONFIGURASI (semua pengaturan ada di blok ini)
# -----------------------------------------------------------------------------

# --- Identitas (ubah hanya di sini) ---
$PROJECT_NAME = 'osint-harian'
$CONTACT      = 'https://cingmen.github.io/osint-harian'       # kontak di User-Agent (URL situs)
$SITE_BASE    = 'https://cingmen.github.io/osint-harian'     # URL absolut untuk feed.xml
$USER_AGENT   = "$PROJECT_NAME/1.0 (+https://github.com/$PROJECT_NAME; kontak: $CONTACT)"

# --- Ambang & retensi ---
$ANOMALI_THRESHOLD = 3
$RETENTION_DAYS    = 90
$RSS_MAX_ITEMS     = 50
$TELEGRAM_LIMIT    = 4000
$SNIPPET_MAX       = 300

# --- Kata kunci pemantauan (case-insensitive) ---
$KEYWORDS_WATCH = @('sanction', 'eruption', 'zero-day')

# --- Daftar sumber statis ---
#   Format: folder|nama|label|url|tier|jadwal|ext
$SOURCES = @'
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
'@ -split "`n"

# --- Artikel Wikipedia (pageviews 7 hari). Format: label|judul_artikel ---
$WIKI_ARTICLES = @'
Indonesia|Indonesia
Ibu Kota Nusantara|Ibu_Kota_Nusantara
Bank Sentral Asia|Bank_Central_Asia
'@ -split "`n"
$WIKI_PROJECT = 'id.wikipedia'

# --- RSS berita (tier snippet). Format: nama|url ---
$RSS_FEEDS = @'
bbc|https://feeds.bbci.co.uk/news/world/rss.xml
aljazeera|https://www.aljazeera.com/xml/rss/all.xml
guardian|https://www.theguardian.com/world/rss
cna|https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml
cnbcindonesia|https://www.cnbcindonesia.com/rss
cnnindonesia|https://www.cnnindonesia.com/rss
antara|https://www.antaranews.com/rss/top-news
'@ -split "`n"

# -----------------------------------------------------------------------------
#  Variabel runtime (jangan diubah kecuali tahu akibatnya)
# -----------------------------------------------------------------------------
$BASE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BASE_DIR) { $BASE_DIR = (Get-Location).Path }
$DATA_DIR     = Join-Path $BASE_DIR 'data'
$ERRORS_DIR   = Join-Path $DATA_DIR 'errors'
$HISTORY_DIR  = Join-Path $DATA_DIR 'history'
$NEWSFULL_DIR = Join-Path $DATA_DIR 'news-full'
$DOCS_DIR     = Join-Path $BASE_DIR 'docs'
$LOCK_FILE    = Join-Path $BASE_DIR '.lock'
$TMPD         = Join-Path ([System.IO.Path]::GetTempPath()) ('osint-harian-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TMPD | Out-Null
# UTF-8 TANPA BOM (Set-Content -Encoding UTF8 di PS 5.1 menambah BOM yang
# bisa merusak kolom pertama file state / CHANGES).
$UTF8NB = New-Object System.Text.UTF8Encoding($false)

$STATE_FILE   = Join-Path $TMPD 'state.tsv'
$ANOMALI_FILE = Join-Path $TMPD 'anomali.txt'
$WATCH_FILE   = Join-Path $TMPD 'watch.txt'
$RINGKAS_FILE = Join-Path $TMPD 'ringkas.txt'
$SKOR_FILE    = Join-Path $TMPD 'skor.tsv'

# --- Waktu ---
$TODAY      = (Get-Date).ToString('yyyyMMdd')
$TODAY_DASH = (Get-Date).ToString('yyyy-MM-dd')
$NOW_ISO    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$NOW_JAM    = (Get-Date).ToString('HH:mm:ss')
$CHANGES_FILE = Join-Path $DATA_DIR ("CHANGES-$TODAY.md")
$THISMONTH  = (Get-Date).ToString('yyyy-MM')

# =============================================================================
#  UTILITAS
# =============================================================================
function Log  { param([string]$m) Write-Host $m }
function Info { param([string]$m) Write-Host "[INFO] $m" }
function Warn { param([string]$m) Write-Host "[WARN] $m" }

# Escape nilai agar aman di dalam string JSON (tanpa kutip pembungkus).
function Jesc {
  param([string]$s)
  if ($null -eq $s) { $s = '' }
  $s = $s -replace '\\', '\\'
  $s = $s -replace '"', '\"'
  $s = $s -replace "`r", ''
  $s = $s -replace "`n", ' '
  $s = $s -replace "`t", ' '
  return $s
}

# Menyimpan baris status ke CHANGES (dan terminal).
function Write-Change {
  param([string]$Status, [string]$Label, [string]$Pesan)
  $line = "[$NOW_JAM] $Status : $Label $DASH $Pesan"
  Write-Host $line
  Add-Content -LiteralPath $CHANGES_FILE -Value $line -Encoding UTF8
}

# Menyimpan baris ke file state (dibaca untuk manifest).
function Save-State {
  param([string]$Folder, [string]$Nama, [string]$Label, [string]$Tier, [string]$Status,
        [string]$Http, [string]$Laten, [string]$Diff, [string]$Pesan, [string]$Saran)
  $row = @($Folder, $Nama, $Label, $Tier, $Status, $Http, $Laten, $Diff, $Pesan, $Saran) -join '|'
  Add-Content -LiteralPath $STATE_FILE -Value $row -Encoding UTF8
}

# --- Tanggal (array dihitung SEKALI; PowerShell tidak perlu fork) ---
$script:HARI_YMD  = @()
$script:HARI_DASH = @()
function Init-Hari {
  if ($script:HARI_YMD.Count -gt 0) { return }
  $script:HARI_YMD  = @()
  $script:HARI_DASH = @()
  for ($i = 0; $i -le 31; $i++) {
    $d = (Get-Date).AddDays(-$i)
    $script:HARI_YMD  += $d.ToString('yyyyMMdd')
    $script:HARI_DASH += $d.ToString('yyyy-MM-dd')
  }
}

function Get-DateMinusDays {
  param([int]$N, [string]$Fmt)
  return (Get-Date).AddDays(-$N).ToString($Fmt)
}

function Get-Iso24Jam { return (Get-Date).ToUniversalTime().AddHours(-24).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
function Get-Iso24JamNvd { return (Get-Date).ToUniversalTime().AddHours(-24).ToString("yyyy-MM-dd'T'HH:mm:ss.000") }
function UrlEnc { param([string]$s) return ($s -replace ':', '%3A' -replace ' ', '%20') }

# =============================================================================
#  BAGIAN 5 — LOCK (cegah double-run)
# =============================================================================
function Ambil-Lock {
  if (Test-Path -LiteralPath $LOCK_FILE) {
    $pidlama = (Get-Content -Encoding UTF8 -LiteralPath $LOCK_FILE -ErrorAction SilentlyContinue | Select-Object -First 1)
    $hidup = $false
    if ($pidlama) { $hidup = $null -ne (Get-Process -Id ([int]$pidlama) -ErrorAction SilentlyContinue) }
    if ($hidup) {
      Warn "Proses lain masih berjalan (PID $pidlama). Keluar agar tidak tumpang tindih."
      Warn "Jika yakin tidak ada, hapus file .lock secara manual."
      exit 3
    }
    Warn "Lock basi (PID $pidlama tidak hidup). Menghapus .lock dan lanjut."
    Remove-Item -LiteralPath $LOCK_FILE -Force -ErrorAction SilentlyContinue
  }
  Set-Content -LiteralPath $LOCK_FILE -Value $PID -Encoding ASCII
}
function Lepas-Lock { Remove-Item -LiteralPath $LOCK_FILE -Force -ErrorAction SilentlyContinue }

# =============================================================================
#  BAGIAN 6 — HTTP + TERJEMAHAN ERROR
# =============================================================================
function Get-ExtraCurl {
  param([string]$Folder)
  switch ($Folder) {
    'nvd'    { if ($env:NVD_API_KEY) { return "-H apiKey:$($env:NVD_API_KEY)" } }
    'github' {
      $h = '-H Accept:application/vnd.github+json'
      if ($env:GITHUB_TOKEN) { $h = "$h -H Authorization:Bearer $($env:GITHUB_TOKEN)" }
      return $h
    }
    'ransomware' {
      if ($env:RANSOMWARE_API_KEY) { return "-H X-API-KEY:$($env:RANSOMWARE_API_KEY)" }
    }
  }
  return ''
}

# curl_get: menjalankan curl.exe dan mengisi $script:CURL_EXIT/HTTP/TIME.
function Invoke-CurlGet {
  param([string]$Url, [string]$Out, [string]$Extra = '', [string]$Auth = '')
  $a = @('-fsSL', '--retry', '3', '--retry-delay', '5', '--max-time', '90', '-A', $USER_AGENT)
  if ($Extra) { foreach ($x in ($Extra -split '\s+')) { if ($x) { $a += $x } } }
  if ($Auth) { $a += @('-u', $Auth) }
  $a += @('-o', $Out, '-w', '%{http_code}|%{time_total}', $Url)
  $w = & curl.exe @a 2>$null
  $script:CURL_EXIT = $LASTEXITCODE
  if ($null -eq $w) { $w = '' }
  $ws = ($w | Out-String).Trim()
  $parts = $ws -split '\|'
  $script:CURL_HTTP = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0] } else { '000' }
  $script:CURL_TIME = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { '0' }
}

function Get-SaranHttp {
  param([string]$Http)
  switch ($Http) {
    '400' { return 'HTTP 400 (permintaan tidak valid)|Periksa parameter/query pada URL sumber.' }
    '401' { return 'HTTP 401 (butuh autentikasi)|Sediakan API key/kredensial lewat env.' }
    '403' { return 'HTTP 403 (diblokir / User-Agent ditolak)|Perbaiki User-Agent (isi kontak) atau sediakan API key.' }
    '404' { return 'HTTP 404 (endpoint pindah)|Perbarui URL sumber di konfigurasi.' }
    '429' { return 'HTTP 429 (rate limit)|Tunggu, atau sediakan API key (mis. NVD_API_KEY).' }
  }
  if ($Http -match '^5') { return "HTTP $Http (kesalahan server sumber)|Coba lagi nanti." }
  return "HTTP $Http (respons tak terduga)|Periksa endpoint dan kredensial."
}

function Get-TerjemahError {
  param([int]$Ec, [string]$Http)
  switch ($Ec) {
    0  {
      $h = 0; [void][int]::TryParse($Http, [ref]$h)
      if ($h -ge 400) { return (Get-SaranHttp $Http) } else { return 'OK|' }
    }
    6  { return 'Host tidak ditemukan (DNS gagal)|Periksa koneksi internet / DNS; pastikan URL sumber benar.' }
    7  { return 'Koneksi ditolak|Host memblokir atau layanan sedang down; coba lagi nanti.' }
    22 { return (Get-SaranHttp $Http) }
    28 { return 'Timeout (>90s)|Layanan lambat/jaringan buruk; coba lagi atau naikkan --max-time.' }
    35 { return 'SSL/TLS gagal|Sertifikat bermasalah; perbarui CA atau hindari host tsb.' }
    default { return "Gagal curl (exit $Ec)|Periksa URL, jaringan, dan opsi curl." }
  }
}

# Validasi konten: <100 byte / JSON-XML rusak/tidak lengkap -> $false (rusak).
function Test-Konten {
  param([string]$File, [string]$Ext)
  if (-not (Test-Path -LiteralPath $File)) { return $false }
  $raw = [System.IO.File]::ReadAllText($File)
  $trim = $raw.Trim()
  # JSON kosong yang SAH ([] / {}) berarti "tidak ada hasil", bukan rusak.
  if ($Ext -eq 'json' -and ($trim -eq '[]' -or $trim -eq '{}')) { return $true }
  $len = (Get-Item -LiteralPath $File).Length
  if ($len -lt 100) { return $false }
  $first = ($trim[0])
  $last  = ($trim[$trim.Length - 1])
  switch ($Ext) {
    'json' {
      if (-not ($first -eq '{' -or $first -eq '[')) { return $false }
      if (-not ($last -eq '}' -or $last -eq ']')) { return $false }
    }
    'xml' {
      if ($raw.IndexOf('<') -lt 0) { return $false }
      if ($last -ne '>') { return $false }
    }
    'csv' {
      $lines = ([regex]::Matches($raw, "`n")).Count
      if ($lines -lt 2) { return $false }
    }
  }
  return $true
}

# =============================================================================
#  DIFF TERSTRUKTUR (Bagian 5)
# =============================================================================
function Count-Lines { param([string]$F) if (-not (Test-Path -LiteralPath $F)) { return 0 } $raw = [System.IO.File]::ReadAllText($F); return ([regex]::Matches($raw, "`n")).Count }

function Diff-JumlahBaris {
  param([string]$Old, [string]$New)
  $a = Count-Lines $Old; $b = Count-Lines $New
  $d = $b - $a
  $sign = if ($d -ge 0) { '+' } else { '' }
  return "baris $a $ARROW $b ($sign$d)"
}

function Diff-Ofac {
  param([string]$Old, [string]$New)
  $a = Count-Lines $Old; $b = Count-Lines $New
  $d = $b - $a
  $sign = if ($d -ge 0) { '+' } else { '' }
  return "entri sanksi $a $ARROW $b ($sign$d)"
}

function Get-CveIds { param([string]$F) if (-not (Test-Path -LiteralPath $F)) { return @() } $raw = [System.IO.File]::ReadAllText($F); return @([regex]::Matches($raw, 'CVE-[0-9][0-9-]*') | ForEach-Object { $_.Value } | Sort-Object -Unique) }

function Diff-Kev {
  param([string]$Old, [string]$New)
  $baru = @(Get-CveIds $New | Where-Object { (Get-CveIds $Old) -notcontains $_ })
  if ($baru.Count -gt 0) { return ('CVE baru masuk KEV: ' + ($baru -join ',')) }
  return "tidak ada CVE baru di KEV (jumlah tetap $((Get-CveIds $New).Count))"
}

function Diff-Bmkg {
  param([string]$Old, [string]$New)
  $raw = [System.IO.File]::ReadAllText($New)
  $n = ([regex]::Matches($raw, '"Magnitude"')).Count
  $mags = @([regex]::Matches($raw, '"Magnitude":"([0-9.]+)"') | ForEach-Object { [double]$_.Groups[1].Value })
  $max = 'n/a'; if ($mags.Count -gt 0) { $max = ($mags | Measure-Object -Maximum).Maximum }
  return "kejadian: $n $DOT magnitudo tertinggi: $max"
}

function Diff-Usgs {
  param([string]$Old, [string]$New)
  $lines = Get-Content -Encoding UTF8 -LiteralPath $New -ErrorAction SilentlyContinue
  $data = @()
  if ($lines.Count -gt 1) { $data = $lines[1..($lines.Count - 1)] }
  $n = $data.Count
  $max = 0.0; $ada = $false
  foreach ($r in $data) {
    $c = ($r -split ',')
    if ($c.Count -ge 5) { $v = 0.0; if ([double]::TryParse($c[4], [ref]$v)) { if ($v -gt $max) { $max = $v }; $ada = $true } }
  }
  $mt = if ($ada) { $max } else { 'n/a' }
  return "kejadian: $n $DOT magnitudo tertinggi: $mt"
}

function Get-Views { param([string]$F) if (-not (Test-Path -LiteralPath $F)) { return @() } $raw = [System.IO.File]::ReadAllText($F); return @([regex]::Matches($raw, '"views":([0-9]+)') | ForEach-Object { [int]$_.Groups[1].Value }) }

function Diff-Pageviews {
  param([string]$Old, [string]$New)
  $v = Get-Views $New
  if ($v.Count -eq 0) { return 'views terakhir: n/a' }
  $b = $v[$v.Count - 1]
  if ($v.Count -ge 2) {
    $a = $v[$v.Count - 2]
    if ($a -gt 0) {
      $pct = [math]::Round(($b - $a) * 100 / $a)
      $sign = if ($pct -ge 0) { '+' } else { '' }
      return "views $a $ARROW $b ($sign$pct%)"
    }
  }
  return "views terakhir: $b"
}

function Get-LinkUnik { param([string]$F) if (-not (Test-Path -LiteralPath $F)) { return @() } $raw = [System.IO.File]::ReadAllText($F); return @([regex]::Matches($raw, '"link":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) }

function Diff-Rss {
  param([string]$Old, [string]$New)
  $baru = @(Get-LinkUnik $New | Where-Object { (Get-LinkUnik $Old) -notcontains $_ })
  return "item baru: $($baru.Count)"
}

function Invoke-DiffSumber {
  param([string]$Folder, [string]$Nama, [string]$Old, [string]$New)
  $key = "$Folder/$Nama"
  switch -Regex ($key) {
    '^ofac/sdn$'                 { return (Diff-Ofac $Old $New) }
    '^cisa/kev$'                 { return (Diff-Kev $Old $New) }
    '^bmkg/(autogempa|gempadirasakan)$' { return (Diff-Bmkg $Old $New) }
    '^usgs/m25hari$'             { return (Diff-Usgs $Old $New) }
    '^firms/hotspot$'            { return (Diff-JumlahBaris $Old $New) }
    '^wiki/pageviews_'           { return (Diff-Pageviews $Old $New) }
    '^rss/'                      { return (Diff-Rss $Old $New) }
    default                      { return (Diff-JumlahBaris $Old $New) }
  }
}

# =============================================================================
#  SNAPSHOT
# =============================================================================
function Get-SnapshotFiles {
  param([string]$Folder, [string]$Nama)
  $dir = Join-Path $DATA_DIR $Folder
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $pat = '^\d{8}-' + [regex]::Escape($Nama) + '\.'
  return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $pat } | Sort-Object Name)
}
function Get-SnapshotCount { param([string]$Folder, [string]$Nama) return (Get-SnapshotFiles $Folder $Nama).Count }
function Get-NewestSnapshot {
  param([string]$Folder, [string]$Nama)
  $f = Get-SnapshotFiles $Folder $Nama
  if ($f.Count -gt 0) { return $f[$f.Count - 1].FullName }
  return ''
}
function Get-SnapshotBeforeToday {
  param([string]$Folder, [string]$Nama)
  $f = Get-SnapshotFiles $Folder $Nama | Where-Object { -not $_.Name.StartsWith("$TODAY-") }
  if (@($f).Count -gt 0) { return @($f)[@($f).Count - 1].FullName }
  return ''
}

# =============================================================================
#  SKOR KESEHATAN 30 HARI (indeks satu kali)
# =============================================================================
$script:SKOR_INDEXED = $false
function Init-SkorIndex {
  if ($script:SKOR_INDEXED) { return }
  $script:SKOR_INDEXED = $true
  Init-Hari
  $tbl = @{}
  for ($i = 0; $i -le 29; $i++) {
    $f = Join-Path $DATA_DIR ("CHANGES-$($script:HARI_YMD[$i]).md")
    if (-not (Test-Path -LiteralPath $f)) { continue }
    foreach ($ln in (Get-Content -Encoding UTF8 -LiteralPath $f -ErrorAction SilentlyContinue)) {
      if ($ln -notmatch '^\[\d{2}:\d{2}:\d{2}\] ') { continue }
      $line = $ln.Substring($ln.IndexOf('] ') + 2)
      $p = $line.IndexOf(' : '); if ($p -lt 0) { continue }
      $st = $line.Substring(0, $p)
      $rest = $line.Substring($p + 3)
      $q = $rest.IndexOf(" $DASH ")
      $lab = if ($q -gt 0) { $rest.Substring(0, $q) } else { $rest }
      if (-not $tbl.ContainsKey($lab)) { $tbl[$lab] = @{ ok = 0; total = 0 } }
      $tbl[$lab].total++
      if ($st -eq 'OK' -or $st -eq 'SAMA') { $tbl[$lab].ok++ }
    }
  }
  $script:SKOR_TBL = $tbl
}
function Get-HealthScore {
  param([string]$Label)
  Init-SkorIndex
  if (-not $script:SKOR_TBL.ContainsKey($Label)) { return 0 }
  $e = $script:SKOR_TBL[$Label]
  if ($e.total -le 0) { return 0 }
  return [int]([math]::Floor($e.ok * 100 / $e.total))
}

# =============================================================================
#  ANOMALI PAGEVIEWS
# =============================================================================
function Test-Anomali {
  param([string]$Label, [string]$File)
  $v = Get-Views $File
  if ($v.Count -eq 0) { return }
  $terakhir = $v[$v.Count - 1]
  $rata = 0
  if ($v.Count -gt 0) { $rata = [int](($v | Measure-Object -Average).Average) }
  if ($rata -le 0) { return }
  $x = [int]([math]::Floor($terakhir * 100 / $rata))
  if ($x -ge ($ANOMALI_THRESHOLD * 100)) {
    $msg = "$Label $DASH $x% rata-rata (nilai $terakhir vs rata $rata)"
    Add-Content -LiteralPath $ANOMALI_FILE -Value $msg -Encoding UTF8
    Add-Content -LiteralPath $RINGKAS_FILE -Value "- ANOMALI : $msg" -Encoding UTF8
    Write-Change 'ANOMALI' $Label "$x% rata-rata (nilai $terakhir vs rata $rata)"
  }
}

# =============================================================================
#  WATCH (kata kunci pemantauan)
# =============================================================================
function Get-Judul {
  param([string]$F)
  if (-not (Test-Path -LiteralPath $F)) { return @() }
  $raw = [System.IO.File]::ReadAllText($F)
  return @([regex]::Matches($raw, '"title":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
function Scan-Watch {
  param([string]$Label, [string]$Old, [string]$New)
  $judul = @(Get-Judul $New)
  if ($judul.Count -eq 0) { return }
  if ($Old -and (Test-Path -LiteralPath $Old)) {
    $lama = Get-Judul $Old
    $judul = @($judul | Where-Object { $lama -notcontains $_ })
  }
  foreach ($j in $judul) {
    if (-not $j) { continue }
    $lower = $j.ToLowerInvariant()
    foreach ($kw in $KEYWORDS_WATCH) {
      $kl = $kw.ToLowerInvariant()
      if ($lower.Contains($kl)) {
        $m = "WATCH : $kw $DASH $j"
        Add-Content -LiteralPath $WATCH_FILE -Value $m -Encoding UTF8
        Add-Content -LiteralPath $RINGKAS_FILE -Value "- $m" -Encoding UTF8
        Write-Change 'WATCH' $kl $j
      }
    }
  }
}

# =============================================================================
#  LAPORAN ERROR TERSTRUKTUR (data/errors/ DI-COMMIT)
# =============================================================================
function Write-ErrorEntry {
  param([string]$Label, [string]$Url, [string]$Ec, [string]$Http, [string]$Pesan, [string]$Saran)
  New-Item -ItemType Directory -Force -Path $ERRORS_DIR | Out-Null
  $f = Join-Path $ERRORS_DIR ("$TODAY.md")
  if (-not (Test-Path -LiteralPath $f)) { [System.IO.File]::AppendAllText($f, "# Laporan error $DASH $TODAY_DASH`n", $UTF8NB) }
  $blok = @(
    "## [$NOW_JAM] $Label",
    "- URL: $Url",
    "- Exit code: $Ec $DOT HTTP: $Http",
    "- Pesan: $Pesan",
    "- Saran: $Saran",
    ""
  ) -join "`n"
  [System.IO.File]::AppendAllText($f, $blok, $UTF8NB)
}

# =============================================================================
#  RETENSI news-full
# =============================================================================
function Invoke-Retensi {
  if (-not (Test-Path -LiteralPath $NEWSFULL_DIR)) { return }
  $batas = Get-DateMinusDays $RETENTION_DAYS 'yyyyMMdd'
  $dihapus = 0
  foreach ($d in (Get-ChildItem -LiteralPath $NEWSFULL_DIR -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name -match '^\d{8}$' -and ([int]$d.Name -lt [int]$batas)) {
      Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
      $dihapus++
    }
  }
  Info "RETENSI: menghapus $dihapus folder news-full (> $RETENTION_DAYS hari)"
}

# =============================================================================
#  PROSES RSS: XML -> JSON {title,link,snippet,wayback}
# =============================================================================
function Get-Tag {
  param([string]$Block, [string]$Tag)
  $m = [regex]::Match($Block, "(?s)<$Tag[^>]*>(.*?)</$Tag>")
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function Convert-Bersih {
  param([string]$s)
  $s = $s -replace '<!\[CDATA\[', '' -replace '\]\]>', ''
  $s = $s -replace '<[^>]*>', ''
  $s = $s -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
  $s = $s -replace '[\t\r\n]+', ' '
  $s = $s.Trim()
  if ($s.Length -gt $SNIPPET_MAX) { $s = $s.Substring(0, $SNIPPET_MAX) }
  return $s
}
function Convert-Esc {
  param([string]$s)
  $s = $s -replace '\\', '\\' -replace '"', '\"'
  $s = $s -replace "`t", ' ' -replace "`r", ' ' -replace "`n", ' '
  return $s
}
function Convert-RssToJson {
  param([string]$Path, [string]$Nama)
  $raw = [System.IO.File]::ReadAllText($Path)
  $items = [regex]::Matches($raw, '(?s)<item[^>]*>(.*?)</item>')
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("[`n")
  $n = 0
  foreach ($m in $items) {
    $blok = $m.Groups[1].Value
    $t = Convert-Bersih (Get-Tag $blok 'title')
    $l = Convert-Bersih (Get-Tag $blok 'link')
    $d = Convert-Bersih (Get-Tag $blok 'description')
    if ($l -eq '') { continue }
    $way = "https://web.archive.org/web/$l"
    if ($n -gt 0) { [void]$sb.Append(",`n") }
    [void]$sb.Append('  {"title":"' + (Convert-Esc $t) + '","link":"' + (Convert-Esc $l) + '","snippet":"' + (Convert-Esc $d) + '","wayback":"' + (Convert-Esc $way) + '"}')
    $n++
  }
  [void]$sb.Append("`n]`n")
  return $sb.ToString()
}

function Download-FullText {
  param([string]$Nama, [string]$Feed)
  New-Item -ItemType Directory -Force -Path (Join-Path $NEWSFULL_DIR $TODAY) | Out-Null
  $links = @([regex]::Matches([System.IO.File]::ReadAllText($Feed), '"link":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 20)
  foreach ($link in $links) {
    if ($link -match 'paywall|subscribe') { continue }
    Start-Sleep -Seconds 1
    $slug = ($link -replace '[^a-zA-Z0-9]', '')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
    $out = Join-Path (Join-Path $NEWSFULL_DIR $TODAY) ("${Nama}_$slug.html")
    & curl.exe -fsSL --max-time 30 -A $USER_AGENT -o $out $link 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
  }
  Info "TIER-LOKAL: teks penuh $Nama disimpan di data/news-full/$TODAY/ (gitignored)"
}

# =============================================================================
#  PROSES SATU SUMBER
# =============================================================================
function Process-Source {
  param([string]$Folder, [string]$Nama, [string]$Label, [string]$Url, [string]$Tier, [string]$Jadwal, [string]$Ext)
  $Url = $Url.TrimEnd("`r")

  switch -Regex ($Jadwal) {
    '^senin$' {
      if ((Get-Date).DayOfWeek.value__ -ne 1) {
        Info "LEWAT : $Label (khusus Senin)"
        Save-State $Folder $Nama $Label $Tier 'LEWAT' '000' '0' '' 'khusus Senin' ''
        return
      }
    }
    '^env:' {
      $evn = $Jadwal.Substring(4)
      $val = [System.Environment]::GetEnvironmentVariable($evn)
      if (-not $val) {
        Info "LEWAT : $Label (butuh env $evn)"
        Save-State $Folder $Nama $Label $Tier 'LEWAT' '000' '0' '' "butuh env $evn" ''
        return
      }
    }
  }

  $Url = $Url -replace '\{TODAY\}', $TODAY -replace '\{TODAY_DASH\}', $TODAY_DASH
  $Url = $Url -replace '\{FROM_ISO\}', (Get-Iso24Jam) -replace '\{TO_ISO\}', $NOW_ISO
  $Url = $Url -replace '\{FROM_ISO_ENC\}', (UrlEnc (Get-Iso24JamNvd))
  $Url = $Url -replace '\{TO_ISO_ENC\}', (UrlEnc ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.000")))
  $Url = $Url -replace '\{FIRMS_KEY\}', "$($env:FIRMS_KEY)"

  New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR $Folder) | Out-Null
  $target = Join-Path (Join-Path $DATA_DIR $Folder) "$TODAY-$Nama.$Ext"
  $extra = Get-ExtraCurl $Folder
  $auth = ''
  if ($Folder -eq 'opensky' -and $env:OPENSKY_USER -and $env:OPENSKY_PASS) { $auth = "$($env:OPENSKY_USER):$($env:OPENSKY_PASS)" }

  Info "AMBIL : $Label ..."
  Invoke-CurlGet $Url $target $extra $auth

  if ($script:CURL_EXIT -ne 0) {
    $ter = Get-TerjemahError $script:CURL_EXIT $script:CURL_HTTP
    $pesan = $ter.Split('|')[0]; $saran = $ter.Split('|')[1]
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    Warn "GAGAL : $Label (exit $($script:CURL_EXIT), HTTP $($script:CURL_HTTP)) $DASH $pesan"
    Write-Change 'GAGAL' $Label "$pesan (HTTP $($script:CURL_HTTP), exit $($script:CURL_EXIT))"
    Write-ErrorEntry $Label $Url $script:CURL_EXIT $script:CURL_HTTP $pesan $saran
    Save-State $Folder $Nama $Label $Tier 'GAGAL' $script:CURL_HTTP $script:CURL_TIME '' $pesan $saran
    return
  }

  if (-not (Test-Konten $target $Ext)) {
    Warn "RUSAK : $Label (konten <100B atau rusak/tidak lengkap)"
    Write-Change 'RUSAK' $Label "konten rusak atau tidak lengkap (HTTP $($script:CURL_HTTP))"
    Write-ErrorEntry $Label $Url $script:CURL_EXIT $script:CURL_HTTP 'Konten rusak/tidak lengkap' 'Cek endpoint; mungkin butuh header/auth atau server mengirim halaman error.'
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    Save-State $Folder $Nama $Label $Tier 'RUSAK' $script:CURL_HTTP $script:CURL_TIME '' 'konten rusak' 'cek endpoint/auth'
    return
  }

  $prev = Get-SnapshotBeforeToday $Folder $Nama
  if ($prev -and (Test-Path -LiteralPath $prev)) {
    $h1 = (Get-FileHash -LiteralPath $prev -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($h1 -eq $h2) {
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      Info "SAMA  : $Label"
      Write-Change 'SAMA' $Label 'identik dengan snapshot terakhir'
      Save-State $Folder $Nama $Label $Tier 'SAMA' $script:CURL_HTTP $script:CURL_TIME '' '' ''
      return
    }
  }

  $ringkasan = 'snapshot baru'
  if ($prev) {
    $ringkasan = Invoke-DiffSumber $Folder $Nama $prev $target
    Add-Content -LiteralPath $RINGKAS_FILE -Value "- PERUBAHAN ${Label}: $ringkasan" -Encoding UTF8
    Add-Content -LiteralPath $CHANGES_FILE -Value "`n## PERUBAHAN $DASH $Label`n- $ringkasan`n" -Encoding UTF8
    Write-Change 'PERUBAHAN' $Label $ringkasan
  } else {
    Write-Change 'OK' $Label "snapshot pertama (HTTP $($script:CURL_HTTP), $($script:CURL_TIME)s)"
  }

  if ($Nama -eq 'pageviews') { Test-Anomali $Label $target }
  if ($Ext -eq 'json' -and $Tier -eq 'snippet') { Scan-Watch $Label $prev $target }

  Save-State $Folder $Nama $Label $Tier 'OK' $script:CURL_HTTP $script:CURL_TIME $ringkasan '' ''
}

# =============================================================================
#  PROSES WIKIPEDIA PAGEVIEWS
# =============================================================================
function Process-Wiki {
  $mulai = Get-DateMinusDays 7 'yyyyMMdd'
  $akhir = (Get-Date).ToString('yyyyMMdd')
  foreach ($ent in $WIKI_ARTICLES) {
    $ent = $ent.TrimEnd("`r"); if (-not $ent.Trim()) { continue }
    $label = $ent.Split('|')[0]
    $art = if ($ent.Contains('|')) { $ent.Substring($ent.IndexOf('|') + 1) } else { $label }
    if (-not $art) { $art = $label }
    $folder = 'wiki'; $nama = "pageviews_$art"
    $url = "https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/$WIKI_PROJECT/all-access/user/$art/daily/$mulai/$akhir"
    New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR $folder) | Out-Null
    $target = Join-Path (Join-Path $DATA_DIR $folder) "$TODAY-$nama.json"
    Info "AMBIL : Wikipedia pageviews ($label) ..."
    Invoke-CurlGet $url $target '' ''
    if ($script:CURL_EXIT -ne 0) {
      $ter = Get-TerjemahError $script:CURL_EXIT $script:CURL_HTTP
      $pesan = $ter.Split('|')[0]; $saran = $ter.Split('|')[1]
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      Write-Change 'GAGAL' "Wikipedia $label" "$pesan (HTTP $($script:CURL_HTTP))"
      Write-ErrorEntry "Wikipedia $label" $url $script:CURL_EXIT $script:CURL_HTTP $pesan $saran
      Save-State $folder $nama "Wikipedia: $label" 'full' 'GAGAL' $script:CURL_HTTP $script:CURL_TIME '' $pesan $saran
      continue
    }
    if (-not (Test-Konten $target 'json')) {
      Write-Change 'RUSAK' "Wikipedia $label" 'respons pageviews rusak'
      Write-ErrorEntry "Wikipedia $label" $url $script:CURL_EXIT $script:CURL_HTTP 'Konten rusak' 'Cek judul artikel & rentang tanggal.'
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      Save-State $folder $nama "Wikipedia: $label" 'full' 'RUSAK' $script:CURL_HTTP $script:CURL_TIME '' 'rusak' 'cek judul'
      continue
    }
    $prev = Get-SnapshotBeforeToday $folder $nama
    if ($prev -and ((Get-FileHash -LiteralPath $prev -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)) {
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      Write-Change 'SAMA' "Wikipedia $label" 'identik'
      Save-State $folder $nama "Wikipedia: $label" 'full' 'SAMA' $script:CURL_HTTP $script:CURL_TIME '' '' ''
      continue
    }
    $ring = 'snapshot pertama'
    if ($prev) {
      $ring = Diff-Pageviews $prev $target
      Add-Content -LiteralPath $CHANGES_FILE -Value "`n## PERUBAHAN $DASH Wikipedia $label`n- $ring`n" -Encoding UTF8
    }
    Write-Change 'OK' "Wikipedia $label" $ring
    Test-Anomali "Wikipedia $label" $target
    Save-State $folder $nama "Wikipedia: $label" 'full' 'OK' $script:CURL_HTTP $script:CURL_TIME $ring '' ''
  }
}

# =============================================================================
#  PROSES RSS BERITA (tier snippet; FETCH_FULL_TEXT -> lokal)
# =============================================================================
function Process-Rss {
  foreach ($ent in $RSS_FEEDS) {
    $ent = $ent.TrimEnd("`r"); if (-not $ent.Trim()) { continue }
    $nama = $ent.Split('|')[0]
    $url = $ent.Substring($ent.IndexOf('|') + 1)
    $folder = 'rss'
    # Awalan rss_ agar nama berkas = `nama` di state/manifest (dedup/diff cocok).
    $target = Join-Path (Join-Path $DATA_DIR $folder) "$TODAY-rss_$nama.json"
    New-Item -ItemType Directory -Force -Path (Join-Path $DATA_DIR $folder) | Out-Null
    Info "AMBIL : RSS $nama (tier snippet) ..."
    $raw = Join-Path $TMPD "rss_$nama.xml"
    Invoke-CurlGet $url $raw '' ''
    if ($script:CURL_EXIT -ne 0) {
      $ter = Get-TerjemahError $script:CURL_EXIT $script:CURL_HTTP
      $pesan = $ter.Split('|')[0]; $saran = $ter.Split('|')[1]
      Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
      Write-Change 'GAGAL' "RSS $nama" "$pesan (HTTP $($script:CURL_HTTP))"
      Write-ErrorEntry "RSS $nama" $url $script:CURL_EXIT $script:CURL_HTTP $pesan $saran
      Save-State $folder "rss_$nama" "RSS: $nama" 'snippet' 'GAGAL' $script:CURL_HTTP $script:CURL_TIME '' $pesan $saran
      continue
    }
    $rawtext = ''
    if (Test-Path -LiteralPath $raw) { $rawtext = [System.IO.File]::ReadAllText($raw) }
    if ($rawtext.IndexOf('<item') -lt 0) {
      Write-Change 'RUSAK' "RSS $nama" 'feed tanpa item / rusak'
      Write-ErrorEntry "RSS $nama" $url $script:CURL_EXIT $script:CURL_HTTP 'Feed kosong/rusak' 'Verifikasi URL feed di browser.'
      Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
      Save-State $folder "rss_$nama" "RSS: $nama" 'snippet' 'RUSAK' $script:CURL_HTTP $script:CURL_TIME '' 'feed rusak' 'verifikasi URL'
      continue
    }
    $json = Convert-RssToJson $raw $nama
    [System.IO.File]::WriteAllText($target, $json)
    Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue

    if ($env:FETCH_FULL_TEXT -eq '1') { Download-FullText $nama $target }

    $prev = Get-SnapshotBeforeToday $folder "rss_$nama"
    if ($prev -and ((Get-FileHash -LiteralPath $prev -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)) {
      Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
      Write-Change 'SAMA' "RSS $nama" 'identik'
      Save-State $folder "rss_$nama" "RSS: $nama" 'snippet' 'SAMA' $script:CURL_HTTP $script:CURL_TIME '' '' ''
      continue
    }
    $ring = 'snapshot pertama'
    if ($prev) {
      $ring = Diff-Rss $prev $target
      Add-Content -LiteralPath $CHANGES_FILE -Value "`n## PERUBAHAN $DASH RSS $nama`n- $ring`n" -Encoding UTF8
    }
    Write-Change 'OK' "RSS $nama" $ring
    Scan-Watch "RSS $nama" $prev $target
    Save-State $folder "rss_$nama" "RSS: $nama" 'snippet' 'OK' $script:CURL_HTTP $script:CURL_TIME $ring '' ''
  }
}

# =============================================================================
#  BAGIAN 7 — MANIFEST (docs/data.json & docs/data.js)
# =============================================================================
function Status-Count {
  param([string]$St)
  if (-not (Test-Path -LiteralPath $STATE_FILE)) { return 0 }
  return @(Get-Content -Encoding UTF8 -LiteralPath $STATE_FILE | Where-Object { $_ -match "\|$St\|" }).Count
}

function Riwayat-30 {
  param([string]$Folder, [string]$Nama, [string]$Ext)
  Init-Hari
  $out = @()
  for ($i = 29; $i -ge 0; $i--) {
    $d = $script:HARI_YMD[$i]
    if (Test-Path -LiteralPath (Join-Path (Join-Path $DATA_DIR $Folder) "$d-$Nama.$Ext")) { $out += 1 } else { $out += 0 }
  }
  return $out
}

function Build-Manifest {
  New-Item -ItemType Directory -Force -Path $DOCS_DIR | Out-Null
  Init-Hari
  $anomali = @(); if (Test-Path -LiteralPath $ANOMALI_FILE) { $anomali = @(Get-Content -Encoding UTF8 -LiteralPath $ANOMALI_FILE | Where-Object { $_ }) }
  $watch = @();   if (Test-Path -LiteralPath $WATCH_FILE)   { $watch = @(Get-Content -Encoding UTF8 -LiteralPath $WATCH_FILE | Where-Object { $_ }) }

  $sumber = @()
  if (Test-Path -LiteralPath $STATE_FILE) {
    foreach ($row in (Get-Content -Encoding UTF8 -LiteralPath $STATE_FILE)) {
      if (-not $row) { continue }
      $p = $row.Split('|')
      if ($p.Count -lt 10) { continue }
      $folder = $p[0]; $nama = $p[1]; $label = $p[2]; $tier = $p[3]; $status = $p[4]
      $http = $p[5]; $laten = $p[6]; $diff = $p[7]; $pesan = $p[8]; $saran = $p[9]
      $ext = 'json'
      switch ($folder) {
        { $_ -eq 'ofac' -or $_ -eq 'usgs' -or $_ -eq 'firms' } { $ext = 'csv' }
      }
      if ($folder -eq 'cisa') { if ($nama -eq 'advisories') { $ext = 'xml' } else { $ext = 'json' } }
      $snap = ''
      $newest = Get-NewestSnapshot $folder $nama
      if ($newest) { $snap = Split-Path -Leaf $newest }
      $sumber += [ordered]@{
        folder = $folder; nama = $nama; label = $label; tier = $tier; status = $status
        http = "$http"; laten = [double]($laten -replace '[^0-9.]', ''); snapshot = $snap
        jumlah_file = (Get-SnapshotCount $folder $nama); skor = (Get-HealthScore $label)
        riwayat = @(Riwayat-30 $folder $nama $ext)
        diff = $diff; pesan_error = $pesan; saran = $saran
      }
    }
  }

  $log = @()
  for ($i = 0; $i -le 13; $i++) {
    $d = $script:HARI_YMD[$i]
    $f = Join-Path $DATA_DIR ("CHANGES-$d.md")
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $ok = 0; $ggl = 0
    foreach ($ln in (Get-Content -Encoding UTF8 -LiteralPath $f -ErrorAction SilentlyContinue)) {
      if ($ln -match ' OK : | SAMA : ') { $ok++ }
      elseif ($ln -match ' GAGAL : | RUSAK : ') { $ggl++ }
    }
    $log += [ordered]@{ tanggal = $script:HARI_DASH[$i]; ok = $ok; gagal = $ggl; file = "data/CHANGES-$d.md" }
  }

  $tabel = [ordered]@{
    gempa = @(Tabel-Gempa)
    cve   = @(Tabel-Cve)
    kev   = @(Tabel-Kev)
    rss   = @(Tabel-Rss)
  }

  $manifest = [ordered]@{
    proyek    = $PROJECT_NAME
    tanggal   = $TODAY_DASH
    dibuat    = $NOW_ISO
    situs     = $SITE_BASE
    ringkasan = [ordered]@{
      ok = (Status-Count 'OK'); sama = (Status-Count 'SAMA'); gagal = (Status-Count 'GAGAL')
      rusak = (Status-Count 'RUSAK'); lewat = (Status-Count 'LEWAT')
      anomali = $anomali.Count; watch = $watch.Count
    }
    sumber  = $sumber
    anomali = $anomali
    watch   = $watch
    log     = $log
    tabel   = $tabel
  }

  $json = $manifest | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText((Join-Path $DOCS_DIR 'data.json'), $json)
  [System.IO.File]::WriteAllText((Join-Path $DOCS_DIR 'data.js'), "window.DATA = $json;`n")
  Info "MANIFEST: docs/data.json + docs/data.js ditulis ulang."
}

function Get-BmkgField {
  param([string]$File, [string]$Field)
  $raw = [System.IO.File]::ReadAllText($File)
  $m = [regex]::Match($raw, '"' + $Field + '":"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function Tabel-Gempa {
  $out = @()
  $f = Get-NewestSnapshot 'bmkg' 'autogempa'
  if ($f) {
    $out += [ordered]@{
      sumber = 'BMKG'; magnitudo = (Get-BmkgField $f 'Magnitude')
      lokasi = (Get-BmkgField $f 'Wilayah'); waktu = (Get-BmkgField $f 'Tanggal')
    }
  }
  $fu = Get-NewestSnapshot 'usgs' 'm25hari'
  if ($fu) {
    $lines = Get-Content -Encoding UTF8 -LiteralPath $fu -ErrorAction SilentlyContinue
    if ($lines.Count -gt 1) {
      $rows = $lines[1..($lines.Count - 1)] | ForEach-Object {
        $c = $_ -split ','
        if ($c.Count -ge 14) {
          $place = $c[13].Trim('"')
          [pscustomobject]@{ t = $c[0]; mag = [double]$c[4]; place = $place }
        }
      } | Sort-Object mag -Descending | Select-Object -First 5
      foreach ($r in $rows) { $out += [ordered]@{ sumber = 'USGS'; magnitudo = "$($r.mag)"; lokasi = $r.place; waktu = $r.t } }
    }
  }
  return $out
}
function Tabel-Cve {
  $out = @()
  $f = Get-NewestSnapshot 'nvd' 'cve'
  if ($f) {
    $ids = @([regex]::Matches([System.IO.File]::ReadAllText($f), '"id":"(CVE-[0-9-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Select-Object -First 40)
    foreach ($id in $ids) { $out += [ordered]@{ id = $id } }
  }
  return $out
}
function Tabel-Kev {
  $out = @()
  $f = Get-NewestSnapshot 'cisa' 'kev'
  if ($f) {
    # CISA KEV = JSON rapi (spasi setelah ':'); ambil id & vendor terpisah lalu
    # pasangkan (urutannya sejajar per entri).
    $raw  = [System.IO.File]::ReadAllText($f)
    $ids  = @([regex]::Matches($raw, '"cveID"\s*:\s*"(CVE-[0-9-]+)"')       | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 20)
    $vens = @([regex]::Matches($raw, '"vendorProject"\s*:\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 20)
    for ($i = 0; $i -lt [Math]::Min($ids.Count, $vens.Count); $i++) {
      $out += [ordered]@{ id = $ids[$i]; vendor = $vens[$i] }
    }
  }
  return $out
}
function Tabel-Rss {
  $out = @()
  foreach ($nama in @('bbc', 'aljazeera', 'guardian', 'cna', 'cnbcindonesia', 'cnnindonesia', 'antara')) {
    $f = Get-NewestSnapshot 'rss' "rss_$nama"
    if (-not $f) { continue }
    $raw = [System.IO.File]::ReadAllText($f)
    $ms = [regex]::Matches($raw, '\{"title":"([^"]*)","link":"([^"]*)","snippet":"([^"]*)","wayback":"([^"]*)"\}')
    foreach ($m in ($ms | Select-Object -First 5)) {
      $out += [ordered]@{
        feed = $nama; title = $m.Groups[1].Value; link = $m.Groups[2].Value
        snippet = $m.Groups[3].Value; wayback = $m.Groups[4].Value
      }
    }
  }
  return $out
}

# =============================================================================
#  BAGIAN 7 — FEED RSS TRACKER (docs/feed.xml)
# =============================================================================
function XmlEsc { param([string]$s) if ($null -eq $s) { return '' } return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&apos;') }

function Build-Feed {
  Init-Hari
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n")
  [void]$sb.Append("<rss version=`"2.0`"><channel>`n")
  [void]$sb.Append("  <title>$(XmlEsc $PROJECT_NAME) $DASH tracker perubahan</title>`n")
  [void]$sb.Append("  <link>$(XmlEsc $SITE_BASE)</link>`n")
  [void]$sb.Append("  <description>Ringkasan harian perubahan, kegagalan, anomali, dan kata kunci pemantauan.</description>`n")
  [void]$sb.Append("  <language>id</language>`n")
  $emitted = 0
  $pub = (Get-Date).ToUniversalTime().ToString('r')
  for ($i = 0; $i -le 30; $i++) {
    if ($emitted -ge $RSS_MAX_ITEMS) { break }
    $d = $script:HARI_YMD[$i]
    $f = Join-Path $DATA_DIR ("CHANGES-$d.md")
    if (-not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $f -ErrorAction SilentlyContinue)) {
      if ($emitted -ge $RSS_MAX_ITEMS) { break }
      if ($line -match ' PERUBAHAN : | GAGAL : | ANOMALI : | WATCH : | RUSAK : ') {
        $idx = $line.IndexOf('] ')
        $jud = if ($idx -ge 0) { $line.Substring($idx + 2) } else { $line }
        [void]$sb.Append("  <item>`n")
        [void]$sb.Append("    <title>$(XmlEsc $jud)</title>`n")
        [void]$sb.Append("    <link>$(XmlEsc $SITE_BASE)#log</link>`n")
        [void]$sb.Append("    <guid isPermaLink=`"false`">$d-$emitted</guid>`n")
        [void]$sb.Append("    <pubDate>$pub</pubDate>`n")
        [void]$sb.Append("  </item>`n")
        $emitted++
      }
    }
  }
  [void]$sb.Append("</channel></rss>`n")
  [System.IO.File]::WriteAllText((Join-Path $DOCS_DIR 'feed.xml'), $sb.ToString())
  Info "FEED: docs/feed.xml ditulis ulang ($emitted item)."
}

# =============================================================================
#  BAGIAN 5 — TELEGRAM DIGEST (opsional)
# =============================================================================
function Send-Telegram {
  if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) {
    Info 'TELEGRAM: dilewati (env tidak diisi).'
    return
  }
  $gagalList = ''
  if (Test-Path -LiteralPath $STATE_FILE) {
    $gagalList = (@(Get-Content -Encoding UTF8 -LiteralPath $STATE_FILE | Where-Object { $_ -match '^[^|]*\|[^|]*\|[^|]*\|[^|]*\|GAGAL\|' } |
      ForEach-Object { $p = $_.Split('|'); "- $($p[2]): $($p[8]) ($($p[9]))" }) -join "`n")
  }
  $ring = ''
  if (Test-Path -LiteralPath $RINGKAS_FILE) { $ring = ([System.IO.File]::ReadAllText($RINGKAS_FILE)); if ($ring.Length -gt 1500) { $ring = $ring.Substring(0, 1500) } }
  if (-not $ring) { $ring = '-' }
  $pesan = @"
Ringkasan harian $PROJECT_NAME ($TODAY_DASH)
OK: $(Status-Count 'OK') $DOT SAMA: $(Status-Count 'SAMA') $DOT GAGAL: $(Status-Count 'GAGAL') $DOT RUSAK: $(Status-Count 'RUSAK')

GAGAL:
$gagalList

PERUBAHAN/ANOMALI/WATCH:
$ring
"@
  if ($pesan.Length -gt $TELEGRAM_LIMIT) { $pesan = $pesan.Substring(0, $TELEGRAM_LIMIT) }
  $resp = & curl.exe -fsSL --max-time 30 -A $USER_AGENT --data-urlencode "chat_id=$($env:TELEGRAM_CHAT_ID)" --data-urlencode "text=$pesan" "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" 2>$null
  if ($LASTEXITCODE -eq 0) { Info 'TELEGRAM: digest terkirim.' } else { Warn 'TELEGRAM: gagal kirim (dilanjutkan).' }
}

# =============================================================================
#  BAGIAN 5 — TAG BULANAN
# =============================================================================
function New-MonthTag {
  $ada = & git tag -l $THISMONTH 2>$null
  if ($ada) { Info "TAG: $THISMONTH sudah ada."; return }
  & git rev-parse --verify HEAD *>$null
  if ($LASTEXITCODE -eq 0) {
    & git tag $THISMONTH 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Info "TAG: $THISMONTH dibuat." }
    & git push origin $THISMONTH 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn 'TAG: push tag gagal (dilanjutkan).' }
  }
}

# =============================================================================
#  BAGIAN 5 — GIT FINALIZE
# =============================================================================
function Invoke-GitFinalize {
  Set-Location $BASE_DIR
  $gitPath = Join-Path $BASE_DIR '.git'
  if (-not (Test-Path -LiteralPath $gitPath)) {
    Warn "GIT: $BASE_DIR bukan root repositori git $DASH lewati commit/push."
    Warn "     Jalankan 'git init' di folder ini (lihat README) lalu coba lagi."
    return
  }
  & git add -A 2>$null
  & git diff --cached --quiet 2>$null
  if ($LASTEXITCODE -eq 0) { Info 'GIT: tidak ada perubahan - keluar tanpa commit.'; return }
  $stat = (& git diff --cached --stat 2>$null | Select-Object -Last 1)
  $ringkas = ''
  if (Test-Path -LiteralPath $RINGKAS_FILE) { $ringkas = [System.IO.File]::ReadAllText($RINGKAS_FILE); if ($ringkas.Length -gt 1500) { $ringkas = $ringkas.Substring(0, 1500) } }
  if (-not $ringkas) { $ringkas = '-' }
  $msg = "Update harian $TODAY_DASH`n`n$ringkas`n`n$stat"
  & git commit -q -m $msg 2>$null
  if ($LASTEXITCODE -eq 0) { Info 'GIT: commit dibuat.' }
  & git push origin HEAD 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Info 'GIT: push origin HEAD berhasil.'
  } else {
    Warn 'GIT: push gagal. Lakukan login lalu push manual:'
    Warn '  gh auth login   (atau gunakan PAT)'
    Warn '  git push origin HEAD'
  }
  if ($env:REMOTE_EXTRA) {
    & git push $env:REMOTE_EXTRA HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Info "GIT: push $($env:REMOTE_EXTRA) berhasil." } else { Warn "GIT: push $($env:REMOTE_EXTRA) gagal." }
  }
  New-MonthTag
}

# =============================================================================
#  BAGIAN 6 — MODE -Cek
# =============================================================================
function Do-Cek {
  New-Item -ItemType Directory -Force -Path $DATA_DIR, $ERRORS_DIR | Out-Null
  '{0,-32} {1,-10} {2,-6} {3,-8} {4}' -f 'SUMBER', 'STATUS', 'HTTP', 'LATEN(s)', 'SKOR30' | Write-Host
  Write-Host ('-' * 72)
  $laporan = Join-Path $ERRORS_DIR "cek-$TODAY.md"
  [System.IO.File]::WriteAllText($laporan, "# Diagnostik $TODAY_DASH`n", $UTF8NB)
  foreach ($ent in $SOURCES) {
    $ent = $ent.TrimEnd("`r"); if (-not $ent.Trim()) { continue }
    $p = $ent.Split('|')
    if ($p.Count -lt 7) { continue }
    $folder = $p[0]; $nama = $p[1]; $label = $p[2]; $url = $p[3]; $tier = $p[4]; $jadwal = $p[5]; $ext = $p[6]
    $url = $url -replace '\{TODAY\}', $TODAY -replace '\{TODAY_DASH\}', $TODAY_DASH
    $url = $url -replace '\{FROM_ISO\}', (Get-Iso24Jam) -replace '\{TO_ISO\}', $NOW_ISO
    $url = $url -replace '\{FROM_ISO_ENC\}', (UrlEnc (Get-Iso24JamNvd))
    $url = $url -replace '\{TO_ISO_ENC\}', (UrlEnc ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.000")))
    $url = $url -replace '\{FIRMS_KEY\}', "$($env:FIRMS_KEY)"
    if ($jadwal -match '^env:') {
      $evn = $jadwal.Substring(4)
      if (-not [System.Environment]::GetEnvironmentVariable($evn)) {
        '{0,-32} {1}' -f $label, "LEWAT (butuh $evn)" | Write-Host
        Add-Content -LiteralPath $laporan -Value "- $label`: LEWAT (butuh env $evn)" -Encoding UTF8
        continue
      }
    }
    $out = Join-Path $TMPD "cek_$nama"
    Invoke-CurlGet $url $out (Get-ExtraCurl $folder) ''
    $status = 'OK'; if ($script:CURL_EXIT -ne 0) { $status = 'GAGAL' }
    $skor = Get-HealthScore $label
    '{0,-32} {1,-10} {2,-6} {3,-8} {4}%' -f $label, $status, $script:CURL_HTTP, $script:CURL_TIME, $skor | Write-Host
    Add-Content -LiteralPath $laporan -Value "- $label`: $status (HTTP $($script:CURL_HTTP), $($script:CURL_TIME)s, skor $skor%)" -Encoding UTF8
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  }
  Info "Laporan diagnostik: $laporan (tidak di-commit)."
  Info 'Selesai -cek. Tidak ada snapshot/commit.'
}

# =============================================================================
#  BAGIAN 6 — MODE -UjiError
# =============================================================================
function Do-UjiError {
  New-Item -ItemType Directory -Force -Path $DATA_DIR, $ERRORS_DIR | Out-Null
  Log '== UJI SISTEM ERROR =='
  Log 'Menyuntik SATU URL palsu lewat pipeline yang sama (tanpa menulis file commit).'
  $url = 'https://sumber-palsu.invalid/tidak-ada.json'
  $out = Join-Path $TMPD 'uji_error.json'
  Invoke-CurlGet $url $out '' ''
  $ter = Get-TerjemahError $script:CURL_EXIT $script:CURL_HTTP
  $pesan = $ter.Split('|')[0]; $saran = $ter.Split('|')[1]
  Log "exit code : $($script:CURL_EXIT)"
  Log "kode HTTP : $($script:CURL_HTTP)"
  Log "latensi   : $($script:CURL_TIME)s"
  Log "pesan     : $pesan"
  Log "saran     : $saran"
  Log ''
  Log 'Contoh entri yang AKAN ditulis ke data/errors/<YYYYMMDD>.md saat run nyata:'
  Log "## [$NOW_JAM] UJI-ERROR"
  Log "- URL: $url"
  Log "- Exit code: $($script:CURL_EXIT) $DOT HTTP: $($script:CURL_HTTP)"
  Log "- Pesan: $pesan"
  Log "- Saran: $saran"
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  Info 'Selesai -UjiError. Tidak ada file yang di-commit.'
}

# =============================================================================
#  RINGKASAN / MAIN
# =============================================================================
function Process-All {
  foreach ($ent in $SOURCES) {
    $ent = $ent.TrimEnd("`r"); if (-not $ent.Trim()) { continue }
    $p = $ent.Split('|')
    if ($p.Count -lt 7) { continue }
    Process-Source $p[0] $p[1] $p[2] $p[3] $p[4] $p[5] $p[6]
  }
}

function Main {
  New-Item -ItemType Directory -Force -Path $DATA_DIR, $ERRORS_DIR, $HISTORY_DIR, $NEWSFULL_DIR, $DOCS_DIR | Out-Null
  [System.IO.File]::WriteAllText($STATE_FILE, '', $UTF8NB)
  [System.IO.File]::WriteAllText($ANOMALI_FILE, '', $UTF8NB)
  [System.IO.File]::WriteAllText($WATCH_FILE, '', $UTF8NB)
  [System.IO.File]::WriteAllText($RINGKAS_FILE, '', $UTF8NB)
  [System.IO.File]::WriteAllText($CHANGES_FILE, "# Perubahan & status $DASH $TODAY_DASH`n", $UTF8NB)

  Ambil-Lock
  try {
    Info "== $PROJECT_NAME - run $TODAY_DASH ($NOW_ISO) =="
    Process-All
    Process-Wiki
    Process-Rss

    Invoke-Retensi
    Build-Manifest
    Build-Feed
    Send-Telegram
    Invoke-GitFinalize

    Info "== Selesai. OK=$(Status-Count 'OK') SAMA=$(Status-Count 'SAMA') GAGAL=$(Status-Count 'GAGAL') RUSAK=$(Status-Count 'RUSAK') =="
  }
  finally {
    Lepas-Lock
    Remove-Item -LiteralPath $TMPD -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($UjiError) { Do-UjiError }
elseif ($Cek)  { Do-Cek }
else           { Main }
