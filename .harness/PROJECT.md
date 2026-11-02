# プロジェクトプロファイル

このファイルには、このプロジェクト固有の情報を書きます。AI エージェントと新しく参加したメンバーが最初に読むファイルです。
汎用の規約（`docs/harness/`）より、このファイルの内容が優先されます。

## 概要

社内 PC の Claude Desktop / Cowork を、LiteLLM 経由で AWS Bedrock・Azure OpenAI に接続するための構成一式（docker-compose・設定・スクリプト・手順書）。
LiteLLM の管理者が構築・運用し、各案件のメンバーが割り当てられたキーで利用する。要件は `docs/requirements.md`。

## 技術スタック

| 項目 | 内容 |
| --- | --- |
| 言語・バージョン | Bash（スクリプト）、YAML（compose / LiteLLM 設定）、nginx 設定 |
| フレームワーク | LiteLLM Proxy（`ghcr.io/berriai/litellm`）、nginx、PostgreSQL |
| パッケージ管理 | なし（コンテナイメージはタグを固定する） |
| テスト | Bash のテストスクリプト（`tests/*.test.sh`。`tests/run.sh` がすべて実行する。`tests/nginx.test.sh` は Docker がない環境ではスキップ） |
| フォーマッタ / リンタ | `scripts/lint.sh`（`bash -n`、shellcheck があれば実行、`docker compose config`） |
| 実行環境 | Linux サーバー上の Docker Compose v2 |

## ディレクトリ構成

```
docker-compose.yml  # nginx / LiteLLM / PostgreSQL の定義
.env.example        # 機密情報のひな形（.env は Git 管理外）
litellm/            # LiteLLM の config.yaml
nginx/              # nginx の設定（default.conf）と起動時スクリプト（entrypoint/）
scripts/certs/      # ルート CA とサーバー証明書の作成スクリプト
scripts/migration/  # 現行環境からの移行（DB のダンプとリストア）のスクリプト
scripts/            # 疎通確認（smoke-test.sh）、lint
tests/              # スクリプトのテスト
docs/               # 要件・構築・運用・PC 設定の手順書、ADR
certs/              # 生成した証明書と鍵（Git 管理外）
```

## アーキテクチャ方針

- 外部に公開するのは nginx の 443 番ポートだけ。LiteLLM と PostgreSQL はホストに公開しない。
- 一般の PC に公開するのは推論 API とヘルスチェックだけ。管理 UI・管理 API は `ADMIN_ALLOW_CIDRS` の端末からだけ（nginx で制限。空なら制限しない）。
- ルート CA は用途（serverAuth）と範囲（IP アドレス範囲）を制限する（`docs/adr/0002-self-signed-root-ca-with-constraints.md`）。
- 機密情報はコード・`docker-compose.yml`・`config.yaml` に書かない。起動に必要なものは `.env`、Azure の認証情報は管理 UI から DB に暗号化して保存する（`docs/adr/0001-store-azure-credentials-in-db.md`）。
- `litellm/config.yaml` には Claude Desktop 用の Claude モデルだけを置く。それ以外のモデル・チーム・キー・予算は管理 UI で管理する。
- Bedrock の Claude は Invoke 経路（`bedrock/invoke/`）を使う（`docs/adr/0003-use-bedrock-invoke-route-for-claude.md`）。
- コンテナイメージはタグと digest の両方で固定する。

## コーディング規約（プロジェクト固有）

- 命名: シェル関数は `snake_case`。共有ライブラリの関数は `certs::` のように名前空間を付ける。
- エラー処理: スクリプトは `set -euo pipefail`。利用者向けのエラーは `エラー: ...` を標準エラー出力に出して終了する。
- ログ: スクリプトの利用者向けメッセージは日本語。
- テストの配置と命名: `tests/<対象>.test.sh`（`tests/run.sh` が自動で実行する）。`tests/lib.sh` を読み込み、`test_` で始まる関数を定義して最後に `run_all_tests` を呼ぶ。失敗を期待する呼び出しは `expect_fail` を使う（`! cmd` は `set -e` で止まらないため使わない）。
- コード中のコメントの言語: 日本語（`scripts/harness/` と `tests/` は英語）
- シェル: bash 3.2 でも動く書き方にする（`mapfile` を使わない）。ただし実行環境は Linux なので、GNU coreutils 前提の箇所（`stat -c` など）は許容する。
- コミットメッセージの言語: 日本語

## コマンド

品質ゲートのコマンドは `.harness/project.env` で指定しています（`scripts/harness/detect.sh` で確認）。

| 用途 | コマンド |
| --- | --- |
| 依存のインストール | なし（Docker・OpenSSL を使う） |
| ローカル起動 | `docker compose up -d --wait`（`docs/setup.md`） |
| 疎通確認 | `scripts/smoke-test.sh https://<IP>` |
| 品質ゲート | `scripts/harness/check.sh` |

## 依存関係のポリシー

- コンテナイメージはバージョンのタグと digest で固定する（`latest` や `main-stable` は使わない）。
- LiteLLM の更新は、リリースノートを確認し、DB をバックアップしてから行う（`docs/operations.md`）。

## 変更してはいけないもの

- `litellm/config.yaml` の `claude-sonnet-5` というモデル名（Claude Desktop の Auto モードがこの名前で呼ぶ）。
- 運用開始後の `LITELLM_SALT_KEY`（変えると DB 内の認証情報を復号できなくなる）。

## 用語集

| 用語 | 意味 | コード上の名前 |
| --- | --- | --- |
| 案件 | 予算を管理する単位。LiteLLM のチーム | Team |
| キー | 利用者が Claude Desktop に設定する仮想キー | Virtual Key |
| ルート CA | サーバー証明書を発行する自前の認証局。各 PC に入れる | `certs/ca/ca.crt` |
| Auto モード | Claude が操作の承認を自動で判断するモード。Cowork では Automatically approve | `autoModeEnabled` |
