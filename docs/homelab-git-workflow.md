# Homelab インフラの Git ワークフロー

最終更新: 2026-05-15

ホームラボ用 Proxmox VE 環境の構成資産（スクリプト・ドキュメント・設定 export）を Git で版管理する運用ガイド。

## 1. なぜ Git を使うか

| 効果 | 業務観点での価値 |
|---|---|
| **差分が見える** | 「いつ・誰が・なぜ・どう変えたか」を `git log` で 1 分以内に追跡 |
| **過去に戻れる** | 設定変更で障害発生 → 数秒で `git checkout` で復旧 |
| **レビュー文化** | Pull/Merge Request で第三者の目を通す品質ゲート |
| **複数人運用** | コンフリクトを Git が自動検出、勝手な上書き防止 |
| **IaC への布石** | Terraform/Ansible で運用する場合の前提インフラ |
| **災害復旧** | リポジトリ自体を別ロケーションに push、コードがあれば再構築可能 |

## 2. 何を Git 管理するか

### 含めるもの

- スクリプト全般 (`scripts/`)
- ドキュメント (`docs/`)
- Zabbix 等の設定 export スナップショット (`zabbix-configs/`)
- README、`.gitignore`、`.env.example`

### 含めないもの（`.gitignore` で除外）

- `.env` （実値の認証情報入り）
- `*.pem`, `*.key`, `*.crt`, `*.pfx`（証明書・秘密鍵）
- `*-credentials`, `*.tunnel_token`（個別認証情報）
- `*.bak`, `.DS_Store`, `.vscode/`（ローカル・OS 一時ファイル）

## 3. 推奨ディレクトリ構成

```
~/homelab-infra/                          ← Git リポジトリのルート
├── .gitignore
├── .env.example                          ← .env のテンプレ（値は空 or プレースホルダ）
├── README.md
├── docs/
│   ├── proxmox-zabbix-monitoring.md
│   └── homelab-git-workflow.md          ← 本書
├── scripts/
│   ├── proxmox-deploy-puter-cloudflare-access.sh
│   ├── proxmox-setup-extra-storage-sda-sdb.sh
│   └── proxmox-zabbix-set-host-location.sh
└── zabbix-configs/
    └── 2026-05-14/
        ├── zabbix-config.yaml
        ├── actions.json
        ├── users.json
        └── global_macros.json
```

## 4. 初期セットアップ

### Step 1: リポジトリ初期化

```bash
cd /home/t-ando
mkdir -p homelab-infra/{docs,scripts,zabbix-configs}
cd homelab-infra

# .gitignore
cat > .gitignore <<'EOF'
# 認証情報
.env
*.env
*.tunnel_id
*.tunnel_token
*.pem
*.key
*.crt
*.pfx
*-credentials
.dns-cert-password
.zabbix-db-credentials
.ntfy-credentials

# OS
.DS_Store
*.swp
*.swo
*~

# エディタ
.vscode/
.idea/

# 一時ファイル
/tmp/
*.bak
*.bak.*
EOF

# README
cat > README.md <<'EOF'
# homelab-infra

ホームラボ Proxmox VE 環境の構成管理リポジトリ。

## 構成
- `docs/`: 各サービスの運用ドキュメント
- `scripts/`: デプロイ・運用スクリプト
- `zabbix-configs/`: Zabbix の設定スナップショット (configuration.export)

## 使い方
- 機微情報は `.env` に書く（コミット禁止、`.env.example` 参照）
- 変更は trunk commit ではなく、小さな commit を積み重ねる
- 環境変更時は対応する docs を同じ commit で更新
EOF

git init -b main
git config user.name "Takao Ando"
git config user.email "<your-email>"
```

### Step 2: 既存ファイル取り込み

```bash
cp /home/t-ando/proxmox-deploy-puter-cloudflare-access.sh    scripts/
cp /home/t-ando/proxmox-setup-extra-storage-sda-sdb.sh       scripts/
cp /home/t-ando/proxmox-zabbix-set-host-location.sh          scripts/
cp /home/t-ando/proxmox-zabbix-monitoring.md                  docs/
cp /home/t-ando/homelab-git-workflow.md                       docs/
cp -r /home/t-ando/zabbix-configs/*                           zabbix-configs/
```

### Step 3: `.env.example` 作成

実値は載せず、フォーマットだけ示すテンプレート。

```bash
cat > .env.example <<'EOF'
export CF_API_TOKEN=<your-cf-api-token>
export CF_DNS_API_TOKEN=<your-cf-dns-api-token>
export CF_ACCOUNT_ID=<your-cf-account-id>
export CF_ZONE_ID=<your-zone-id>
export CF_TUNNEL_TOKEN=<tunnel-token>
export CF_TUNNEL_ID=<tunnel-uuid>
export PUTER_DOMAIN=puter.example.com
EOF
```

### Step 4: 機微情報チェック → 初回コミット

```bash
# .env が含まれていないことを必ず確認
git status
git ls-files --others --exclude-standard

git add .
git commit -m "Initial commit: import existing homelab artifacts"

git log --oneline
```

### Step 5: リモート（Gitea / GitHub）に push

```bash
# Gitea/GitHub で新規空リポジトリを作る → URL を取得

git remote add origin https://gitea.example.com/<user>/homelab-infra.git
git push -u origin main
```

## 5. 日々の運用ワークフロー

### A. 設定を変えた時

```bash
cd ~/homelab-infra

# 変更を加える（docs/, scripts/, zabbix-configs/）
$EDITOR docs/proxmox-zabbix-monitoring.md

# 差分を確認
git diff

# ステージング → コミット (1 変更 1 commit)
git add docs/proxmox-zabbix-monitoring.md
git commit -m "Zabbix: change ntfy topic from zabbix-alerts to home-monitoring

Reason: Renamed to better reflect scope (not just Zabbix).
Updated mediatype Topic parameter via API."

git push
```

### B. 過去設定への復元

```bash
# 履歴を見る
git log --oneline -- zabbix-configs/

# 特定の過去ファイルを見る
git show <commit-hash>:zabbix-configs/2026-05-14/zabbix-config.yaml

# ファイル単位で戻す
git checkout <commit-hash> -- zabbix-configs/2026-05-14/

# 安全に新ブランチで実験
git checkout -b restore-test <commit-hash>
```

### C. 動作確認済の節目を Tag で残す

```bash
git tag -a v1.0.0-monitoring-complete -m "Phase 1-6 complete: monitoring + 3-channel notification working"
git push --tags
```

## 6. 機微情報を守る習慣

### 絶対ルール

1. **`.env` や認証情報は絶対に `git add` しない**
2. **誤って commit したら push 前に `git reset --soft HEAD~1`** で取り消す
3. **push 後に気付いたら** → 過去履歴から削除する作業はコストが高いので、
   - 該当認証情報を**全部 rotate**（無効化）
   - 後追いで `git filter-repo` 等で履歴から削除
4. **平文の API token / SMTP password / webhook URL** は会話履歴やドキュメントにも残さない

### Pre-commit hook で機械的にブロック

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/bash
# 機微情報らしき長い文字列が含まれていれば commit を止める
if git diff --cached --name-only | xargs grep -lE '(api_key|password|token|secret|webhook).*=.*[a-zA-Z0-9]{20,}' 2>/dev/null; then
  echo "ERROR: 認証情報らしき文字列がコミット対象に含まれています"
  echo "  git diff --cached --name-only で対象を確認してください"
  exit 1
fi
EOF
chmod +x .git/hooks/pre-commit
```

## 7. Commit Message の書き方（業務観点）

良い commit message は以下の構造:

```
<対象>: <短い変更概要>

<より詳しい説明>

Reason: <なぜ変更したか>
Impact: <何に影響するか>
```

例:

```
Zabbix: add Discord media type via API (mediatypeid=39)

Created custom Discord webhook media type with built-in template parameters.
Set {$ZABBIX.URL} global macro to http://192.168.11.55 (required by template).

Reason: Phase 5-B notification channel setup
Impact: Admin user now receives all triggers via Discord channel home.yagamin.net
```

「何を」変えたかはコードから読める。**「なぜ」**はメッセージにしかない。

## 8. 高度な発展

### Branch を使った実験

```bash
git checkout -b experiment/dns2-dot-doh-retry
# 試行錯誤
# うまく行ったら main へマージ
git checkout main
git merge experiment/dns2-dot-doh-retry
# ダメなら破棄
git branch -D experiment/dns2-dot-doh-retry
```

### IaC への布石

Git 管理が習慣化したら次のステップ:

- **Ansible Playbook 化**: スクリプトを宣言的に書き直し、`ansible-playbook -i inventory site.yml` で一発デプロイ
- **Terraform**: Proxmox provider で LXC 作成も IaC 化
- **CI/CD**: push → 自動 test → 自動 deploy

## 9. 業務観点の重要ポイント（再掲）

1. **コミットの粒度を小さく**: 1 commit = 1 つの論理変更
2. **commit message は「何」より「なぜ」**: コードからは読めない情報を残す
3. **機微情報は絶対に commit しない**: pushed history は実質消せない
4. **タグで節目を残す**: 「v1.0 動作確認済み」「2026-Q2 安定稼働開始」
5. **README は最初に整える**: 自分が 3 ヶ月後に読んだ時に思い出せる粒度
