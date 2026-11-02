# Claude Cowork 連携対応 LiteLLM

社内 PC の Claude Desktop / Cowork を、Claude の契約なしにサードパーティ推論（Gateway モード）で使うための LiteLLM 構成です。
案件ごとにキーを発行して予算の上限を設定し、AWS Bedrock と Azure OpenAI のモデルを提供します。

```
社内 PC（Claude Desktop）──HTTPS──► nginx ──► LiteLLM ──► AWS Bedrock / Azure OpenAI
                                                  │
                                              PostgreSQL
```

## 特徴

- docker-compose で構築します（nginx / LiteLLM / PostgreSQL）。
- 機密情報は `.env` に分けています（Azure の認証情報は管理 UI で登録し、DB に暗号化して保存します）。
- 自前のルート CA で HTTPS 化します。ルート CA は、署名できる範囲を指定した IP アドレス範囲に、用途をサーバー認証に限定しています。
- 一般の PC に公開するのは推論 API とヘルスチェックだけです。管理 UI・管理 API は管理者の端末からだけ使えます。
- 使わない LiteLLM の機能（API ドキュメント、Moyai、Lens、Auto Router、Enterprise 機能）は無効にし、外への通信は Bedrock と Azure だけにしています。
- 案件（チーム）ごとに予算の上限を設定し、上限に達したらその案件のキーを止めます。
- Cowork の Auto モードに対応しています（`claude-sonnet-5` を提供）。

## ドキュメント

| ドキュメント | 対象 | 内容 |
| --- | --- | --- |
| [docs/requirements.md](docs/requirements.md) | 全員 | 要件定義 |
| [docs/setup.md](docs/setup.md) | サーバー管理者 | 構築手順 |
| [docs/operations.md](docs/operations.md) | LiteLLM 管理者 | 案件の追加、キーの発行、Azure モデルの追加、バックアップ、更新 |
| [docs/migration.md](docs/migration.md) | サーバー管理者 | 現行環境からの移行（DB のダンプとリストア） |
| [docs/client-setup.md](docs/client-setup.md) | 利用者 | 社内 PC の設定（ルート CA、Claude Desktop） |
| [docs/adr/](docs/adr/) | 開発者 | 設計判断の記録 |

## クイックスタート

```sh
cp .env.example .env && chmod 600 .env    # 値を設定する
scripts/certs/create-ca.sh <サーバーの IP>/32
scripts/certs/issue-server-cert.sh <サーバーの IP>
docker compose up -d --wait
set -a; . ./.env; set +a
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP>
```

詳しくは [docs/setup.md](docs/setup.md) を参照してください。

## 開発

```sh
scripts/harness/check.sh         # 品質ゲート（lint: scripts/lint.sh、test: tests/run.sh）
```
