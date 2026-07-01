#!/usr/bin/env bash
# =============================================================
# Update Check & Notification (homelab RKE2 cluster)
# =============================================================
# admin-vm から実行し、RKE2 クラスタと周辺 CLI ツールのバージョン
# 更新を毎日自動チェックする。チェック対象: Helm チャート / kubectl
# apply 管理アプリ / RKE2 / CLI ツール / admin-vm 自身の OS パッケージ。
# 検知・通知のみを行い、自動適用はしない（適用コマンドを通知に添える）。
#
# 由来: ics-update-checker（別クラスタ向けに切り出された汎用版）を
# このクラスタの実際の構成 (helm list -A, kubectl 管理アプリ) に
# 合わせて移植したもの。
#
# 使い方: update-check.sh [check|report|help]
#
# 認証情報（ntfy トークン等）はこのスクリプトに書かず、設定ファイル
# （既定: $HOME/.config/update-check/update-check.conf）から読み込む。
# =============================================================
set -euo pipefail

CONFIG_FILE="${UPDATE_CHECK_CONFIG:-$HOME/.config/update-check/update-check.conf}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# admin-vm の ~/bin に kubectl/helm があり、kubeconfig は RKE2 API
# (192.168.11.80:6443) を直接指すので sudo/フルパス指定は不要。
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
export KUBECTL HELM

# ---- 通知先（設定ファイルで指定。未設定なら通知はスキップ）----
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
SYSTEM_LABEL="${SYSTEM_LABEL:-homelab (RKE2)}"

LOG_FILE="${LOG_FILE:-$HOME/.local/state/update-check.log}"
REPORT_FILE="${REPORT_FILE:-$HOME/.local/state/update-check-report.json}"
TMPDIR_UC="/tmp/update-check-$$"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$REPORT_FILE")"

_info()  { printf '\033[36m[update-check]\033[0m %s\n' "$*"; }
_ok()    { printf '\033[32m[update-check]\033[0m %s\n' "$*"; }
_warn()  { printf '\033[33m[update-check]\033[0m %s\n' "$*"; }
_error() { printf '\033[31m[update-check]\033[0m %s\n' "$*" >&2; }

_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

_cleanup() {
    rm -rf "$TMPDIR_UC"
}
trap _cleanup EXIT

# ---- Category A: Helm Charts (helm 直管理のリリースのみ) ----
# GitOps (ArgoCD Application) 配下のリリースはこのクラスタには無い
# （ArgoCD は kustomize manifest 運用で、Helm リリースは全て直管理）。

check_helm_charts() {
    _info "Checking Helm chart updates..."
    _log "START check_helm_charts"

    $HELM repo update > /dev/null 2>&1 || _warn "helm repo update failed (partial)"
    $HELM list -A -o json > "$TMPDIR_UC/helm-installed.json" 2>/dev/null

    python3 - "$TMPDIR_UC/helm-installed.json" "$TMPDIR_UC/helm-results.json" "$TMPDIR_UC" << 'PYEOF'
import json, subprocess, sys, os, re

installed_file = sys.argv[1]
output_file = sys.argv[2]
tmpdir = sys.argv[3]
helm_bin = os.environ.get("HELM", "helm")

with open(installed_file) as f:
    installed = json.load(f)

# helm list -A の NAME -> 実際に upstream で `helm search repo` できる repo/chart。
# sealed-secrets は upstream が OCI レジストリ移行済で `helm search repo` 不可のため
# Category B (GitHub Releases) 側でイメージタグ比較する。
chart_map = {
    "gitea": "gitea-charts/gitea",
    "harbor": "harbor/harbor",
    "mariadb": "bitnami/mariadb",
    "postgresql": "bitnami/postgresql",
    "redis": "bitnami/redis",
    "prometheus-stack": "prometheus-community/kube-prometheus-stack",
    "longhorn": "longhorn/longhorn",
    "velero": "vmware-tanzu/velero",
    "kyverno": "kyverno/kyverno",
    "loki": "grafana/loki",
    "promtail": "grafana/promtail",
    "metallb": "metallb/metallb",
    "trivy-operator": "aqua/trivy-operator",
    "postgres-exporter": "prometheus-community/prometheus-postgres-exporter",
    "my-wordpress": "bitnami/wordpress",
}

def normalize(v):
    return re.sub(r'^v', '', re.sub(r'[+-].*', '', v))

def version_gt(a, b):
    a_parts = [int(x) for x in normalize(a).split('.') if x.isdigit()]
    b_parts = [int(x) for x in normalize(b).split('.') if x.isdigit()]
    for i in range(max(len(a_parts), len(b_parts))):
        av = a_parts[i] if i < len(a_parts) else 0
        bv = b_parts[i] if i < len(b_parts) else 0
        if av > bv:
            return True
        if av < bv:
            return False
    return False

installed_map = {}
for rel in installed:
    name = rel.get("name", "")
    if name in chart_map:
        chart_str = rel.get("chart", "")
        match = re.search(r'-(v?\d+\..+)$', chart_str)
        ver = match.group(1) if match else chart_str
        installed_map[name] = {
            "namespace": rel.get("namespace", ""),
            "current": ver,
            "app_version": rel.get("app_version", ""),
        }

results = []

for name, repo_chart in chart_map.items():
    if name not in installed_map:
        continue

    info = installed_map[name]
    search_file = os.path.join(tmpdir, f"helm-search-{name}.json")

    try:
        proc = subprocess.run(
            [helm_bin, "search", "repo", repo_chart, "--versions", "-o", "json"],
            capture_output=True, text=True, timeout=30
        )
        with open(search_file, "w") as sf:
            sf.write(proc.stdout)

        with open(search_file) as sf:
            search_results = json.load(sf)

        if not search_results:
            continue

        latest = search_results[0].get("version", "")
        current = info["current"]
        has_update = version_gt(latest, current)

        ns_flag = f"-n {info['namespace']}" if info['namespace'] else ""
        apply_hint = f"helm upgrade {name} {repo_chart} --version {latest} {ns_flag} --reuse-values"

        results.append({
            "name": name,
            "repo_chart": repo_chart,
            "namespace": info["namespace"],
            "current": current,
            "latest": latest,
            "has_update": has_update,
            "apply_hint": apply_hint,
        })
    except Exception as e:
        results.append({
            "name": name,
            "repo_chart": repo_chart,
            "namespace": info.get("namespace", ""),
            "current": info.get("current", "?"),
            "latest": "error",
            "has_update": False,
            "apply_hint": f"# Error: {e}",
        })

with open(output_file, "w") as f:
    json.dump(results, f, indent=2)
PYEOF

    local count
    count=$(python3 -c "
import json
with open('$TMPDIR_UC/helm-results.json') as f:
    d = json.load(f)
print(sum(1 for x in d if x.get('has_update')))
")
    _log "END check_helm_charts (updates=$count)"
    _info "Helm charts: $count updates available"
}

# ---- Category B: kubectl apply / Helm-OCI 管理アプリ ----
# ArgoCD と cert-manager は raw manifest (kubectl apply) 管理。
# sealed-secrets は Helm リリースだが chart repo が OCI 移行済で
# `helm search repo` できないため、稼働イメージタグで判定する。

check_github_releases() {
    _info "Checking GitHub-managed app updates..."
    _log "START check_github_releases"

    python3 - "$TMPDIR_UC/github-results.json" "$TMPDIR_UC" << 'PYEOF'
import json, subprocess, sys, os, re

output_file = sys.argv[1]
tmpdir = sys.argv[2]
kubectl = os.environ.get("KUBECTL", "kubectl")

checks = [
    {"name": "ArgoCD", "repo": "argoproj/argo-cd", "kind": "deployment", "resource": "argocd-server", "namespace": "argocd"},
    {"name": "cert-manager", "repo": "cert-manager/cert-manager", "kind": "deployment", "resource": "cert-manager", "namespace": "cert-manager"},
    {"name": "sealed-secrets", "repo": "bitnami-labs/sealed-secrets", "kind": "deployment", "resource": "sealed-secrets", "namespace": "kube-system"},
]

apply_hints = {
    "ArgoCD": "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/{version}/manifests/install.yaml",
    "cert-manager": "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{version}/cert-manager.yaml",
    "sealed-secrets": "helm upgrade sealed-secrets oci://registry-1.docker.io/bitnamicharts/sealed-secrets --version <chart-version-for-{version}> -n kube-system --reuse-values  # chart/app version の対応は GitHub Releases で要確認",
}

def normalize(v):
    return re.sub(r'^v', '', re.sub(r'[+-].*', '', v))

results = []

for c in checks:
    try:
        cmd = f"{kubectl} get {c['kind']} {c['resource']} -n {c['namespace']} -o jsonpath='{{.spec.template.spec.containers[0].image}}'"
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        image = proc.stdout.strip().strip("'")
        current = image.split(":")[-1] if ":" in image else "unknown"

        api_url = f"https://api.github.com/repos/{c['repo']}/releases/latest"
        api_file = os.path.join(tmpdir, f"github-{c['name']}.json")
        proc = subprocess.run(
            ["curl", "-sL", "--connect-timeout", "10", "--max-time", "30", "-o", api_file, "-w", "%{http_code}", api_url],
            capture_output=True, text=True, timeout=35
        )
        http_code = proc.stdout.strip()

        if http_code != "200":
            results.append({"name": c["name"], "current": current, "latest": f"error (HTTP {http_code})", "has_update": False, "apply_hint": ""})
            continue

        with open(api_file) as f:
            release = json.load(f)
        latest = release.get("tag_name", "unknown")

        has_update = normalize(current) != normalize(latest)
        hint = apply_hints.get(c["name"], "").replace("{version}", latest)

        results.append({
            "name": c["name"],
            "current": current,
            "latest": latest,
            "has_update": has_update,
            "apply_hint": hint,
        })
    except Exception as e:
        results.append({"name": c["name"], "current": "?", "latest": f"error: {e}", "has_update": False, "apply_hint": ""})

with open(output_file, "w") as f:
    json.dump(results, f, indent=2)
PYEOF

    local count
    count=$(python3 -c "
import json
with open('$TMPDIR_UC/github-results.json') as f:
    d = json.load(f)
print(sum(1 for x in d if x.get('has_update')))
")
    _log "END check_github_releases (updates=$count)"
    _info "kubectl-managed apps: $count updates available"
}

# ---- Category C: RKE2 ----
# admin-vm に rke2 バイナリは無いため、kubectl 経由でノードの
# kubelet バージョン (vX.Y.Z+rke2rN) から現在バージョンを取得する。

check_rke2() {
    _info "Checking RKE2 updates..."
    _log "START check_rke2"

    $KUBECTL get nodes -o json > "$TMPDIR_UC/nodes.json" 2>/dev/null || echo '{"items":[]}' > "$TMPDIR_UC/nodes.json"

    curl -s --connect-timeout 10 --max-time 30 \
        "https://update.rke2.io/v1-release/channels" \
        -o "$TMPDIR_UC/rke2-channels.json" 2>/dev/null

    python3 - "$TMPDIR_UC/nodes.json" "$TMPDIR_UC/rke2-channels.json" "$TMPDIR_UC/rke2-result.json" << 'PYEOF'
import json, sys, re

nodes_file = sys.argv[1]
channels_file = sys.argv[2]
output_file = sys.argv[3]

def normalize(v):
    return re.sub(r'^v', '', re.sub(r'[+-].*', '', v))

try:
    with open(nodes_file) as f:
        nodes = json.load(f)
    versions = sorted({n["status"]["nodeInfo"]["kubeletVersion"] for n in nodes.get("items", [])})
    current = versions[0] if versions else "unknown"
    skew = len(versions) > 1

    with open(channels_file) as f:
        data = json.load(f)

    latest_stable = ""
    for ch in data.get("data", []):
        if ch.get("id") == "stable":
            latest_stable = ch.get("latest", "")
            break

    has_update = normalize(current) != normalize(latest_stable) and latest_stable != ""

    result = {
        "current": current,
        "node_versions": versions,
        "version_skew": skew,
        "latest_stable": latest_stable,
        "has_update": has_update,
        "apply_hint": "curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=stable sh - && systemctl restart rke2-server  # cp1 → worker1 の順に1台ずつ",
    }
except Exception as e:
    result = {"current": "unknown", "latest_stable": f"error: {e}", "has_update": False, "apply_hint": ""}

with open(output_file, "w") as f:
    json.dump(result, f, indent=2)
PYEOF

    local has_update
    has_update=$(python3 -c "
import json
with open('$TMPDIR_UC/rke2-result.json') as f:
    d = json.load(f)
print('yes' if d.get('has_update') else 'no')
")
    _log "END check_rke2 (update=$has_update)"
    _info "RKE2: update=$has_update"
}

# ---- Category D: CLI Tools (admin-vm 上のもののみ) ----
# act_runner は別ホスト (gitea-runner LXC) で稼働しているため対象外。

check_cli_tools() {
    _info "Checking CLI tool updates..."
    _log "START check_cli_tools"

    python3 - "$TMPDIR_UC/cli-results.json" "$TMPDIR_UC" << 'PYEOF'
import json, subprocess, sys, os, re

output_file = sys.argv[1]
tmpdir = sys.argv[2]

def normalize(v):
    return re.sub(r'^v', '', re.sub(r'[+-].*', '', v))

def get_current(name):
    cmds = {
        "helm": "helm version --short 2>/dev/null",
        "kubeseal": "kubeseal --version 2>&1",
        "cloudflared": "cloudflared --version 2>&1",
    }
    try:
        proc = subprocess.run(cmds[name], shell=True, capture_output=True, text=True, timeout=10)
        out = proc.stdout.strip()
        if name == "helm":
            return out.split("+")[0].lstrip("v")
        elif name == "kubeseal":
            return out.strip().split()[-1].lstrip("v")
        elif name == "cloudflared":
            parts = out.split()
            return parts[2] if len(parts) >= 3 else out
    except Exception:
        pass
    return "unknown"

def get_latest_github(repo):
    api_file = os.path.join(tmpdir, f"cli-gh-{repo.replace('/', '-')}.json")
    proc = subprocess.run(
        ["curl", "-sL", "--connect-timeout", "10", "--max-time", "30",
         "-o", api_file, "-w", "%{http_code}",
         f"https://api.github.com/repos/{repo}/releases/latest"],
        capture_output=True, text=True, timeout=35
    )
    if proc.stdout.strip() != "200":
        return None
    with open(api_file) as f:
        data = json.load(f)
    return data.get("tag_name", "")

checks = [
    {"name": "helm", "repo": "helm/helm",
     "hint": "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"},
    {"name": "kubeseal", "repo": "bitnami-labs/sealed-secrets",
     "hint": "# Download kubeseal from https://github.com/bitnami-labs/sealed-secrets/releases"},
    {"name": "cloudflared", "repo": "cloudflare/cloudflared",
     "hint": "sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared && sudo chmod +x /usr/local/bin/cloudflared"},
]

results = []
for c in checks:
    current = get_current(c["name"])
    try:
        latest = get_latest_github(c["repo"])

        if latest is None:
            results.append({"name": c["name"], "current": current, "latest": "error", "has_update": False, "apply_hint": c["hint"]})
            continue

        has_update = normalize(current) != normalize(latest)
        results.append({
            "name": c["name"],
            "current": current,
            "latest": latest,
            "has_update": has_update,
            "apply_hint": c["hint"],
        })
    except Exception as e:
        results.append({"name": c["name"], "current": current, "latest": f"error: {e}", "has_update": False, "apply_hint": c["hint"]})

with open(output_file, "w") as f:
    json.dump(results, f, indent=2)
PYEOF

    local count
    count=$(python3 -c "
import json
with open('$TMPDIR_UC/cli-results.json') as f:
    d = json.load(f)
print(sum(1 for x in d if x.get('has_update')))
")
    _log "END check_cli_tools (updates=$count)"
    _info "CLI tools: $count updates available"
}

# ---- Category E: OS Updates (admin-vm 自身のみ) ----
# cp1 / worker1 の OS パッチ状況は対象外 (admin-vm から root SSH 不可)。
# 別途 Zabbix 等での監視を検討。

check_os_updates() {
    _info "Checking OS updates (admin-vm only)..."
    _log "START check_os_updates"

    sudo apt-get update -qq 2>/dev/null || true

    local total security
    total=$(apt list --upgradable 2>/dev/null | grep -c "/" || true)
    security=$(apt-get -s dist-upgrade 2>/dev/null | grep "^Inst " | grep -c -i "secur" || true)
    total=${total:-0}
    security=${security:-0}

    python3 - "$total" "$security" "$TMPDIR_UC/os-result.json" << 'PYEOF'
import json, sys
result = {"total": int(sys.argv[1]), "security": int(sys.argv[2])}
with open(sys.argv[3], "w") as f:
    json.dump(result, f, indent=2)
PYEOF

    _log "END check_os_updates (total=$total, security=$security)"
    _info "OS (admin-vm): $total total updates ($security security)"
}

# ---- Report Builder ----

build_report() {
    _info "Building report..."

    python3 - "$TMPDIR_UC" "$REPORT_FILE" << 'PYEOF'
import json, sys, os
from datetime import datetime

tmpdir = sys.argv[1]
output = sys.argv[2]

def load_json(filename):
    path = os.path.join(tmpdir, filename)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)

helm = load_json("helm-results.json") or []
github = load_json("github-results.json") or []
rke2 = load_json("rke2-result.json") or {}
cli = load_json("cli-results.json") or []
os_updates = load_json("os-result.json") or {"total": 0, "security": 0}

total = 0
total += sum(1 for x in helm if x.get("has_update"))
total += sum(1 for x in github if x.get("has_update"))
total += 1 if rke2.get("has_update") else 0
total += sum(1 for x in cli if x.get("has_update"))
if os_updates.get("security", 0) > 0:
    total += 1

report = {
    "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "total_updates": total,
    "categories": {
        "helm_charts": helm,
        "kubectl_managed": github,
        "rke2": rke2,
        "cli_tools": cli,
        "os_updates": os_updates,
    }
}

with open(output, "w") as f:
    json.dump(report, f, indent=2, ensure_ascii=False)

print(f"Report: {total} updates found")
PYEOF
}

# ---- Notification (ntfy) ----

send_ntfy() {
    if [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_TOKEN:-}" ]; then
        _warn "NTFY_URL/NTFY_TOKEN 未設定のため通知をスキップ"
        return 0
    fi
    _info "Sending ntfy notification..."

    python3 - "$REPORT_FILE" "$NTFY_URL" "$NTFY_TOKEN" "$SYSTEM_LABEL" << 'PYEOF'
import json, sys, subprocess

with open(sys.argv[1]) as f:
    report = json.load(f)

if report["total_updates"] == 0:
    sys.exit(0)

ntfy_url, token, system_label = sys.argv[2], sys.argv[3], sys.argv[4]
lines = []

for item in report["categories"].get("helm_charts", []):
    if item.get("has_update"):
        lines.append(f"Helm: {item['name']} {item['current']} -> {item['latest']}")

for item in report["categories"].get("kubectl_managed", []):
    if item.get("has_update"):
        lines.append(f"K8s: {item['name']} {item['current']} -> {item['latest']}")

rke2 = report["categories"].get("rke2", {})
if rke2.get("has_update"):
    lines.append(f"RKE2: {rke2['current']} -> {rke2['latest_stable']}")

for item in report["categories"].get("cli_tools", []):
    if item.get("has_update"):
        lines.append(f"CLI: {item['name']} {item['current']} -> {item['latest']}")

os_info = report["categories"].get("os_updates", {})
if os_info.get("security", 0) > 0:
    lines.append(f"OS(admin-vm): total {os_info['total']} / security {os_info['security']}")

body = "\n".join(lines) + "\n\n詳細・適用コマンドは `update-check.sh report` で確認。"

proc = subprocess.run(
    ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
     "-H", f"Authorization: Bearer {token}",
     "-H", f"Title: [{system_label}] {report['total_updates']} updates available",
     "-H", "Priority: default",
     "-d", body,
     ntfy_url],
    capture_output=True, text=True, timeout=30
)
if proc.stdout.strip() != "200":
    print(f"ntfy publish failed: HTTP {proc.stdout.strip()}", file=sys.stderr)
    sys.exit(1)
PYEOF

    _ok "ntfy notification sent"
}

# ---- Commands ----

cmd_check() {
    mkdir -p "$TMPDIR_UC"
    _info "Starting update check... ($(date '+%Y-%m-%d %H:%M:%S'))"
    _log "=== Update check started ==="

    check_helm_charts     || _warn "Helm chart check failed"
    check_github_releases || _warn "kubectl-managed app check failed"
    check_rke2            || _warn "RKE2 check failed"
    check_cli_tools       || _warn "CLI tool check failed"
    check_os_updates      || _warn "OS update check failed"

    build_report

    local total
    total=$(python3 -c "
import json
with open('$REPORT_FILE') as f:
    d = json.load(f)
print(d.get('total_updates', 0))
")

    if [ "$total" -gt 0 ]; then
        _warn "$total updates available — sending notification..."
        send_ntfy || _warn "ntfy notification failed"
    else
        _ok "All components are up to date."
    fi

    _log "=== Update check completed (updates=$total) ==="
    _ok "Done. Report: $REPORT_FILE"
}

cmd_report() {
    if [ ! -f "$REPORT_FILE" ]; then
        _error "No report found. Run '$0 check' first."
        exit 1
    fi

    python3 - "$REPORT_FILE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    report = json.load(f)

print(f"\n{'='*60}")
print(f"  Homelab RKE2 Update Report")
print(f"  {report['timestamp']}")
print(f"  Total updates: {report['total_updates']}")
print(f"{'='*60}\n")

def print_section(title, items):
    print(f"  [{title}]")
    for item in items:
        marker = "!!" if item.get("has_update") else "ok"
        current = item.get("current", "?")
        latest = item.get("latest", "?")
        name = item.get("name", "?")
        if item.get("has_update"):
            print(f"    [{marker}] {name:25s} {current:20s} -> {latest}")
            print(f"         {item.get('apply_hint', '')}")
        else:
            print(f"    [{marker}] {name:25s} {current:20s}    (up to date)")
    print()

print_section("Helm Charts", report["categories"].get("helm_charts", []))
print_section("kubectl-managed Apps", report["categories"].get("kubectl_managed", []))

rke2 = report["categories"].get("rke2", {})
print("  [RKE2]")
marker = "!!" if rke2.get("has_update") else "ok"
print(f"    [{marker}] {'rke2-server':25s} {rke2.get('current','?'):20s}", end="")
if rke2.get("has_update"):
    print(f" -> {rke2.get('latest_stable','?')}")
    print(f"         {rke2.get('apply_hint', '')}")
else:
    print("    (up to date)")
if rke2.get("version_skew"):
    print(f"         WARNING: node version skew detected: {rke2.get('node_versions')}")
print()

print_section("CLI Tools", report["categories"].get("cli_tools", []))

os_info = report["categories"].get("os_updates", {})
print("  [OS Updates (admin-vm only)]")
print(f"    Total: {os_info.get('total', 0)} / Security: {os_info.get('security', 0)}")
if os_info.get("security", 0) > 0:
    print(f"         sudo apt-get upgrade -y")
print()
print(f"{'='*60}")
PYEOF
}

cmd_help() {
    cat << 'EOF'
Update Check & Notification (homelab RKE2 cluster)

Usage: update-check.sh <command>

Commands:
  check     全チェックを実行し、更新があれば ntfy に通知する
  report    最新レポートを表示する（人間可読）
  help      このヘルプを表示する

チェック対象:
  - Helm チャート（gitea, harbor, mariadb, postgresql, redis,
    prometheus-stack, longhorn, velero, kyverno, loki, promtail,
    metallb, trivy-operator, postgres-exporter, my-wordpress）
  - kubectl 管理アプリ（ArgoCD, cert-manager, sealed-secrets）
  - RKE2（stable チャンネル、kubectl 経由でノードバージョン取得）
  - CLI ツール（helm, kubeseal, cloudflared）
  - admin-vm 自身の OS セキュリティ更新（apt）

通知: ntfy（http://192.168.11.56/update-check、Bearer token）
  - 更新がある場合のみ送信。

設定ファイル: $HOME/.config/update-check/update-check.conf（UPDATE_CHECK_CONFIG で変更可）
スケジュール: 毎日 07:00（systemd --user timer: update-check.timer）

対象外（既知の制約）:
  - cp1 / worker1 の OS パッチ状況（admin-vm から root SSH 不可のため）
  - act_runner（gitea-runner LXC 上で稼働、別ホストのため対象外）
EOF
}

# ---- Main ----

case "${1:-help}" in
    check)   cmd_check ;;
    report)  cmd_report ;;
    help)    cmd_help ;;
    *)       _error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
