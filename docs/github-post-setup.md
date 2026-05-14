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
cd /home/t-ando/homelab-infra

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

### 設定場所

`https://github.com/<user>/<repo>/settings/security_analysis`

### 有効化推奨項目

- **Secret scanning**: ✓
  - GitHub が認証情報パターンを検出 → 通知
- **Push protection**: ✓（強く推奨）
  - 既知のシークレットパターンを含む push を**自動拒否**
  - 例えば GitHub PAT、Slack token、AWS access key などが該当
- **Dependabot alerts**: 任意（コード依存ライブラリの脆弱性検知。本リポジトリは依存少ないので優先度低）

### 業務観点

- **Public リポジトリでは必須レベル**: シークレット流出は即座にクローン→悪用される
- **Private でも有効化推奨**: 内部脅威・誤操作対策、また将来 public 化する場合の予防
- 本リポジトリは Private だが、`.git` 履歴に過去誤って混入させた場合のラストガード

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
- [ ] Secret scanning + Push protection: 有効化推奨（業務本番化時の必須項目）
- [ ] Phase 4-B Issue 化（残作業の可視化）
- [ ] Phase 6-E (credential rotation) Issue 化
