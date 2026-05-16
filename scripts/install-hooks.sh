#!/usr/bin/env bash
#
# Git hooks をリポジトリ管理版から .git/hooks/ に symlink する。
#
# 背景:
#   .git/hooks/ は Git の追跡対象外なので、clone 直後は hook が無効。
#   このスクリプトでリポジトリ内の scripts/git-hooks/* を symlink して
#   一発で有効化する。
#
# 使い方:
#   $ cd ~/homelab-infra
#   $ bash scripts/install-hooks.sh
#
# 冪等性:
#   - 既に正しい symlink があれば SKIP
#   - 既存ファイル (symlink ではない実体) があれば .bak にバックアップして置換
#
# 履歴:
#   2026-05-15 初版 (Issue #4 対応)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: Git リポジトリ内で実行してください。" >&2
  exit 1
fi

SRC_DIR="$REPO_ROOT/scripts/git-hooks"
DST_DIR="$REPO_ROOT/.git/hooks"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "ERROR: $SRC_DIR が存在しません。" >&2
  exit 1
fi

echo "=== Installing git hooks ==="
echo "  source:      $SRC_DIR"
echo "  destination: $DST_DIR"
echo

mkdir -p "$DST_DIR"

shopt -s nullglob
hooks=("$SRC_DIR"/*)
shopt -u nullglob

if [[ ${#hooks[@]} -eq 0 ]]; then
  echo "WARN: $SRC_DIR に hook ファイルがありません。"
  exit 0
fi

for src in "${hooks[@]}"; do
  name="$(basename "$src")"
  dst="$DST_DIR/$name"

  # source は実行可能にしておく
  chmod +x "$src"

  if [[ -L "$dst" ]]; then
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" || "$current" == "../../scripts/git-hooks/$name" ]]; then
      echo "  SKIP (already linked): $name"
      continue
    fi
    echo "  REPLACE symlink: $name (was $current)"
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    echo "  BACKUP existing $name -> $name.bak"
    mv "$dst" "$dst.bak"
  fi

  # .git/hooks/<name> -> ../../scripts/git-hooks/<name> (相対 symlink)
  ln -s "../../scripts/git-hooks/$name" "$dst"
  echo "  LINK: $name -> ../../scripts/git-hooks/$name"
done

echo

# gitleaks 依存チェック
if command -v gitleaks >/dev/null 2>&1; then
  echo "OK: gitleaks $(gitleaks version 2>/dev/null | head -1) が利用可能。"
else
  cat >&2 <<'EOF'
WARN: gitleaks が未インストールです。pre-commit hook は簡易 regex に fallback します。

  インストール推奨:
    TAG=$(curl -sI -L -o /dev/null -w "%{url_effective}" \
      https://github.com/gitleaks/gitleaks/releases/latest | sed 's|.*/||')
    VER=${TAG#v}
    URL="https://github.com/gitleaks/gitleaks/releases/download/${TAG}/gitleaks_${VER}_linux_x64.tar.gz"
    cd /tmp && wget -q "$URL" -O gitleaks.tar.gz && tar -xzf gitleaks.tar.gz gitleaks
    sudo install -m 0755 gitleaks /usr/local/bin/gitleaks
EOF
fi

# secretlint 依存チェック (Node.js devDependency)
if [[ -x "$REPO_ROOT/node_modules/.bin/secretlint" ]]; then
  echo "OK: secretlint $("$REPO_ROOT/node_modules/.bin/secretlint" --version 2>/dev/null) が利用可能。"
else
  cat >&2 <<'EOF'
WARN: secretlint が未インストールです。pre-commit hook の Check 3 はスキップされます。

  インストール:
    cd "$(git rev-parse --show-toplevel)" && npm install
EOF
fi

echo
echo "=== 完了 ==="
