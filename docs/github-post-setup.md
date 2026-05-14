# GitHub リポジトリ Post-Setup ガイド

最終更新: 2026-05-15

`homelab-infra` リポジトリを GitHub に push した直後にやっておくと業務品質が上がる作業群。

## 1. README 拡充

GitHub のリポジトリトップで最初に見える文書。3 ヶ月後の自分・他者が「このリポジトリは何で、どこから読めばよいか」を 30 秒で把握できる粒度に整える。

含めると有用:
- リポジトリの目的
- 主要対象（システム構成）
- ディレクトリ構成
- 運用ルール（コミット粒度、機微情報の扱い）
- クイックリファレンス（重要ドキュメントへのリンク）
- 主要スクリプトの一覧

`README.md` をエディタで編集 → commit → push で GitHub 上に即反映。

## 2. タグで節目を残す

「動作確認済の状態」を tag として記録すると、後から `git checkout v1.0.0` で完全復元できる。

### コマンド

```bash
cd /home/shotayagami/homelab-infra

# Annotated tag (推奨、メッセージとメタデータが残る)
git tag -a v1.0.0 -m "Phase 1-6 complete: Zabbix 7.0.26 LTS + 3-channel notification (ntfy/Discord/Mailgun) + auto backup"

# GitHub に push
git push --tags

# 確認
git tag -l
git show v1.0.0
```

### GitHub UI 上の見え方

- `https://github.com/<user>/homelab-infra/tags` でタグ一覧
- Release を作りたい場合は <https://github.com/...../releases/new> で tag を選択 → Release ノートを追加

### 命名規則（業務観点）

- **Semantic Versioning (SemVer)**: `vMAJOR.MINOR.PATCH`
  - MAJOR: 破壊的変更
  - MINOR: 後方互換性ある機能追加
  - PATCH: バグ修正
- ホームラボ用なら段階的に v1.0.0 → v1.1.0 → v1.1.1 で十分

## 3. Branch protection rules（業務向け）

`main` ブランチを保護して、直接 push を禁止し PR 経由のみに。

### 設定場所

`https://github.com/<user>/<repo>/settings/branches`

### 推奨ルール（チーム運用時）

1. **Branch name pattern**: `main`
2. **Require a pull request before merging**: ✓
   - **Require approvals**: 1 以上（業務では 2 推奨）
   - **Dismiss stale pull request approvals when new commits are pushed**: ✓
3. **Require linear history**: ✓（rebase 強制、merge commit 禁止）
4. **Do not allow bypassing the above settings**: ✓（管理者も例外なし）
5. **Restrict who can push to matching branches**: 必要に応じて

### 自分しか触らない場合

過剰な設定はワークフローを遅らせるので、**OFF のままで OK**。チーム化する際に有効化する。

## 4. Secret scanning（機微情報の機械的検出）

GitHub 標準機能で、commit / push される内容を機械的にスキャンし、API token・秘密鍵などのパターンを検出。

### Plan による可用性の制限（2026 時点）

| 機能 | Public repo | Private (Free/Pro) | Private (Advanced Security 有料) |
|---|---|---|---|
| Dependabot alerts/updates | 無料 | **無料** | 有料 |
| Secret scanning | 無料 | **不可** | 有料 |
| Push protection | 無料 | **不可** | 有料 |

**本リポジトリ (Private + 個人 Free アカウント) では Secret scanning は使えない**。
Settings → Advanced Security に Dependabot 系のみ表示されることが正常な挙動。

### 代替策: gitleaks + pre-commit hook（推奨）

GitHub の Secret scanning 相当を**ローカルで完結**させる OSS。push 前に検出することで、GitHub 側に到達させない設計。

#### インストール

```bash
TAG=$(curl -sI -L -o /dev/null -w "%{url_effective}" https://github.com/gitleaks/gitleaks/releases/latest | sed 's|.*/||')
VER=${TAG#v}
URL="https://github.com/gitleaks/gitleaks/releases/download/${TAG}/gitleaks_${VER}_linux_x64.tar.gz"

cd /tmp
wget -q "$URL" -O gitleaks.tar.gz
tar -xzf gitleaks.tar.gz gitleaks
sudo install -m 0755 gitleaks /usr/local/bin/gitleaks
gitleaks version
```

#### Pre-commit hook 連携

`.git/hooks/pre-commit` で `gitleaks git --pre-commit --staged --redact --no-banner` を呼び、staged content から機微情報を検出。

**重要 (v8 移行ポイント)**:
- v7 までは `gitleaks protect --staged` だったが、v8 で `protect` サブコマンドが廃止
- v8 では `gitleaks git --pre-commit --staged` が正式
- `gitleaks detect` も v8.30 では `git`/`dir`/`stdin` に分割

#### 既存履歴のスキャン（過去 commit を全件チェック）

```bash
cd /home/shotayagami/homelab-infra

# Git 履歴全部
gitleaks git --redact --no-banner --log-opts="--all"

# ワーキングディレクトリ (未 commit 含む)
gitleaks dir --redact --no-banner .
```

漏洩を発見した場合の対処:
1. 該当認証情報を**即時 rotate / 無効化**
2. 履歴から削除 (`git filter-repo`)、ただし他人が clone 済なら遡及不可能
3. push 後の漏洩は実質「漏洩」確定として扱う

### 業務観点

- **Public リポジトリでは GitHub の Secret scanning が必須レベル**: シークレット流出は即座にクローン → 悪用される
- **Private + GHAS なら GitHub の機能を活用**: 業務環境では費用対効果あり
- **Private + Free では gitleaks + pre-commit で代替**: ローカル運用で機能等価性は十分

## 5. その他の発展

### a. GitHub Actions による自動チェック

`.github/workflows/lint.yml` を追加して push 時に:
- `shellcheck` でスクリプトを静的解析
- `yamllint` で zabbix-configs YAML を構文チェック
- `markdownlint` でドキュメント整合性

CI に組み込めば「commit を入れる前に気付ける」体制になる。

### b. Issues + Projects で TODO 管理

Phase 4-B (Nextcloud) や Phase 6-E (rotation) などの残作業を Issue 化:

- Issue: `Phase 4-B: Add Nextcloud monitoring`
- Label: `enhancement`, `phase-4`
- Milestone: `v1.1.0`

Project (Board) で「Backlog / In Progress / Done」を可視化。

### c. Releases で安定版を配布

タグを打った後、GitHub UI の Releases から:
1. **Draft a new release** → タグを選択
2. **Release title**: `v1.0.0 — Initial monitoring infra`
3. **Description**: 主要成果・既知問題・移行手順
4. **Publish release**

業務で同じ構成を他環境にもデプロイする際の起点になる。

### d. CODEOWNERS でレビュー必須化

複数人運用時、特定ディレクトリの変更時に自動で reviewer 指定:

```
# .github/CODEOWNERS
docs/             @<docs-owner>
scripts/          @<infra-owner>
zabbix-configs/   @<monitoring-owner>
```

## 6. 本リポジトリでの実施記録

### 2026-05-15: 初期構築

- リポジトリ作成 (Private): <https://github.com/shotayagami/homelab-infra>
- 初回 commit `f19919e` (15 objects, 1428 行)
- SSH 鍵 `homelab-infra` を登録、SSH 経由で push
- Tag `v1.0.0` を打って Phase 1-6 完走を記録（後述）

### 2026-05-15: README 拡充 + v1.0.0 タグ

- README にディレクトリ構成図・運用ルール・クイックリファレンスを追記
- `git tag -a v1.0.0` で Phase 1-6 完走をマーク、`git push --tags` で GitHub へ反映

### 後日（手動 UI 作業）

- [ ] Branch protection rules: 一旦 OFF のまま（自分しか触らないため）
- [x] ~~Secret scanning + Push protection 有効化~~ → **Private + Free では使用不可**、gitleaks で代替済
- [ ] Phase 4-B Issue 化（残作業の可視化）
- [ ] Phase 6-E (credential rotation) Issue 化

### 2026-05-15: gitleaks 導入

- GitHub Secret scanning が Private repo (Free) で使えないため、OSS の **gitleaks v8.30.1** を `/usr/local/bin/` に導入
- `.git/hooks/pre-commit` を v8 syntax (`gitleaks git --pre-commit --staged`) で実装
- 全履歴 (3 commits, 82 KB) を `gitleaks git --log-opts=--all` でスキャン → **leaks found: 0** 確認
- 偽 secret (AWS key / GitHub PAT / Slack webhook) で commit 試行 → hook が正しく block することを確認
- gitleaks 未インストール時は簡易 regex fallback で動作
- 業務観点では「ローカル完結 + push 後の GitHub 側保護なし」を理解した上で運用

### gitleaks v7 → v8 migration 注意

v7 と v8 でコマンド体系が大きく変わったため、古い情報の hook 設定例は動かない:

| v7 | v8 |
|---|---|
| `gitleaks protect --staged` | `gitleaks git --pre-commit --staged` |
| `gitleaks detect` (デフォルト = git) | `gitleaks git` |
| `gitleaks detect --no-git` | `gitleaks dir` |
| (stdin パイプ) | `gitleaks stdin` |

`--no-banner` も v8 で追加されたフラグ。`--redact` は v7/v8 共通。
