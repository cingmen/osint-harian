# osint-harian

Tracker data publik harian (**Indonesia + global**). Setiap hari skrip mengunduh
data publik resmi, menyimpan **snapshot per hari**, membandingkannya dengan hari
sebelumnya lewat **mesin diff terstruktur**, mendeteksi **anomali**, mencatat
**error secara terstruktur**, mengirim **notifikasi opsional**, lalu otomatis
**commit + push** ke GitHub dan menampilkan hasilnya di **GitHub Pages**.

> **Semua deterministik, TANPA API LLM.** Tidak ada model bahasa, tidak ada
> inferensi; hanya HTTP + perbandingan teks/angka.

---

## Daftar isi

1. [Prinsip & etika data](#1-prinsip--etika-data)
2. [Fitur](#2-fitur)
3. [Struktur folder](#3-struktur-folder)
4. [Mulai cepat](#4-mulai-cepat)
5. [Perintah](#5-perintah)
6. [Sumber data](#6-sumber-data)
7. [Konfigurasi & menambah sumber](#7-konfigurasi--menambah-sumber)
8. [Skema data + KAMUS DATA](#8-skema-data--kamus-data)
9. [Bagaimana mesin diff bekerja](#9-bagaimana-mesin-diff-bekerja)
10. [Anomali, WATCH, skor kesehatan](#10-anomali-watch-skor-kesehatan)
11. [Sistem error terstruktur](#11-sistem-error-terstruktur)
12. [Telegram, tag bulanan, remote kedua](#12-telegram-tag-bulanan-remote-kedua)
13. [GitHub Pages](#13-github-pages)
14. [Workflow GitHub Actions](#14-workflow-github-actions)
15. [Otomatisasi (cron / Task Scheduler)](#15-otomatisasi-cron--task-scheduler)
16. [Catatan & keterbatasan](#16-catatan--keterbatasan)

---

## 1. Prinsip & etika data

- **Hanya data publik resmi**: tanpa login, tanpa bypass paywall, tanpa scraping
  situs kebocoran.
- **Tanpa data pribadi perorangan** (patuh UU PDP). Yang disimpan hanya data
  institusi/agregat.
- **Kebijakan berita TIGA TIER**:

  | Tier | Sumber | Yang boleh disimpan |
  |------|--------|---------------------|
  | `full` | dokumen resmi & lisensi terbuka (CISA, NVD, BMKG, USGS, WHO, OFAC, pemerintah) | teks penuh — boleh di-commit |
  | `snippet` | media komersial (BBC, Kompas, dll.) | **HANYA** judul + link + kutipan **≤ 300 karakter** per artikel |
  | `lokal` | media komersial, hanya bila `FETCH_FULL_TEXT=1` | teks penuh **HANYA** ke `data/news-full/` yang **gitignored** — tidak pernah di-commit, tidak masuk manifest, tidak tampil di web |

- Repo publik **tidak boleh** memuat artikel penuh media komersial (hak cipta,
  risiko DMCA, Pasal 43 UUHC).
- **Bukan alat nasihat hukum.** Cantumkan selalu disclaimer (sudah ada di footer web).
- Lisensi: **kode** MIT ([`LICENSE`](LICENSE)); **dataset** CC-BY 4.0 ([`LICENSE-DATA`](LICENSE-DATA)).

---

## 2. Fitur

- Snapshot harian per sumber: `data/<sumber>/<YYYYMMDD>-<nama>.<ext>`.
- **Dedup**: snapshot identik dengan yang terakhir → dihapus, dicatat `SAMA`.
- **Validasi konten**: unduhan < 100 byte atau JSON/XML/CSV rusak → `RUSAK`,
  file tidak disimpan.
- **Mesin diff** per jenis sumber (OFAC, KEV, BMKG, USGS, pageviews, RSS, umum).
- **Anomali pageviews** (≥ `ANOMALI_THRESHOLD` × rata-rata 7 hari).
- **WATCH**: headline baru di-scan terhadap kata kunci (case-insensitive).
- **Log** `data/CHANGES-<tanggal>.md` + **laporan error** `data/errors/<tanggal>.md`
  (di-commit sebagai riwayat kesehatan sumber).
- **Skor kesehatan 30 hari** per sumber dari `CHANGES-*.md`.
- **Manifest web** `docs/data.json` + `docs/data.js` + **feed RSS** `docs/feed.xml`.
- **Telegram digest** opsional (satu pesan, ≤ 4000 karakter).
- **Tag bulanan** `YYYY-MM` otomatis (bila ada commit).
- **Daemon lock** `.lock` mencegah dua run tumpang tindih.
- Skrip **tidak crash** bila satu sumber gagal (tanpa `set -e`).

---

## 3. Struktur folder

```
osint-harian/
├── tracker-harian.sh          # skrip utama (macOS/Linux, bash)
├── tracker-harian.ps1         # skrip utama (Windows, PowerShell) — perilaku identik
├── jaga-harian.sh             # penjaga: jalankan otomatis tiap 00:00 (bash)
├── jaga-harian.ps1            # penjaga: jalankan otomatis tiap 00:00 (Windows)
├── setup-git.sh               # penyiapan repo git + remote (sekali saja)
├── config/                    # ⭐ SATU sumber kebenaran untuk kedua skrip
│   ├── pengaturan.conf        #   KEY=value (identitas, ambang, kata kunci, batas tabel)
│   ├── sumber.tsv             #   folder|nama|label|url|tier|jadwal|ext
│   ├── wiki.tsv               #   label|judul_artikel
│   └── rss.tsv                #   nama|url  (urutan = urutan tabel `rss`)
├── docs/                      # yang dilayani GitHub Pages (folder /docs)
│   ├── index.html             # dashboard statis (gelap, responsif, tanpa framework)
│   ├── data.json              # manifest (dibuat ulang tiap run)
│   ├── data.js                # window.DATA = {…} (isi sama, untuk tes file://)
│   └── feed.xml               # RSS "apa yang berubah" (dibuat ulang tiap run)
├── data/                      # DI-COMMIT: snapshot harian
│   ├── bmkg/                  #   20261004-autogempa.json
│   ├── ofac/                  #   20261006-sdn.csv
│   ├── cisa/                  #   kev.json, advisories.xml
│   ├── nvd/                   #   cve.json
│   ├── wiki/                  #   pageviews_<artikel>.json
│   ├── rss/                   #   rss_<feed>.json (judul+link+snippet+wayback)
│   ├── history/               #   (disiapkan untuk arsip tambahan)
│   ├── errors/                #   <tanggal>.md  → DI-COMMIT
│   │   └── cek-<tanggal>.md   #   laporan --cek  → TIDAK di-commit
│   ├── news-full/             #   ⛔ GITIGNORED, tidak pernah di-commit
│   ├── logs/                  #   ⛔ GITIGNORED, log penjaga jaga-<tanggal>.log
│   └── CHANGES-<tanggal>.md   #   log status + blok PERUBAHAN
├── .github/workflows/update.yml
├── .gitignore
├── LICENSE                    # MIT
├── LICENSE-DATA               # CC-BY 4.0
└── .lock                      # dibuat saat run (gitignored)
```

---

## 4. Mulai cepat

```bash
# 1) Siapkan repositori git + remote (SEKALI saja). Pilih salah satu:
#    a) lewat GitHub CLI (buat repo + remote + push sekaligus):
gh repo create <username>/osint-harian --public --source=. --remote=origin --push
#    b) manual (buat repo dulu di GitHub), lalu:
./setup-git.sh https://github.com/<username>/osint-harian.git

# 2) Sunting SATU blok konfigurasi di atas tracker-harian.sh:
#    PROJECT_NAME, CONTACT, SITE_BASE (URL Pages Anda)

# 3) Uji tanpa commit, lalu jalankan:
./tracker-harian.sh --cek        # tes semua sumber + tabel kesehatan
./tracker-harian.sh              # run harian: snapshot + AUTO commit + push

# 4) Aktifkan GitHub Pages: Settings → Pages → Branch: main → Folder: /docs

# 5) (Opsional) biarkan bot jalan sendiri tiap tengah malam:
./jaga-harian.sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File tracker-harian.ps1 -Cek
powershell -ExecutionPolicy Bypass -File tracker-harian.ps1
```

### Login git & auto push

- macOS/Linux: `gh auth login` (disarankan) atau gunakan **PAT**.
- Windows: `gh auth login`, atau **Git Credential Manager**.
- Push gagal tidak mematikan skrip — ia mencetak instruksi login dan lanjut.
- **Auto commit + push**: setiap run selesai, skrip menjalankan `git add -A`,
  commit (`Update harian <tanggal>` + ringkasan perubahan) lalu `git push origin
  HEAD`. Tidak ada perubahan → tanpa commit. Bila tidak ada `.git` di folder ini,
  langkah tersebut **dilewati** dengan pesan jelas (agar tidak menyapu work tree
  repo induk). Gunakan `setup-git.sh` sekali untuk menyiapkannya.

---

## 5. Perintah

| Perintah | Bash | PowerShell | Efek |
|---|---|---|---|
| Run harian | `./tracker-harian.sh` | `tracker-harian.ps1` | Snapshot + diff + manifest + feed + commit + push |
| Diagnostik | `./tracker-harian.sh --cek` | `tracker-harian.ps1 -Cek` | Tes semua sumber (GET ringan), tabel kesehatan, **tanpa snapshot/commit** |
| Uji error | `./tracker-harian.sh --uji-error` | `tracker-harian.ps1 -UjiError` | Suntik 1 URL palsu, tampilkan penangkapan/terjemahan/pelaporan, **tanpa file yang di-commit** |

---

## 6. Sumber data

| Folder | Sumber | Jadwal | Env |
|---|---|---|---|
| `bmkg` | Gempa terkini & dirasakan (Indonesia) | daily | — |
| `ofac` | OFAC SDN (daftar sanksi) | **Senin** | — |
| `cisa` | CISA KEV + Cybersecurity Advisories | daily | — |
| `nvd` | NVD CVE 24 jam (API 2.0) | daily | `NVD_API_KEY` (opsional) |
| `ransomware` | ransomware.live PRO (korban terbaru) | opsional | `RANSOMWARE_API_KEY` |
| `who` | WHO Disease Outbreak News (JSON API) | daily | — |
| `usgs` | USGS Gempa M2.5+ 24 jam | daily | — |
| `nws` | NWS peringatan aktif (**khusus AS**) | daily | — |
| `firms` | NASA FIRMS hotspot (bbox Indonesia) | opsional | `FIRMS_KEY` |
| `opensky` | OpenSky penerbangan (bbox Indonesia) | opsional | `OPENSKY_USER/PASS` |
| `github` | commit github/github-dmca 24 jam | daily | `GITHUB_TOKEN` (opsional) |
| `faa` | FAA NOTAM (contoh WIII) | opsional | `FAA_CLIENT_ID/SECRET` |
| `wiki` | Wikipedia pageviews (7 hari) | daily | — |
| `rss` | BBC, Al Jazeera, Guardian, CNA, CNBC Indonesia, CNN Indonesia, Antara | daily | — |

Sumber berjadwal `env:…` **dilewati** (status `LEWAT`) bila env-nya kosong, dengan
pesan jelas. Sumber `senin` hanya jalan pada hari Senin.

---

## 7. Konfigurasi & menambah sumber

**Semua pengaturan ada di folder `config/`** — SATU sumber kebenaran yang dipakai
**bersama** oleh `tracker-harian.sh` (bash) dan `tracker-harian.ps1` (PowerShell).
Ubah di sana; kedua skrip otomatis ikut. Tidak ada lagi daftar sumber yang
diduplikasi di dua skrip.

| Berkas | Isi |
|---|---|
| `config/pengaturan.conf` | `KEY=value`: identitas, ambang, kata kunci, batas tabel, daftar blokir CI |
| `config/sumber.tsv` | daftar sumber statis (`folder\|nama\|label\|url\|tier\|jadwal\|ext`) |
| `config/wiki.tsv` | artikel pageviews (`label\|judul_artikel`) |
| `config/rss.tsv` | umpan RSS (`nama\|url`; urutannya menentukan urutan tabel `rss`) |

Kunci pada `config/pengaturan.conf`:

| Kunci | Arti |
|---|---|
| `PROJECT_NAME` | Nama proyek (dipakai di User-Agent & judul) |
| `CONTACT` | Kontak di User-Agent (**wajib diisi**; di sini diisi URL situs) |
| `SITE_BASE` | URL absolut Pages, mis. `https://cingmen.github.io/osint-harian` (untuk feed.xml) |
| `ANOMALI_THRESHOLD` | Kelipatan rata-rata 7 hari agar dianggap anomali (default 3) |
| `RETENTION_DAYS` | Umur retensi `data/news-full/` (default 90) |
| `RSS_MAX_ITEMS` | Maks entri `docs/feed.xml` (default 50) |
| `SNIPPET_MAX` | Panjang kutipan maksimum (default 300) |
| `KEYWORDS_WATCH` | Kata kunci pemantauan, dipisah koma (default `sanction,eruption,zero-day`) |
| `BLOKIR_CI` | Label sumber yang host-nya memblokir IP datacenter (dipisah koma). Saat berjalan di CI, HTTP 403/451 dari label ini dicatat `LEWAT` — bukan `GAGAL` — supaya `GAGAL` tetap bermakna |
| `TABEL_CVE_LIMIT` / `TABEL_KEV_LIMIT` / `TABEL_RSS_LIMIT` / `TABEL_USGS_LIMIT` | Batas baris tiap tabel manifest (40 / 20 / 5 / 5) |
| `WIKI_PROJECT` | Proyek Wikimedia (default `id.wikipedia`) |

### Menambah satu sumber

Tambahkan **SATU baris** ke `config/sumber.tsv`:

```
folder|nama|label|url|tier|jadwal|ext
```

- `tier` : `full` | `snippet` | `lokal`
- `jadwal` : `daily` | `senin` | `env:NAMA_ENV`
- `ext` : `json` | `xml` | `csv`
- Token URL yang disubstitusi: `{TODAY}` `{TODAY_DASH}` `{FROM_ISO}` `{TO_ISO}`
  `{FROM_ISO_ENC}` `{TO_ISO_ENC}` `{FIRMS_KEY}`

Contoh:

```
kemenkes|wabah|Kemenkes Wabah|https://example.go.id/api/wabah.json|full|daily|json
```

**Verifikasi** sumber baru tanpa menulis apa pun:

```bash
./tracker-harian.sh --cek
```

### Variabel lingkungan (opsional)

| Env | Kegunaan |
|---|---|
| `FETCH_FULL_TEXT` | `1` → unduh teks penuh artikel media ke `data/news-full/` (gitignored) |
| `NVD_API_KEY` | Header `apiKey` untuk NVD (naikkan rate limit) |
| `GITHUB_TOKEN` | Header `Authorization: Bearer` untuk GitHub API |
| `FIRMS_KEY` | Mengaktifkan sumber NASA FIRMS |
| `RANSOMWARE_API_KEY` | Kunci gratis ransomware.live PRO (`X-API-KEY`); tanpa ini sumber dilewati |
| `OPENSKY_USER` / `OPENSKY_PASS` | Mengaktifkan sumber OpenSky (`curl -u`) |
| `FAA_CLIENT_ID` / `FAA_CLIENT_SECRET` | Mengaktifkan sumber FAA NOTAM |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | Mengaktifkan digest Telegram |
| `REMOTE_EXTRA` | Nama remote git kedua (mis. `backup`) untuk push tambahan |

---

## 8. Skema data + KAMUS DATA

### 8a. Manifest web — `docs/data.json` / `docs/data.js`

```jsonc
{
  "proyek": "osint-harian",
  "tanggal": "2026-10-04",              // tanggal run (lokal)
  "dibuat": "2026-10-04T07:00:00Z",     // waktu run (UTC)
  "situs": "https://cingmen.github.io/osint-harian",
  "ringkasan": { "ok":5, "sama":3, "gagal":2, "rusak":1, "lewat":1, "anomali":1, "watch":2 },
  "sumber": [
    {
      "folder": "bmkg",                 // folder di data/
      "nama": "autogempa",              // nama di belakang tanggal
      "label": "BMKG Gempa Terkini",    // label tampil
      "tier": "full",                   // full | snippet | lokal
      "status": "OK",                   // OK | SAMA | GAGAL | RUSAK | LEWAT
      "http": "200",                    // kode HTTP terakhir
      "laten": 0.31,                    // latensi (detik)
      "snapshot": "20261004-autogempa.json",  // snapshot terakhir ("" bila tak ada)
      "jumlah_file": 12,                // total snapshot tersimpan
      "skor": 100,                      // % OK 30 hari (0-100)
      "riwayat": [0,1,1,…],             // 30 nilai 1/0 (untuk sparkline)
      "diff": "kejadian: 2 · magnitudo tertinggi: 5.4",  // ringkasan PERUBAHAN terakhir
      "pesan_error": "",                // pesan error terakhir
      "saran": ""                       // saran perbaikan error terakhir
    }
  ],
  "anomali": ["Wikipedia: Indonesia — 213% rata-rata (…)"],
  "watch": ["WATCH : sanction — …"],
  "log": [ { "tanggal":"2026-10-04", "ok":5, "gagal":2, "file":"data/CHANGES-20261004.md" } ],
  "tabel": {
    "gempa": [ { "sumber":"BMKG", "magnitudo":"5.4", "lokasi":"Laut Banda, Maluku", "waktu":"…" } ],
    "cve":   [ { "id":"CVE-2026-12345" } ],
    "kev":   [ { "id":"CVE-2026-99999", "vendor":"Acme" } ],
    "rss":   [ { "feed":"bbc", "title":"…", "link":"…", "snippet":"…", "wayback":"…" } ]
  }
}
```

> `docs/data.js` = string `window.DATA = ` + isi JSON di atas + `;` — agar dashboard
> bisa diuji langsung via `file://` (tanpa server).

### 8b. File per sumber — `data/<folder>/<YYYYMMDD>-<nama>.<ext>`

| Folder/nama | Isi | Field penting |
|---|---|---|
| `bmkg/autogempa`, `bmkg/gempadirasakan` | JSON BMKG | `Magnitude`, `Wilayah`, `Tanggal`, `Kedalaman` |
| `ofac/sdn` | CSV sanksi | 1 baris = 1 entri |
| `cisa/kev` | JSON KEV | `cveID`, `vendorProject`, `product` |
| `cisa/advisories` | XML advisories | `<item>` |
| `nvd/cve` | JSON NVD 2.0 | `id` (`CVE-…`) |
| `who/don` | XML WHO DON | `<item>` |
| `usgs/m25hari` | CSV USGS | kolom ke-5 = magnitudo, kolom ke-14 = lokasi |
| `wiki/pageviews_<artikel>` | JSON Wikimedia | `views` per hari |
| `rss/rss_<feed>` | **JSON buatan kami** | `title`, `link`, `snippet` (≤300), `wayback` |

### 8c. Log & error (di-commit)

- `data/CHANGES-<YYYYMMDD>.md` — baris `[HH:MM:SS] STATUS : label — pesan`
  (`OK`/`SAMA`/`GAGAL`/`RUSAK`/`PERUBAHAN`/`ANOMALI`/`WATCH`) + blok `## PERUBAHAN`.
- `data/errors/<YYYYMMDD>.md` — entri error: label, URL, exit code, HTTP, pesan, saran.
- `data/errors/cek-<YYYYMMDD>.md` — laporan `--cek` (**tidak di-commit**).

---

## 9. Bagaimana mesin diff bekerja

Bila snapshot baru **berbeda** dari snapshot terakhir sumber yang sama, ringkasan
Indonesia dibuat dan ditulis ke blok `PERUBAHAN`:

| Sumber | Ringkasan |
|---|---|
| Umum | `baris <a> → <b> (±d)` |
| OFAC SDN | `entri sanksi <a> → <b> (±d)` |
| CISA KEV | daftar **CVE baru masuk KEV**, atau jumlah tetap |
| BMKG | `kejadian: N · magnitudo tertinggi: X` |
| USGS | `kejadian: N · magnitudo tertinggi: X` |
| Pageviews | `views <a> → <b> (±p%)` |
| RSS | `item baru: N` (link yang belum ada di snapshot sebelumnya) |

---

## 10. Anomali, WATCH, skor kesehatan

- **ANOMALI pageviews** — bila nilai harian terakhir > `ANOMALI_THRESHOLD` × rata-rata
  7 hari, dicatat `ANOMALI : <artikel> <x>% rata-rata` dan muncul di manifest &
  digest.
- **WATCH** — headline **baru** (belum ada di snapshot sebelumnya) di-scan terhadap
  `KEYWORDS_WATCH`; cocok → `WATCH : <kata> — <judul>`.
- **Skor kesehatan 30 hari** — persentase `OK`+`SAMA` atas seluruh baris status
  suatu sumber dalam 30 hari terakhir (dari `CHANGES-*.md`). Ditampilkan di kartu
  web dan saat `--cek`.
- **Sparkline** — deret 30 nilai `1/0` (ada/tidak snapshot per hari) digambar
  sebagai `<polyline>` SVG murni (tanpa CDN).

---

## 11. Sistem error terstruktur

Setiap `curl` menangkap **exit code**, **kode HTTP**, dan **latensi**, lalu
diterjemahkan ke pesan + saran bahasa Indonesia:

| Exit | Arti | Saran |
|---|---|---|
| 6 | host tidak ditemukan (DNS) | periksa koneksi/DNS |
| 7 | koneksi ditolak | host/layanan sedang down |
| 22 | HTTP error | lihat kode di bawah |
| 28 | timeout (>90s) | layanan lambat/jaringan |
| 35 | SSL/TLS gagal | sertifikat bermasalah |

HTTP: `400` param salah · `401` butuh auth · `403` diblokir/User-Agent · `404`
endpoint pindah · `429` rate limit · `5xx` masalah server.

**Host yang memblokir IP datacenter.** Sebagian host menolak **semua** permintaan
dari IP runner GitHub dengan `403`, apa pun User-Agent/headernya (terukur: CNBC &
CNN di belakang Cloudflare, serta jalur CISA Advisories; endpoint alternatif pada
host yang sama juga `403`). Label yang terdaftar di `BLOKIR_CI` dicatat **`LEWAT`**
dengan alasan eksplisit selama berjalan di CI (`GITHUB_ACTIONS=true`), dan `--cek`
menandainya **`LEWAT*`** — sehingga hitungan `GAGAL` tetap berarti. Di luar CI
(jaringan lokal) sumber yang sama tetap diuji penuh dan tetap `GAGAL` bila memang
gagal, jadi tidak ada kegagalan nyata yang tersembunyi. Ketiga sumber itu tetap
terisi setiap hari oleh runner lokal (`jaga-harian`).

Setiap `GAGAL`/`RUSAK` menulis entri ke `data/errors/<YYYYMMDD>.md` (folder ini
**di-commit** sebagai riwayat kesehatan sumber — jangan dihapus manual).

---

## 12. Telegram, tag bulanan, remote kedua

- **Telegram** (opsional): bila `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` terisi,
  satu pesan digest dikirim via `api.telegram.org` (jumlah OK/SAMA/GAGAL/RUSAK,
  daftar GAGAL + saran, ringkasan perubahan, anomali, watch). Batas 4000 karakter.
  Gagal kirim → hanya dicatat, tidak crash. Tanpa env → dilewati diam-diam.
- **Tag bulanan** `YYYY-MM`: dibuat & di-push sekali per bulan bila ada commit.
- **REMOTE_EXTRA**: bila diisi (mis. `backup`), skrip push juga ke remote kedua.

---

## 13. GitHub Pages

1. Push repo ke GitHub.
2. **Settings → Pages**.
3. **Source**: *Deploy from a branch*.
4. **Branch**: `main` · **Folder**: `/docs` → **Save**.
5. Situs tersedia di `https://cingmen.github.io/osint-harian`.
6. `SITE_BASE` di skrip sudah diarahkan ke URL di atas (dipakai feed.xml).

Dashboard memakai **path relatif** (`data.js`, `data.json`, `feed.xml`), jadi tidak
butuh konfigurasi tambahan.

> **PWA (opsional)**: untuk menambah mode offline, tambahkan
> `docs/manifest.webmanifest` + service worker sederhana yang meng-cache
> `index.html`, `data.json`, dan `feed.xml`. Belum disertakan agar struktur tetap
> ringkas.

---

## 14. Workflow GitHub Actions

`.github/workflows/update.yml` disertakan dengan **dua pemicu**: `workflow_dispatch`
(manual) dan `schedule` harian pada **`0 17 * * *` UTC = 00:00 WIB (UTC+7)**.

- **Manual**: Tab **Actions** → pilih workflow **update** → **Run workflow**.
- **Otomatis**: berjalan tiap tengah malam WIB di server GitHub, sehingga tetap
  jalan walau PC Anda mati. Cron GitHub bisa **bergeser beberapa menit** saat jam
  sibuk, dan hanya berjalan bila repo aktif.

Isi kredensial opsional lewat **Settings → Secrets and variables → Actions**
(mis. `RANSOMWARE_API_KEY`, `FIRMS_KEY`, `OPENSKY_USER`). Bila Anda hanya ingin
penjaga lokal (`jaga-harian`) yang berjalan, hapus blok `schedule` di workflow.

**Catatan runner GitHub:** CISA Advisories, RSS CNBC, dan RSS CNN selalu `403`
dari IP runner (blokir IP/ASN, bukan header) sehingga dicatat `LEWAT` di CI —
lihat §11 dan `BLOKIR_CI` pada §7. Runner lokal mengisinya normal.

---

## 15. Otomatisasi (cron / Task Scheduler)

### Penjaga harian di terminal (tengah malam)

Ingin bot jalan sendiri tiap **jam 12 malam** cukup dengan membiarkan terminal
terbuka? Jalankan penjaga:

```bash
./jaga-harian.sh              # tunggu sampai 00:00 berikutnya, lalu tiap hari
./jaga-harian.sh --sekarang   # jalankan sekarang, lalu lanjut tiap 00:00
```

```powershell
powershell -ExecutionPolicy Bypass -File .\jaga-harian.ps1
powershell -ExecutionPolicy Bypass -File .\jaga-harian.ps1 -Sekarang
```

Penjaga menghitung selisih detik ke 00:00 lokal, `sleep`, menjalankan tracker,
lalu mengulang. Keluaran disimpan ke `data/logs/jaga-<tanggal>.log` (gitignored).
Tekan **Ctrl+C** untuk berhenti. Karena tracker memakai `.lock`, berhenti di
tengah run lalu jalan lagi tidak akan menumpuk proses. Agar tetap jalan tanpa
terminal, gunakan cron / **Task Scheduler** di bawah.

**macOS/Linux (cron)** — setiap hari 07:00:

```cron
0 7 * * * cd /path/ke/osint-harian && ./tracker-harian.sh >> data/cron.log 2>&1
```

**Windows (Task Scheduler)**: buat tugas harian yang menjalankan

```
powershell -ExecutionPolicy Bypass -File C:\path\osint-harian\tracker-harian.ps1
```

**Lock `.lock`**: sebelum mulai skrip memeriksa `.lock` berisi PID. Bila proses
masih hidup → keluar (mencegah **double-run**); bila basi → dihapus dan lanjut.
Lock dihapus saat skrip selesai.

---

## 16. Catatan & keterbatasan

- **NWS khusus AS**; **FAA butuh registrasi** (`FAA_CLIENT_ID/SECRET`).
- Feed mati / endpoint pindah → dicatat `GAGAL`/`RUSAK`, **tidak** menyimpan file.
- `data/news-full/` (tier lokal) **wajib** tetap di `.gitignore`; retensi default
  90 hari, bisa diubah lewat `RETENTION_DAYS`.
- `data/errors/` jangan dihapus manual (riwayat kesehatan sumber).
- Di Windows (MSYS2 + Git Bash), setiap proses luar relatif lambat; skrip sudah
  dioptimalkan (array tanggal sekali hitung, indeks skor sekali baca, pencarian
  snapshot memakai glob bash) agar run tetap wajar.
- Beberapa endpoint eksternal bisa lambat/timeout — itu normal; status akan jelas.
- **Terjemahan peringatan**: bila satu sumber gagal, run tetap lanjut sampai selesai.
- **Validasi `RUSAK`**: berkas sah yang berakhir newline tetap diterima (spasi
  ujung diabaikan), dan JSON kosong yang sah (`[]` / `{}`) berarti "tidak ada
  hasil", **bukan** rusak — sehingga hasil kosong tidak lagi salah dilaporkan.

---

## 17. Riwayat perbaikan (2026-10-05 → 2026-10-06)

Diperbaiki dari laporan error run nyata `data/errors/2026-10-04.md`:

| Gejala | Akar masalah | Perbaikan |
|---|---|---|
| **CISA Advisories** & XML lain → `RUSAK` (HTTP 200) | Validasi membaca byte terakhir lalu membuang spasi; berkas XML sah berakhir newline → dianggap "tanpa `>`" | Karakter pertama/terakhir kini diambil dari potongan lalu spasi dibuang (kedua skrip) |
| **GitHub DMCA** → `RUSAK` (HTTP 200) | Respons sah `[]` (tak ada commit 24 jam) < 100 byte → ditolak | JSON kosong sah (`[]`/`{}`) kini diterima |
| **WHO DON** → `404` | RSS lama dipensiunkan | Pakai JSON API resmi `who.int/api/news/diseaseoutbreaknews` |
| **ransomware.live** → `404` | Domain lama menyajikan situs, bukan API | Pakai API PRO `api-pro.ransomware.live/victims/recent` + header `X-API-KEY` (butuh `RANSOMWARE_API_KEY`; dilewati bila kosong) |
| **RSS kompas** → `404` | Feed Kompas dihapus | Diganti **CNBC Indonesia** (`cnbcindonesia.com/rss`) |
| **RSS antara** → `403` | Jalur `/rss/news` diblokir | Diganti `/rss/top-news` (terverifikasi HTTP 200) |
| **OpenSky** → `timeout (exit 28)` | Tanpa kredensial sering diblokir/timeout | Dijadikan `env:OPENSKY_USER` (dilewati bila tak ada kredensial) |
| **CISA KEV** tabel kosong | KEV di-render JSON rapi (spasi setelah `:`), regex lama mengasumsikan JSON padat → tak pernah cocok | Ekstraksi id & vendor toleran spasi, lalu dipasangkan |
| **RSS** dedup/diff selalu "snapshot pertama" | Berkas disimpan `-bbc.json` padahal semua lookup memakai `rss_bbc` | Nama berkas disamakan `-rss_<feed>.json` |
| **`docs/data.json` tidak valid** saat data banyak | Tabel (`gempa`/`cve`/`kev`/`rss`) tidak menulis koma pemisah (flag `first` hilang di subshell pipa) | Loop memakai process substitution; koma ditulis benar |
| Tabel `rss` / `kev` kosong walau data ada | Bug di atas + regex JSON padat | Lihat dua baris sebelumnya |
| **Konfigurasi terduplikasi** di dua skrip (rawan divergen) | `SOURCES`/`WIKI_ARTICLES`/`RSS_FEEDS`/ambang/kata kunci/batas tabel ditulis dua kali (bash + PowerShell) | Diekstrak ke **`config/`** (satu sumber kebenaran); kedua skrip memuatnya. `RSS_NAMES` & batas tabel kini berasal dari config |
| **`github` (GitHub DMCA) → `exit 22, HTTP 000`** di Actions | Header `Authorization:Bearer <token>` disusun sebagai string lalu dipecah IFS/spasi → token menjadi argumen terpisah dan curl menganggapnya URL | Header kini dibawa sebagai **array** (`EXTRA_ARGS` / `$script:EXTRA_ARGS`) di kedua skrip; berlaku juga untuk `NVD_API_KEY` & `RANSOMWARE_API_KEY` |
| **Data harian hilang tanpa pesan** (3 commit lokal tertinggal di belakang commit Actions) | Job Actions sudah push lebih dulu → push lokal ditolak non-fast-forward dan hanya tercatat sebagai peringatan | `git_push_sinkron` / `Invoke-GitPushSynced`: coba push, bila ditolak lakukan `fetch` + `rebase --autostash` lalu push ulang; bila rebase konflik, dibatalkan bersih dan push manual diimbau |
| **3 `GAGAL` palsu setiap run CI** (CISA Advisories, RSS CNBC, RSS CNN) | Host memblokir IP/ASN runner GitHub: semua variasi User-Agent tetap `403`, endpoint alternatif juga `403` | `BLOKIR_CI` di `config/pengaturan.conf`: saat CI dicatat `LEWAT` dengan alasan jelas (`LEWAT*` di `--cek`), di luar CI tetap `GAGAL` |
| **Manifest lambat** (bash 88 dtk; PowerShell 1,6 dtk) | Bash: ratusan fork subshell `$(jesc …)` per field + 32 fork `date`; PowerShell: `Get-ChildItem`/`Test-Path` diulang per sumber | Bash: helper `jescv` tanpa-fork, `_siapkan_hari` satu-proses awk (dengan fallback portable), substitusi token URL ber-fork hanya bila perlu; PowerShell: cache daftar berkas + himpunan nama + cache state. **Manifest+feed: bash 88→24 dtk, PowerShell 1,6→1,35 dtk**, keluaran identik |

---

Lisensi kode: **MIT** · Lisensi data: **CC-BY 4.0**.
