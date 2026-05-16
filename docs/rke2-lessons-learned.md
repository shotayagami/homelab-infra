# RKE2 / Kubernetes 運用 Lessons Learned

PVE 上 RKE2 クラスタ ([docs/rke2-cluster.md](rke2-cluster.md)) の構築・運用で踏んだハマりポイントの集合。一度踏んでから「次の人 (または将来の自分) に同じ穴を踏ませない」ための備忘。

2026-02〜03 期の構築フェーズ (PVE host /root/.claude memory) で蓄積した内容を 2026-05-16 に救出・整理。

> ほとんどが普遍的な内容で、Bitnami chart や ArgoCD、cert-manager 等を使う**別環境にも転用可能**。

---

## 1. DNS / ネットワーク

### 1-1. K8s ノードの DNS が壊れる (systemd-resolved 既定)

Ubuntu 22.04 ベースのノードは systemd-resolved がデフォルトで `127.0.0.53` を見るので、内部 FQDN (`*.home.yagamin.net`) が引けない。

**対処:**
```bash
# 各 K8s ノードで
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/dns.conf <<'EOF'
[Resolve]
DNS=192.168.11.53 192.168.11.54
Domains=~home.yagamin.net
EOF
sudo systemctl restart systemd-resolved
```

### 1-2. CoreDNS で内部 FQDN が引けない

systemd-resolved を直しても、Pod 内からの DNS は CoreDNS に行く。CoreDNS の forward は外向きデフォルトなので `home.yagamin.net` を Technitium に投げない。

**対処:** CoreDNS ConfigMap (`kube-system/rke2-coredns-rke2-coredns`) の Corefile に以下を追加:

```
home.yagamin.net:53 {
    forward . 192.168.11.53 192.168.11.54
    cache 30
}
home.local:53 {
    forward . 192.168.11.53
}
```

### 1-3. cert-manager DNS-01 伝播チェックが永久ループする

Technitium の SOA の `MNAME` が `dns.yagamin.com` (解決不能ドメイン) を指していたため、cert-manager が SOA から得た authoritative NS を引けず、伝播確認が timeout を繰り返す。

**対処:** cert-manager Deployment に以下の args を追加:

```yaml
- --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53
- --dns01-recursive-nameservers-only
```

### 1-4. Cloudflare Universal SSL は 1 階層しかカバーしない

`yagamin.net` の Universal SSL は `*.yagamin.net` のみ対象。`*.home.yagamin.net` (2 階層目) はカバーされず、CF 経由で外部公開すると SSL エラー。

**対処:** 外部公開する FQDN は **1 階層に揃える** (例: `ics.yagamin.net`、`grafana.yagamin.net`)。内部 FQDN は `*.home.yagamin.net` のままで、step-ca 発行で対応。

### 1-5. Cloudflare Tunnel の `httpHostHeader` を使ってはいけないアプリ

外部 FQDN (`grafana.yagamin.net`) を内部 FQDN (`grafana.home.yagamin.net`) に書き換える `httpHostHeader` リライトは、**cookie ベース認証アプリで session が壊れる**。

| アプリ | 症状 | 解決策 |
|---|---|---|
| Grafana | login 後の全ダッシュボードが "No data"、cookie ドメイン不一致 | Ingress に External host を追加、httpHostHeader リライトなし |
| WordPress | `$_SERVER['HTTP_HOST']` ベースで WP_HOME / WP_SITEURL が動的生成、外部 URL に化ける | 同上 |

ステートレス API (cert-manager, Harbor) はリライトしても OK。

---

## 2. Image / Registry

### 2-1. Harbor imagePullSecrets の付け忘れ

新規 Deployment 作成時、`imagePullSecrets` を書き忘れて ImagePullBackOff になる定番ミス。

**対処パターン:**
1. アプリ namespace に Harbor 用 secret を一度だけ作っておく:
   ```bash
   kubectl create secret docker-registry harbor-creds \
     --docker-server=harbor.home.yagamin.net \
     --docker-username=admin --docker-password='***' \
     -n ics
   ```
2. **新規 Deployment 作成時は既存 Deployment の `imagePullSecrets` を必ずコピー**する習慣にする
3. Kyverno で `imagePullSecrets` 必須化ポリシーを書く (将来検討)

---

## 3. Storage

### 3-1. Longhorn RWX に `nfs-common` が必要

Longhorn の RWX (ReadWriteMany) は NFS provisioner で実装される。各 K8s ノードに `nfs-common` がないと PVC が Pending のまま固まる。

**対処:** 全ノードで一度だけ:
```bash
sudo apt-get install -y nfs-common
```

### 3-2. Longhorn `default-replica-count=1` のリスク

[docs/rke2-cluster.md](rke2-cluster.md) §4 Phase 1 で 3→1 に削減済。worker1 の disk 故障 = データロスト。

**緩和策:**
- **重要 PVC (Harbor registry / Gitea repos / DB) は個別に numberOfReplicas を引き上げる** (Longhorn UI で per-volume 設定可能)
- 全 PVC を Velero/MinIO で定期バックアップ (詳細: [docs/backup-strategy.md](backup-strategy.md))

---

## 4. Django / Python アプリ

### 4-1. K8s liveness/readiness probe が 400 を返す

kube-probe は Host ヘッダに **Pod IP** を入れて来る。Django の `ALLOWED_HOSTS` に Pod CIDR が入っていないと 400 で probe 失敗 → CrashLoopBackOff。

**対処 (どちらか):**
```python
# settings.py
ALLOWED_HOSTS = ['*']  # 検証環境なら OK
# または
ALLOWED_HOSTS = ['app.example.com', '10.42.0.0/16']  # Pod CIDR を含める
```

### 4-2. SSL_REDIRECT で無限リダイレクトループ

Ingress 終端で TLS して Django に HTTP で渡しているのに、Django で `SECURE_SSL_REDIRECT=True` だと「HTTPSじゃない」と判定して HTTPS にリダイレクト → Ingress → HTTP → 永遠ループ。

**対処:**
```python
SECURE_SSL_REDIRECT = False
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')  # 必要なら
```

### 4-3. カスタム User モデルで migrations が壊れる

`AUTH_USER_MODEL = 'accounts.CustomUser'` を後付けで設定すると、初回 `makemigrations` で挿入順がずれて壊れる。

**対処:** **migrations ディレクトリと `__init__.py` を先に作ってから** `makemigrations` する。

### 4-4. `is_authenticated` 属性が存在しないカスタム User

独自実装の AdminUser モデル等で `request.user.is_authenticated` を直接呼ぶと AttributeError。

**対処:**
```python
if getattr(request.user, 'is_authenticated', False):
    ...
```

### 4-5. django-prometheus の `/metrics` が二重パスになる

`django_prometheus.urls` の sub-path は `metrics`。

```python
# ✗ /metrics/metrics になる
path('metrics/', include('django_prometheus.urls'))

# ✓ /metrics に配置
path('', include('django_prometheus.urls'))
```

---

## 5. PgBouncer / PostgreSQL

### 5-1. PG 17 と SCRAM 認証

PG 17 はデフォルトで scram-sha-256。PgBouncer ConfigMap で `AUTH_TYPE` を指定しないと md5 として認証を試みて黙って失敗する。

**対処:**
```yaml
data:
  AUTH_TYPE: "scram-sha-256"
```

### 5-2. LXC PostgreSQL の 3 層 access control

[docs/pg-db-postgresql.md](pg-db-postgresql.md) と同型:

1. `listen_addresses` を LXC IP のみに絞る
2. `pg_hba.conf` で K8s ノード IP を明示許可
3. **CT 内 ufw でもポート許可**を同期させる (pg_hba だけだと CT のネットワークが手前で deny する)

---

## 6. ArgoCD

### 6-1. Secret を kubectl で編集してもすぐ巻き戻る

ArgoCD auto-sync が K8s Secret を Git 定義で上書きする。

**対処:** **Secret 変更は必ず Git push 経由** (SealedSecret 含む)。緊急時は ArgoCD UI で auto-sync を一時 disable してから kubectl edit。

### 6-2. Application の repoURL を変えても古いまま参照される

Application status の `history` と `operationState` に旧 URL が残る。

**対処:**
```bash
# 1. Application を replace (新 manifest で)
kubectl replace -f application.yaml

# 2. ArgoCD Redis cache を flush
kubectl exec -n argocd argocd-redis-0 -- redis-cli FLUSHALL
```

---

## 7. Bitnami WordPress (および類似 Helm chart)

### 7-1. DB_PASSWORD は wp-config.php に焼き付く

Bitnami WordPress chart は初回起動時に Secret 値を `wp-config.php` にハードコードし PVC に永続化する。**Secret を更新しても反映されない。**

**PW 変更手順 (順番厳守):**

1. MariaDB 側:
   ```sql
   ALTER USER 'wordpress'@'%' IDENTIFIED BY 'new-password';
   FLUSH PRIVILEGES;
   ```

2. WordPress Pod を停止:
   ```bash
   kubectl scale -n wordpress deploy my-wordpress --replicas=0
   ```

3. 一時 Pod で PVC を mount、`wp-config.php` 内 `DB_PASSWORD` を直接書き換え

4. Pod 起動:
   ```bash
   kubectl scale -n wordpress deploy my-wordpress --replicas=1
   ```

5. WP-CLI で admin PW 変更:
   ```bash
   kubectl exec -n wordpress deploy/my-wordpress -- \
     wp user update admin --user_pass='new-admin-pw' --allow-root
   ```

### 7-2. Bitnami イメージの uid が 1001

Bitnami MariaDB / WordPress は uid=1001 で実行。**ノード OS 由来 PVC で書き込み権限がない場合あり**。バックアップ用には公式 `mariadb:latest` (uid=999) を使う。

---

## 8. Grafana

[Grafana 外部公開](#1-5-cloudflare-tunnel-の-httphostheader-を使ってはいけないアプリ) は §1-5 参照。

---

## 9. Sealed Secrets

### 9-1. 既存 Secret の取り込みは「先に delete」

既存 Secret が SealedSecret 管理外で存在する場合、SealedSecret を apply しても owner reference の不一致で reconciliation がループする。

**対処:**
```bash
kubectl delete secret -n app my-secret
kubectl apply -f sealed-secret.yaml
```

---

## 10. step-ca

### 10-1. ACME http-01 はプライベート IP で詰まる

internal な IP (192.168.11.x) 向け証明書を ACME http-01 で取ろうとすると、step-ca が challenge URL に到達できないケースがある。

**対処:** **JWK プロビジョナ (`admin`) で直接発行**:
```bash
step ca certificate \
  192.168.11.60 \
  /etc/ssl/step/cert.pem /etc/ssl/step/key.pem \
  --san 192.168.11.60 --san pg-db.home.yagamin.net \
  --provisioner admin
```

[docs/internal-tls.md](internal-tls.md) の同型展開パターンを参照。

### 10-2. step CLI が DNS で詰まる (LXC からの利用)

LXC の nameserver が外部 DNS (8.8.8.8 等) だと `step-ca.home.yagamin.net` が解決できない。

**対処:** `--ca-url https://192.168.11.61` で IP 直指定。

### 10-3. SAN 漏れで TLS 検証失敗

`step ca certificate` の positional 引数 (subject CN) は **SAN に自動追加されない**。`curl` 等は RFC 6125 で SAN 必須なので「no alternative certificate subject name matches」で TLS 検証失敗。

**対処:** subject (CN) も常に `--san` で明示:
```bash
step ca certificate pg-db.home.yagamin.net cert.pem key.pem \
  --san pg-db.home.yagamin.net --san 192.168.11.60
```

---

## 11. Gitea Actions / CI

### 11-1. Repo-level runner 登録が必要

Instance-level トークンで Act Runner を登録すると repo に認識されないことがある。

**対処:** **repo 固有のトークン**で登録 (Repo Settings → Actions → Runners)。

### 11-2. Helm 初回デプロイ後ログインできない

Gitea Helm chart は初回起動後 `must-change-password` フラグを ON にする。Web UI からログインしようとすると永久に PW 変更画面に飛ぶ。

**対処:**
```bash
kubectl exec -n gitea gitea-0 -- \
  gitea admin user must-change-password --all --unset
```

### 11-3. Act Runner コンテナ内から内部 FQDN が引けない

Runner コンテナの DNS は host 側 systemd-resolved を見るので、`gitea.home.yagamin.net` が引けない。

**対処:** runner 設定 (`config.yaml`) に:
```yaml
container:
  options: "--add-host=gitea.home.yagamin.net:192.168.11.80"
```

### 11-4. Git push で SSL 検証スキップは不要

`gitea.home.yagamin.net` は Let's Encrypt 証明書なので `GIT_SSL_NO_VERIFY` 系の workaround は使わない。普通に credential helper だけ:
```bash
git config --global credential.helper 'store --file=/tmp/.git-credentials'
```

---

## 12. Prometheus / ServiceMonitor

### 12-1. ServiceMonitor に `release` ラベル必須

kube-prometheus-stack の Prometheus CR は `serviceMonitorSelector: matchLabels: release: prometheus-stack` を要求する。

**対処:** カスタム ServiceMonitor / PrometheusRule には必ず:
```yaml
metadata:
  labels:
    release: prometheus-stack
```

---

## 13. Trivy Operator

### 13-1. `scanJobsConcurrentLimit` は worker の vCPU 数より小さく

`operator.scanJobsConcurrentLimit` (env `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT`、chart デフォルト `10`) は **同時走行するスキャン Job 数の上限**。各 Job は `trivy.resources.limits.cpu: 1000m` で、`trivy.mode: Standalone`(chart デフォルト)では初回 DB ダウンロード + イメージスキャン中に実際に 1 CPU を使い切る。

3 vCPU の `k8s-worker1` 上で `scanJobsConcurrentLimit: 4` のまま運用したところ、トリガ条件(例: 多数の workload を同時 enroll、イメージタグ多数更新)で load average が 13 を超え、Zabbix `Linux: Load average is too high (per CPU load over 1.5 for 5m)` が発火 (2026-05-17 観測)。

**対処:** worker の vCPU 数より小さい値にする。3 vCPU なら `2`。

即時(deployment env 直接更新、`helm upgrade` まで保持):
```bash
kubectl -n trivy-system set env deploy/trivy-operator \
  OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT=2 OPERATOR_SCAN_JOB_RETRY_AFTER=60s
```

恒久(`helm upgrade` 用 values.yaml):
```yaml
operator:
  scanJobsConcurrentLimit: 2
  scanJobRetryAfter: 60s
trivy:
  resources:
    limits:
      cpu: 1000m
      memory: 1536Mi
    requests:
      cpu: 100m
      memory: 256Mi
```

**根本的改善 (未実施 / 次の打ち手):**
- worker ノードの vCPU 増設(`k8s-worker1` 3 → 4 以上)
- `trivy.mode: ClientServer` 化で中央 Trivy server による DB 共有(各 Job の重複 DL 排除)
- スキャン Job 用 `tolerations` を入れ、cp1 にも分散

---

## 14. npm / フロントエンド

### 14-1. `npm ci` には `package-lock.json` が必要

新規プロジェクトでいきなり `npm ci` するとコケる。

**対処:** 初回は `npm install` で lock を生成、以降の CI/CD は `npm ci` で再現性確保。

---

## 15. ExternalName Service (K8s 外 DB へのルーティング)

K8s クラスタ外の DB (LXC PostgreSQL 等) への接続は、ExternalName Service で透過化できる:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pg-db
  namespace: ics
spec:
  type: ExternalName
  externalName: pg-db.home.yagamin.net
```

これで Pod からは `pg-db.ics.svc.cluster.local` で接続可能。

**前提:** CoreDNS の forward 設定 ([§1-2](#1-2-coredns-で内部-fqdn-が引けない)) が入っていること。

---

## 16. 関連ドキュメント

- [docs/rke2-cluster.md](rke2-cluster.md) — クラスタ全体構成、Phase 0/1/2 最適化、etcd 再配置
- [docs/pg-db-postgresql.md](pg-db-postgresql.md) — pg-db (LXC 106) と RKE2 アプリの接続
- [docs/internal-dns.md](internal-dns.md) — Technitium DNS
- [docs/internal-tls.md](internal-tls.md) — step-ca + 自動更新パターン
- [docs/backup-strategy.md](backup-strategy.md) — 多層バックアップ
- [docs/proxmox-host-self-healing.md](proxmox-host-self-healing.md) — PVE host の自律復旧層
