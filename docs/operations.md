# 運用手順

LiteLLM の管理者向けの手順です。案件の追加・キーの発行・モデルの追加は、**管理 UI（または管理 API）だけで完結し、コンテナの設定変更や再起動は不要**です。
構築手順は [setup.md](setup.md) を参照してください。

## 基本の考え方

```
チーム（= 案件）  … 予算の上限（max_budget）と、使えるモデルを持つ
 └─ キー          … 当面は案件ごとに 1 本を共有。将来はメンバーごとに発行する
```

- 予算は**チームに設定**します。キーには設定しません。
  チームに属するすべてのキーの利用額が合算され、上限に達するとチームのすべてのキーが使えなくなります。
- 予算は案件の期間の総額です。自動ではリセットしません（`budget_duration` は設定しない）。
- この形にしておくと、共有キーから個別キーへの移行で予算を付け替える必要がありません。

## 管理 UI と管理 API

- 管理 UI: `https://<サーバーの IP アドレス>/ui`（ユーザー名 `admin`、パスワードはマスターキー）
- 管理 API: このドキュメントのコマンド例は、サーバー上のリポジトリのディレクトリで、次の準備をしてから実行します。

```sh
cd <リポジトリのディレクトリ>
set -a; . ./.env; set +a
B=https://<サーバーの IP アドレス>
# マスターキーをコマンドライン引数に出さない（共用サーバーでは ps で他のユーザーに見えるため）
api() { curl -sS --cacert certs/ca/ca.crt -H @<(printf 'Authorization: Bearer %s\n' "$LITELLM_MASTER_KEY") -H 'content-type: application/json' "$@"; }
```

管理 UI と管理 API に接続できるのは、`.env` の `ADMIN_ALLOW_CIDRS` の範囲にある端末だけです（それ以外の PC からは 403 になります。`ADMIN_ALLOW_CIDRS` が空の場合は制限しません）。
サーバー上で上のコマンドを使う場合は、サーバー自身の IP アドレスも `ADMIN_ALLOW_CIDRS` に含めてください。

> [!NOTE]
> `set -a; . ./.env` を実行したシェルでは、`.env` の値が環境変数として残ります。Docker Compose は `.env` ファイルより環境変数を優先するため、
> そのシェルで `.env` を書き換えてから `docker compose up` しても、古い値が使われます。`.env` を変更したら、新しいシェルで `docker compose` を実行してください。

> [!WARNING]
> マスターキーはすべての操作ができる管理者用の鍵です。メンバーには配布しないでください。

## 案件を追加する

### 1. チームを作る

管理 UI の **Teams** で新しいチームを作成し、次の値を設定します。

| 項目 | 値 |
| --- | --- |
| Team Name | 案件名（例: `projA`） |
| Max Budget (USD) | 案件の予算の総額 |
| Reset Budget | 設定しない |
| Models | 案件で使うモデル。**Cowork を使う案件には必ず `claude-sonnet-5` を含める**（Auto モードの安全性分類器が使う） |

```sh
api "$B/team/new" -d '{"team_alias":"projA","max_budget":500,"models":["claude-sonnet-5","claude-sonnet-5-5","claude-opus-5-5"]}'
```

### 2. キーを発行する

管理 UI の **Virtual Keys** でキーを作成し、上で作ったチームを選びます。
キーの名前（Key Alias）は `<案件名>-shared` とします。

```sh
api "$B/key/generate" -d '{"team_id":"<チーム ID>","key_alias":"projA-shared"}'
```

キーは作成時に一度だけ表示されます。安全な方法で案件のメンバーに渡し、[client-setup.md](client-setup.md) の手順で設定してもらいます。

案件の終了日が決まっている場合は、キーに有効期限（Expire / `duration`）を設定できます。

## 予算を変更する・利用状況を確認する

- 予算の引き上げ: 管理 UI でチームを編集し、Max Budget を変更します。変更はすぐに反映されます。

```sh
api "$B/team/update" -d '{"team_id":"<チーム ID>","max_budget":800}'
api "$B/team/info?team_id=<チーム ID>"     # spend が現在の利用額
```

- 利用状況: 管理 UI の **Usage** と **Logs** で、チーム・キー・モデルごとの利用額を確認できます。

### 予算超過時の動き

- 上限に達したチームのキーでリクエストすると、HTTP 422（`budget_exceeded`）が返ります。Claude Desktop では一般的なエラーとして表示されます。
- 上限のチェックはリクエストの**前**に行われます。そのため、上限の直前に始まったリクエストの分だけ、利用額が上限を少し超えることがあります。
- 利用額は LiteLLM の料金表から計算した見積額です。AWS や Azure の実際の請求額とは一致しないことがあります。

## 共有キーから個別キーに移行する

コンテナの設定変更は不要です。予算はチームに付いているので、そのまま引き継がれます。

1. 同じチームに、メンバーごとのキーを発行する（Key Alias は `<案件名>-<メンバー名>`）。
2. 各メンバーの Claude Desktop の設定を、新しいキーに切り替えてもらう。
3. 全員の切り替えが終わったら、共有キー（`<案件名>-shared`）を削除する。

```sh
api "$B/key/generate" -d '{"team_id":"<チーム ID>","key_alias":"projA-alice"}'
api "$B/key/delete" -d '{"key_aliases":["projA-shared"]}'
```

メンバーが案件から外れたときは、そのメンバーのキーだけを削除します。

## Azure OpenAI のモデルを追加する

Azure の認証情報は管理 UI で登録し、DB に暗号化して保存します（[ADR 0001](adr/0001-store-azure-credentials-in-db.md)）。

1. Azure で、案件のリソースにモデルをデプロイしておく。
2. 管理 UI の **Models**（モデルの追加画面）で次の値を入力する。

| 項目 | 値 |
| --- | --- |
| Provider | Azure |
| モデル名（Public Model Name） | **`<案件名>-<モデル名>`**（例: `projA-gpt-5`） |
| LiteLLM Model Name | `azure/<Azure のデプロイ名>` |
| API Base | `https://<リソース名>.openai.azure.com` |
| API Key | リソースのキー |
| API Version | Azure で使う API バージョン |

3. 案件のチームの Models に、追加したモデル名を加える。

> [!WARNING]
> モデル名は必ず案件名を先頭に付け、全体で一意にしてください。
> 異なる案件のリソースを同じモデル名で登録すると、LiteLLM はそれらの間で負荷分散します。その結果、別の案件のリソースにリクエストが流れてしまいます。

同じリソースのデプロイを複数登録する場合は、モデルの詳細画面の **Re-use Credentials** で認証情報に名前を付けると、次から入力を省略できます。

## Bedrock のモデルを追加する

Claude Desktop 用の Claude モデルは `litellm/config.yaml` で定義しています。
変更した場合は `docker compose restart litellm` で反映します（`restart` はコンテナを作り直さないため、nginx の再起動は不要です）。
それ以外の Bedrock モデルは、管理 UI で追加します。

- Provider: Amazon Bedrock
- LiteLLM Model Name: `bedrock/<モデル ID または推論プロファイル ID>`
- 認証情報: 入力しない。コンテナの環境変数（`.env` の AWS のアクセスキー）が使われます。
- Claude Desktop のモデル一覧に表示したいモデルは、モデル名に `claude` か `anthropic` を含めます。

追加する前に、AWS の Bedrock コンソールで、us-east-1 でのモデルの利用を有効にしておきます。

## 案件を終了する

1. チームのキーをすべて削除する。
2. 管理 UI でチームを削除する（利用ログは残ります）。
3. 案件専用の Azure モデルを削除する。

## バックアップとリストア

バックアップの対象は 2 つです。

| 対象 | 内容 | 頻度 |
| --- | --- | --- |
| `.env` | マスターキー・**ソルトキー**・各種パスワード | 作成時と変更時 |
| PostgreSQL | チーム・キー・予算・利用額・管理 UI で登録したモデルと認証情報 | 毎日（cron など） |

DB のバックアップは、ソルトキーがないと認証情報を復号できません。必ず `.env` とセットで保管してください。
バックアップにはキーのハッシュや暗号化された認証情報が含まれます。所有者だけが読めるように作成します。

```sh
# バックアップ（umask 077 で、所有者だけが読めるファイルにする）
(
  umask 077
  mkdir -p backups
  docker compose exec -T db pg_dump -U litellm -d litellm --format=custom > "backups/litellm-$(date +%F).dump"
)

# リストア（LiteLLM を止めてから行う）
docker compose stop litellm
docker compose exec -T db pg_restore -U litellm -d litellm --clean --if-exists < backups/litellm-YYYY-MM-DD.dump
docker compose start litellm
```

## LiteLLM を更新する

1. [リリースノート](https://docs.litellm.ai/release_notes)で、破壊的変更を確認する。
2. DB をバックアップする（DB のマイグレーションは元に戻せないため、ロールバックはリストアで行う）。
3. 新しいバージョンのイメージの digest を確認する。

```sh
docker buildx imagetools inspect ghcr.io/berriai/litellm:<バージョン> | grep -m1 '^Digest:'
```

4. `docker-compose.yml` の `image:` を `ghcr.io/berriai/litellm:<バージョン>@sha256:<digest>` に書き換え、PR でレビューを受ける。
   nginx と PostgreSQL のイメージも、同じ形でタグと digest を更新する。
5. サーバーで反映する（変数の準備は「[管理 UI と管理 API](#管理-ui-と管理-api)」を参照）。

```sh
git pull
docker compose pull litellm
# --wait: LiteLLM が起動を終える（healthy になる）まで待つ。待たずに確認すると 502 になる
docker compose up -d --wait litellm
# litellm コンテナを作り直すと IP アドレスが変わることがある。nginx は起動時に
# 宛先を名前解決するため、再起動して新しい宛先を読み込ませる
docker compose restart nginx
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh "$B" --inference
```

更新後は、Cowork の Auto モードとプロンプトキャッシュも確認してください（[setup.md の PoC での確認](setup.md#7-poc-での確認)の P2・P3）。

## サーバー証明書を更新する

サーバー証明書の有効期間は 825 日です。期限の前、またはサーバーの IP アドレスが変わったときに再発行します。

```sh
# 退避していたルート CA の秘密鍵を一時的に certs/ca/ca.key に戻してから実行する
scripts/certs/issue-server-cert.sh <サーバーの IP アドレス>
docker compose restart nginx
# 終わったら certs/ca/ca.key を再び退避する
```

新しい IP アドレスがルート CA の許可範囲内であれば、PC 側の作業は不要です。
新しい IP アドレスがルート CA の許可範囲の外にある場合は、ルート CA から作り直し、全 PC に配布し直します。

## 検証済みの動作

構築時に、LiteLLM 1.106.6 をローカル環境で起動して次の点を確認しました（AWS / Azure には接続していません）。

- 自前のルート CA で発行した証明書で HTTPS 接続できる。ルート CA を指定しない接続は拒否される。
- `/v1/models` に `litellm/config.yaml` の 4 つの Claude モデルが表示される。キーなしのリクエストは 401 になる。
- Invoke 経路のモデルでも、料金表の US 推論プロファイルの単価で利用額が計算される。
- 上流のエラーは、Anthropic 形式のエラー本文とステータスコードのまま返る。
- チームに許可していないモデルへのリクエストは拒否される。
- チームの利用額が上限を超えると、そのチームのすべてのキー（後から追加したキーを含む）が 422 になる。予算を引き上げると再び使える。
- 削除したキーは 401 になる。
- 管理 API で登録したモデルの API キーと API Base は、DB に暗号化して保存される。
- 利用ログにプロンプトと応答の本文は保存されない。
- `ADMIN_ALLOW_CIDRS` の範囲外からは、管理 UI・管理 API・Bedrock のパススルー・詳細なヘルスチェックが 403 になり、推論 API（`/v1/models` など）とヘルスチェック（`/health/liveliness`）だけが使える。
- `ADMIN_ALLOW_CIDRS` に不正な値を設定すると、nginx は起動しない。空の場合は、管理系の接続元を制限せずに起動する。
- `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` が空でも、LiteLLM は起動する。
- `%2F` や `..` を含むパスで推論 API に見せかけて管理系やパススルーに届かせる手口は、400 で拒否される（`tests/nginx.test.sh` で自動テスト）。
- `STORE_MODEL_IN_DB` を環境変数だけで設定した状態で、管理 API からモデルを追加できる。
