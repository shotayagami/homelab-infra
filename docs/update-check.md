# アップデート検知 (update-check)

RKE2 クラスタと周辺 CLI ツールのバージョン更新を毎日自動でチェックし、更新があれば ntfy で通知する仕組み。**検知のみ行い、自動適用はしない**（適用コマンドを通知・レポートに添えるだけ）。

外部クラスタ向けに切り出された汎用パッケージ（ics-update-checker）を、このクラスタの実際の構成（`helm list -A` の内容、ArgoCD/cert-manager の管理方式）に合わせて移植したもの。

## 1. 全体構成

```
                ┌──────────────────────────────┐
  systemd --user│ update-check.timer            │  毎日 07:00 に発火 (admin-vm)
  timer         └──────────────┬───────────────┘
                               ▼
                ┌──────────────────────────────┐
  systemd --user│ update-check.service           │  oneshot
  service       └──────────────┬───────────────┘
                               ▼
                ┌──────────────────────────────┐
  本体スクリプト│ update-check.sh check          │
                │  ├─ A. Helm チャート           │  helm search repo で最新版と比較
                │  ├─ B. kubectl 管理アプリ       │  稼働 image tag と GitHub Releases を比較
                │  ├─ C. RKE2                    │  kubectl 経由でノードバージョン取得 → update.rke2.io と比較
                │  ├─ D. CLI ツール              │  各バイナリ --version と GitHub Releases を比較
                │  └─ E. OS 更新 (admin-vm のみ) │  apt の更新可能数・セキュリティ数
                └──────────────┬───────────────┘
                               ▼ 更新が1件以上あれば
                        ntfy (http://192.168.11.56/update-check)
```

- 実行ホストは **admin-vm**（root 不要。kubectl/helm は `~/bin` から RKE2 API (`192.168.11.80:6443`) を直接叩く。OS 更新チェックのみ `sudo apt-get` を使うが admin-vm は passwordless sudo 設定済）。
- systemd は **user unit** (`systemctl --user`) で運用し、ユニットファイルに個人ユーザー名を書かない（`%h` 指定）。ログイン無しでも動くよう `loginctl enable-linger` が必要。
- 通知は ntfy のみ。Discord / Mailgun は Zabbix 用に既に使っていて、資格情報の使い回しでローテーション対象が増えるのを避けるため採用しなかった（[proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) 参照）。

## 2. チェック対象カテゴリ（このクラスタの実態）

| カテゴリ | 対象 | 最新版の取得元 |
|---|---|---|
| **A. Helm チャート**（直管理） | gitea, harbor, mariadb, postgresql, redis, prometheus-stack, longhorn, velero, kyverno, loki, promtail, metallb, trivy-operator, postgres-exporter, my-wordpress | `helm search repo`（要 `helm repo add`） |
| **B. kubectl 管理アプリ** | ArgoCD, cert-manager, sealed-secrets | 稼働 Pod の image tag ⇔ GitHub Releases API |
| **C. RKE2** | rke2-server（ノード kubelet バージョンから間接取得） | `https://update.rke2.io/v1-release/channels` |
| **D. CLI ツール** | helm, kubeseal, cloudflared（admin-vm 上のもの） | GitHub Releases API |
| **E. OS 更新** | admin-vm 自身（Ubuntu 24.04） | `apt` |

このクラスタでは `helm list -A` の 23 リリースのうち、RKE2 バンドルのアドオン（`rke2-cilium` / `rke2-coredns` / `rke2-ingress-nginx` / `rke2-metrics-server` / `rke2-runtimeclasses` / `rke2-snapshot-controller*`）は RKE2 本体のアップグレードに追従するため C. RKE2 側で間接的にカバーし、個別監視はしていない。

`ArgoCD` / `cert-manager` はいずれも `kubectl apply` による raw manifest 管理（Helm リリースなし）と確認済み。`sealed-secrets` は Helm リリースとして存在するが、upstream の chart repo (`bitnami-labs.github.io/sealed-secrets`) が OCI レジストリへ移行済で `helm search repo` できないため、他の kubectl 管理アプリと同様に稼働イメージタグでの比較に倒している。

なお `bitnami-labs/sealed-secrets` は GitHub 上で組織移管されており、素の `curl -s` は 301 を返す（フォロー無しだと "up to date" に誤判定される既知の落とし穴）。本スクリプトは `curl -sL` でリダイレクトを追う。

## 3. 対象外（既知の制約）

- **cp1 / worker1 の OS パッチ状況**: admin-vm から両ノードへの root SSH が通っておらず（未設定/host key 不一致）、チェック対象は admin-vm 自身のみ。両ノードの OS 更新状況を見たい場合は Zabbix 側での監視を検討する。
- **act_runner**: `gitea-runner` LXC (103) 上で稼働しており、admin-vm 上のバイナリではないため CLI ツールカテゴリの対象外。

## 4. 設定ファイル

`$HOME/.config/update-check/update-check.conf`（`UPDATE_CHECK_CONFIG` で変更可、`chmod 600` 必須、リポジトリにはコミットしない）。テンプレートは [scripts/admin-vm/update-check.conf.example](../scripts/admin-vm/update-check.conf.example)。

ntfy の認証情報は Zabbix と同じ「用途ごとに専用ユーザー+write-only トピック」パターンで発行する（ntfy LXC 191、`pve-wrapper` 経由）:

```bash
PVE_HOST=root@192.168.11.12 pct exec 191 -- ntfy user add update-check
PVE_HOST=root@192.168.11.12 pct exec 191 -- ntfy access update-check update-check write-only
PVE_HOST=root@192.168.11.12 pct exec 191 -- ntfy token add update-check
```

内部通信は Zabbix の ntfy media type と同様、`https://ntfy.home.yagamin.net` ではなく `http://192.168.11.56` を使う（HTTPS は step-ca 内部 CA 署名のため、admin-vm がルート証明書を信頼していないと `curl` の証明書検証に失敗する）。

## 5. 導入手順（admin-vm）

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/update-check
install -m 0755 scripts/admin-vm/update-check.sh ~/.local/bin/update-check.sh
install -m 0644 scripts/systemd-units/update-check.service ~/.config/systemd/user/
install -m 0644 scripts/systemd-units/update-check.timer   ~/.config/systemd/user/

cp scripts/admin-vm/update-check.conf.example ~/.config/update-check/update-check.conf
chmod 700 ~/.config/update-check
chmod 600 ~/.config/update-check/update-check.conf
vi ~/.config/update-check/update-check.conf   # NTFY_TOKEN 等を設定

# --user unit はログインセッション終了で死ぬため linger を有効化
sudo loginctl enable-linger "$USER"

systemctl --user daemon-reload
systemctl --user enable --now update-check.timer

~/.local/bin/update-check.sh check    # 手動実行テスト（通知も飛ぶ）
```

## 6. 運用（手動実行・確認）

```bash
# 手動でチェック実行（通知も飛ぶ）
~/.local/bin/update-check.sh check

# 直近レポートを人間可読で表示（通知は飛ばさない）
~/.local/bin/update-check.sh report

# ログ確認
tail -n 50 ~/.local/state/update-check.log
journalctl --user -u update-check.service --no-pager | tail -n 50

# タイマーの次回発火時刻
systemctl --user list-timers update-check.timer
```

## 7. トラブルシューティング

| 症状 | 原因・対処 |
|---|---|
| 通知が来ない | 更新 0 件なら無通知が正常。`report` で内容確認。`NTFY_URL`/`NTFY_TOKEN` 未設定だと通知スキップ（ログに warning） |
| ntfy publish が失敗する | `https://ntfy.home.yagamin.net` を使っていないか確認（内部 CA 未信頼で証明書検証エラーになる）。`http://192.168.11.56/update-check` を使うこと |
| Helm が全部 "error" | 対象 repo が `helm repo add` 未登録、または `helm repo update` 失敗 |
| GitHub 系が "error (HTTP xxx)" / 常に "up to date" になる | GitHub API のレート制限、またはリポジトリ移管によるリダイレクト未追従（`curl -sL` になっているか確認） |
| timer が発火しない | `loginctl show-user $USER -p Linger` が `yes` か確認。`no` なら `--user` unit はログアウトで停止する |
