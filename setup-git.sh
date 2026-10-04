#!/usr/bin/env bash
# =============================================================================
#  osint-harian — penyiapan repositori git (jalankan SEKALI).
#
#  Script tracker (tracker-harian.sh) sudah otomatis commit + push setiap selesai
#  crawl. Yang perlu disiapkan hanyalah repositori git + remote (origin).
#
#  Pemakaian:
#    ./setup-git.sh                      # init lokal + commit awal; remote dilewati
#    ./setup-git.sh <URL_REPO>           # set origin ke URL lalu push
#    ./setup-git.sh git@github.com:user/osint-harian.git
#
#  Jika GitHub CLI (gh) tersedia dan sudah login, Anda bisa membuat repo + remote
#  sekaligus dengan:
#    gh repo create <user>/osint-harian --public --source=. --remote=origin --push
# =============================================================================
set -u

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR" || exit 1
REMOTE_URL="${1:-}"

if [ ! -d .git ]; then
  git init -q && echo "[INFO] git init selesai."
  git branch -M main 2>/dev/null || true
else
  echo "[INFO] Repositori git sudah ada."
fi

# Identitas commit (lokal repo) bila belum diatur — agar commit tidak gagal.
[ -n "$(git config user.name 2>/dev/null)" ]  || git config user.name  "osint-harian bot"
[ -n "$(git config user.email 2>/dev/null)" ] || git config user.email "osint-harian@users.noreply.github.com"

if [ -n "$REMOTE_URL" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
  else
    git remote add origin "$REMOTE_URL"
  fi
  echo "[INFO] origin → $REMOTE_URL"
fi

git add -A
if git diff --cached --quiet; then
  echo "[INFO] Tidak ada perubahan untuk di-commit."
else
  git commit -q -m "Inisialisasi osint-harian" && echo "[INFO] Commit awal dibuat."
fi

if git remote get-url origin >/dev/null 2>&1; then
  if git push -u origin main 2>/dev/null; then
    echo "[INFO] Push awal berhasil."
  else
    echo "[WARN] Push gagal. Lakukan 'gh auth login' atau isi PAT, lalu: git push -u origin main"
  fi
else
  echo "[INFO] Belum ada remote origin. Jalankan ulang dengan URL repo, atau:"
  echo "       gh repo create <user>/osint-harian --public --source=. --remote=origin --push"
fi
