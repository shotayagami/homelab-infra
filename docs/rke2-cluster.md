# RKE2 クラスタの中身 (VMID 110 / 120)

PVE 上に立てた RKE2 (Rancher Kubernetes Engine 2) クラスタの **workload カタログと最適化履歴**。`hardware.md` が物理層、本書がワークロード層、`proxmox-zabbix-monitoring.md` §2026-05-16 が監視 / etcd fsync 詳細を担当する。

## 1. クラスタ概要

| 項目 | 内容 |
|---|---|
| ディストリ | RKE2 v1.34.3-rke2r3 (Rancher 公式、軽量 K8s) |
| ノード | `k8s-cp1` (VMID 110, 192.168.11.80) / `k8s-worker1` (VMID 120, 192.168.11.83) の 2 台 |
| OS | Ubuntu 22.04 (cloud-init で `ubuntu` ユーザー、PVE root SSH 鍵で入る) |
| kubectl | `/var/lib/rancher/rke2/bin/kubectl` |
| kubeconfig | `/etc/rancher/rke2/rke2.yaml` (mode 0644) |
| CNI | Cilium (デフォルト、pod CIDR 10.42.0.0/16) |
| 稼働期間 | 97 日 (2026-05-16 時点) |

### 設計意図と実態のギャップ

`/etc/rancher/rke2/config.yaml` は **3 control-plane HA 構成** (cp1/cp2/cp3 + VIP 192.168.11.88) を想定した設定が入っているが、**実体は cp1 単独 + worker1 の 1+1 構成**。VIP も実体なし。リソース都合で HA 化は未着手。

## 2. SSH アクセス

PVE ホスト経由の jump で入る:

```bash
ssh -J root@192.168.11.11 ubuntu@192.168.11.80    # cp1
ssh -J root@192.168.11.11 ubuntu@192.168.11.83    # worker1
```

admin-vm から `~/.ssh/config` に `ProxyJump root@192.168.11.11` を書いておくと楽。

## 3. 載っている workload（~110 pods、23 Helm release）

### GitOps / CI

| コンポーネント | 用途 | PVC |
|---|---|---|
| ArgoCD | クラスタ自身のマニフェスト管理 | — |
| Gitea | 自前 Git ホスティング | 34 GiB (本体 + 旧 Valkey 残骸) |
| Harbor | コンテナレジストリ | 20 GiB (registry) |

### 監視 / ロギング

| コンポーネント | 用途 | PVC |
|---|---|---|
| Prometheus (kube-prometheus-stack) | メトリクス、retention 7d | 含む |
| Grafana | ダッシュボード | 含む |
| Loki | ログ集約、SingleBinary mode | 含む |
| Promtail | ログ収集 agent | — |
| (合計 PVC) | | **25 GiB** |

### データベース

| コンポーネント | 用途 |
|---|---|
| MariaDB | アプリ用 |
| PostgreSQL | アプリ用 |
| Redis | キャッシュ / queue (standalone、後述 Phase 1 で replicas 削除) |
| MongoDB | アプリ用 |

### バックアップ / DR

| コンポーネント | 用途 | PVC |
|---|---|---|
| Velero | クラスタバックアップ | — |
| MinIO | Velero の S3 互換ストレージ | 20 GiB |

### セキュリティ

| コンポーネント | 用途 |
|---|---|
| Kyverno | ポリシーエンジン |
| Trivy | 脆弱性スキャナ |
| cert-manager | TLS 自動更新 (Let's Encrypt) |
| sealed-secrets | GitOps 用の暗号化 Secret |

### ネットワーク

| コンポーネント | 用途 |
|---|---|
| Cilium | CNI (デフォルト RKE2 配布) |
| MetalLB | LoadBalancer IP プール |
| Cloudflare Tunnel | 外部公開 (cloudflared DaemonSet) |

### ストレージ

| コンポーネント | 用途 |
|---|---|
| Longhorn 1.7.2 | 分散ブロックストレージ |
| | 21 PVC、ディスク実体 18 GB、`/var/lib/longhorn/replicas` 配下 |
| | replica count = 1 (Phase 1 で 3→1 に削減、後述) |

### アプリ namespace

| Namespace | 内容 | 状態 |
|---|---|---|
| `ics` | admin-portal / backend / frontend / celery 系 8 pods | **scale 0 で休眠中** (Phase 2)、`backend-media-pvc` 5 GiB は保持 |
| `wordpress` | WordPress 一式 | scale 0 で休眠中 |
| `app` | db-test-app など | scale 0 で休眠中 |
| `gitea` | Gitea + 旧 Valkey 残骸 | 稼働中、Valkey サブチャートは Phase 1 で無効化 |

## 4. 2026-05-15〜16 の最適化作業 (Phase 0/1/2)

**発端**: PVE ホストの memory が peak 92.9% / load average 12.46 まで跳ね、Zabbix agent や PVE API も落ちる事態に。

### Phase 0: VM スペック圧縮

| VM | 移行前 | 移行後 |
|---|---|---|
| cp1 (110) | 4 cores / 10 GiB | 4 cores / **9 GiB** |
| worker1 (120) | 5 cores / 10 GiB | **3 cores / 7 GiB** |
| **合計** | 9c / 20 GiB | **7c / 16 GiB** |

**結果**: PVE 6 物理 core に対する CPU overcommit 50% → 17%、host memory peak 92.9% → 78.6%。

### Phase 1: DB レプリカ削減

- **Redis**: `architecture=replication` (master + 2 replicas) → `architecture=standalone` (master のみ)
- **Gitea の Valkey サブチャート無効化**: Gitea 本体は memory cache + level queue + sqlite で完結しているので Valkey 不要
- **Longhorn `default-replica-count: 3 → 1`** + 既存 21 ボリュームを `numberOfReplicas:1` に patch

### Phase 2: retention 削減 + 非クリティカル workload を scale 0

- Prometheus `retention=7d` (default 10d)
- Loki は既に SingleBinary + replicas=1 + cache 全 disable で最適化済みなので非対象
- WordPress / app / db-test-app / ics 全 deployments を `kubectl scale --replicas=0` (定義は保留、`kubectl scale --replicas=N` で即時再開可)

### 副作用整理

- 孤立 PVC 5 個 (redis-replicas × 2 + valkey-cluster × 3、合計 40 GiB) を `kubectl delete pvc` で掃除
- Phase 0 の VM 再起動後に発生した Unknown ghost pods を `kubectl delete --force --grace-period=0` で除去
- cloudflared と Longhorn CSI 系の transient CrashLoop は自然回復

## 5. 2026-05-16 etcd fsync 由来の disk 再配置

別途、cp1 で **etcd slow fdatasync** によるリーダー選出系 Pod の CrashLoop バーストが観測され、同日中に disk を移行:

- cp1 (etcd ホスト): `store-sdb` (Fanxiang QLC) → `local-lvm` (Samsung 970 EVO Plus NVMe)
- worker1 (Longhorn replica ホスト): `store-sdb` (Fanxiang QLC) → `store-sda` (SPCC TLC SATA)
- `store-sdb` は **バックアップ専用**に

詳細: [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) §「2026-05-16: cp1 etcd slow fdatasync 解消」、ハード根拠: [docs/hardware.md](hardware.md) §「Storage tier の決定経緯」。

## 6. 「クラスタを消したい」依頼が来たときの確認フロー

このクラスタは「検証環境」と言いつつ、Gitea のリポジトリ / Harbor のイメージ / Grafana ダッシュボード / MinIO 内の Velero バックアップなど **捨てると痛い資産** を抱えている。撤去前のチェック:

1. **Gitea のリポジトリ一覧** を export (`gitea dump` or リポジトリ単位の `git clone --mirror`)
2. **Harbor のイメージ一覧** を確認、必要なものを別レジストリ (Docker Hub 等) に push
3. **MinIO 内の Velero バックアップ** が他の場所に複製されているか確認
4. **scale 0 で休眠中のアプリ** (ics / wordpress / app) の deployment 定義を export
5. `kubectl get pvc -A` で PVC 一覧を取り、Longhorn snapshot を退避

`qm destroy 110 120` は **これら全て確認後の最終手段**。

## 7. KubeCPUOvercommit アラートを意図的にサイレンス (2026-05-16〜)

`KubeCPUOvercommit` (Prometheus / kube-prometheus-stack 同梱) は 2-node + 単一 CP のホームラボ構成では**構造的に常時発火する**ため、Alertmanager で長期サイレンスを設定済み (期限 2027-05-16)。

### なぜ常時発火するのか

ルールの **HA branch** は控除元から `max(node allocatable)` を差し引いて評価する:

```
sum(requests) > sum(allocatable) - max(allocatable per node)
```

本クラスタの実数 (2026-05-16 時点):

| | CPU allocatable | CPU requests |
|---|---|---|
| cp1 | 4 (= max) | 3030m (75%) |
| worker1 | 3 | 1660m (55%) |
| **合計** | **7** | **4690m** |

→ `4690 > 7000 - 4000 = 3000` で常時 True。

しかも cp1 は**唯一の control-plane**なので、cp1 障害時はクラスタ全停止であり、このルールが想定する「他ノードで pod を救う」シナリオ自体が成立しない。実 CPU 使用率は cp1 40% / worker1 14% で実害もない。

### 操作ログ

```bash
# サイレンス作成 (1 年)
ssh -J root@192.168.11.11 ubuntu@192.168.11.80 \
  "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
   -n monitoring exec alertmanager-prometheus-stack-kube-prom-alertmanager-0 \
   -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 \
   silence add alertname=KubeCPUOvercommit --duration=8760h \
   --comment='2-node single-CP homelab structural noise'"
```

silence ID は `amtool ... silence query` で確認できる。

### サイレンス解除の条件

以下のいずれかが満たされたら **必ず見直すこと**:

1. **worker2 (3 ノード目) を追加した場合** — failover 余地が出るため、本来の意図に沿った alert として機能し始める
2. **Helm values で `defaultRules.disabled.KubeCPUOvercommit: true` に切り替えた場合** — silence は不要になる
3. **2027-05-16 にサイレンス期限切れ** — 再評価して再延長か恒久対応か判断

### worker2 追加の現状フィージビリティ (2026-05-16 時点)

「本格対応 = worker2 追加」のリソース感:

| リソース | 現状 | worker2 (2c / 6 GiB 想定) 追加可否 |
|---|---|---|
| Physical CPU | 6 cores / vCPU 割当合計 24 (VM 11 + LXC 13) / load 2.0 | 追加 OK (vCPU は overcommit 前提) |
| Physical RAM | 32 GiB / 実 used 25 GiB / available **6.1 GiB** / swap **760 MB 既使用** | **不可** — swap thrashing リスク高 |
| Storage (local-lvm) | 658 GiB free | 余裕 |
| Network | 1 GbE 1 本 | Longhorn replica 同期で帯域逼迫の懸念 |

→ **メモリが瓶頸**。先に [docs/hardware.md](hardware.md) §「将来の拡張余地」記載の **64 GB DIMM 換装** をやらないと worker2 は危険。手順:

1. 16 GB DDR4-2666 (non-ECC) DIMM × 4 を調達 (~1 万円台)
2. PVE をシャットダウンして全 DIMM 入れ替え (DIMM1〜4 全埋め)
3. ブート確認後、worker2 用 VMID 130 を作成 (cp1 のクローンから RKE2 worker として再 join)

## 8. 「クラスタが再び重くなった」場合の最初の確認

Phase 0/1/2 の効果は **長期維持されない** 可能性がある (Helm chart upgrade や ArgoCD の sync で元に戻り得る)。

1. `kubectl get deploy -A | grep -v "0/0"` で休眠していたはずの workload が再起動していないか
2. `helm list -A` で Redis / Valkey の architecture が `replication` に戻っていないか
3. `kubectl get pvc -A -l app.kubernetes.io/name=longhorn` の `numberOfReplicas` が 1 のままか
4. PVE ホスト側で `free -h` と `uptime` の load average を確認

## 関連

- [docs/hardware.md](hardware.md) — PVE 物理層 + storage tier 決定経緯
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) §「2026-05-16 Phase 4-D RKE2 クラスタ監視」+ §「cp1 etcd slow fdatasync 解消」— RKE2 監視構成と etcd 安定化作業
- [docs/admin-vm-tooling.md](admin-vm-tooling.md) — admin-vm から VM を操作する仕組み
