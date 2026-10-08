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

# Identitas commit (config LOKAL — menimpa identitas global Anda untuk repo ini).
# GitHub mengaitkan commit ke sebuah akun lewat EMAIL, dan format noreply yang
# benar adalah "<id>+<username>@users.noreply.github.com". Alamat seperti
# "<username>@users.noreply.github.com" tidak cocok dengan akun mana pun, jadi
# commit hanya tampil sebagai nama tanpa profil dan tidak masuk contribution
# graph. Karena itu identitas di sini diambil dari akun GitHub via `gh`, bukan
# ditulis sebagai bot.
if [ -z "$(git config user.name 2>/dev/null)" ] || [ -z "$(git config user.email 2>/dev/null)" ]; then
  gh_login=""; gh_name=""; gh_id=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh_login="$(gh api user --jq .login 2>/dev/null || true)"
    gh_name="$(gh api user --jq '.name // .login' 2>/dev/null || true)"
    gh_id="$(gh api user --jq .id 2>/dev/null || true)"
  fi
  if [ -n "$gh_login" ] && [ -n "$gh_id" ]; then
    gh_email="${gh_id}+${gh_login}@users.noreply.github.com"
    git config user.name  "${gh_name:-$gh_login}"
    git config user.email "$gh_email"
    echo "[INFO] Identitas commit repo → ${gh_name:-$gh_login} <$gh_email>"
  else
    echo "[WARN] Identitas commit belum ada dan gh tidak tersedia. Atur manual:"
    echo "         git config user.name  \"Nama Anda\""
    echo "         git config user.email \"<id>+<username>@users.noreply.github.com\""
  fi
fi

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
