# zabbix-configs

Zabbix の `configuration.export` 等で取得した raw export は **このディレクトリに含めない**（`.gitignore` で除外済）。

理由: raw export には以下のような機微情報が含まれる。
- Mailgun SMTP password (mediatype.passwd)
- Discord webhook URL (Admin user の sendto)
- その他認証 token 等

## 運用ルール

1. **raw export はローカル限定** — `~/.zabbix-backups/` 等の Git 管理外に保管
2. **PVE vzdump で LXC ごとバックアップ** — 真の DR はこちら（Phase 6-B 参照）
3. **公開可能な範囲のスナップショットを残したい場合** は `sanitized/` 配下にサニタイズ済みファイルを配置
   - password, webhook URL, token 等を `<masked>` に置換してから commit
