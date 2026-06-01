# VOICEVOX (Japanese neural TTS) on RKE2

FreePBX(LXC 109)の IVR / アナウンス用に、**日本語の音声プロンプトを事前生成**するための VOICEVOX engine。

- 用途: 静的プロンプト(「営業は1、サポートは2」等)を高品質な日本語で生成 → WAV → Asterisk 形式に変換 → FreePBX System Recordings に登録。**毎回 TTS せず録音を再生**する方式(遅延ゼロ・最高品質・無料)。
- 動的 TTS(通話時の可変読み上げ)は FreePBX 側で Google Cloud TTS 等を併用(本エンジンとは別)。

## 構成
- `k8s/base/`: namespace `voicevox` / Deployment(`voicevox/voicevox_engine:cpu-latest`, replicas 1, worker1 へ soft affinity, req 100m/300Mi・limit 2/2Gi) / Service(ClusterIP `voicevox.voicevox.svc:50021`)。
- `k8s/overlays/production/`: base への passthrough。
- `k8s/argocd/application.yaml`: ArgoCD App(GitHub repo, automated sync)。

## デプロイ
親 PR が main にマージされた後、一度だけ:
```
kubectl apply -f voicevox/k8s/argocd/application.yaml
```
以降は ArgoCD が sync。

## プロンプト生成の使い方(例)
クラスタ内 ClusterIP なので、生成時は port-forward でアクセス:
```
kubectl -n voicevox port-forward svc/voicevox 50021:50021 &
# 1) 音声合成クエリ生成 (speaker は VOICEVOX の話者ID)
curl -s "localhost:50021/audio_query?speaker=3" --data-urlencode "text=お電話ありがとうございます" -G > q.json
# 2) 合成 (24kHz WAV)
curl -s -H 'Content-Type: application/json' -d @q.json "localhost:50021/synthesis?speaker=3" > out.wav
# 3) Asterisk 形式へ変換 (例: 8kHz mono) し System Recordings へ
sox out.wav -r 8000 -c 1 -t wav prompt.wav   # or ffmpeg
```
変換後の WAV を FreePBX の Admin → System Recordings でアップロードして IVR/アナウンスで参照。

## メモ
- 画像は当面 `cpu-latest`。GitOps 再現性のため初回 sync 後に稼働中バージョンへ pin する(TODO, deployment.yaml)。
- cp1 はメモリ逼迫のため worker1 へ soft 寄せ。idle 時は軽量、生成時のみ CPU を使う。
