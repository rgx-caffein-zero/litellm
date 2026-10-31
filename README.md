# Claude Cowork 連携対応 LiteLLM

社内 PC の Claude Desktop / Cowork を、Claude の契約なしにサードパーティ推論（Gateway モード）で使うための LiteLLM 構成です。
案件ごとにキーを発行して予算の上限を設定し、AWS Bedrock と Azure OpenAI のモデルを提供します。

- [構成](#構成)
- [構築](#構築)
- [運用](#運用)
- [社内 PC の設定](#社内-pc-の設定)
- [トラブルシューティング](#トラブルシューティング)

## 構成

```
社内 PC（Claude Desktop）
   │ HTTPS（443）。証明書は自前のルート CA で発行
   ▼
nginx ──► LiteLLM ──► AWS Bedrock（us-east-1）
             │    └─► Azure OpenAI（案件ごとのリソース）
             ▼
         PostgreSQL（チーム・キー・予算・利用ログ・管理 UI で登録したモデルと認証情報）
```

外部に公開するのは nginx の 443 番ポートだけです。LiteLLM と PostgreSQL はホストのポートに公開しません。
nginx は、一般の PC には推論 API とヘルスチェックだけを公開し、管理 UI・管理 API は管理者の端末（`.env` の `ADMIN_ALLOW_CIDRS`）からだけ受け付けます。

| ファイル | 役割 |
| --- | --- |
| `docker-compose.yml` | 3 つのコンテナの定義 |
| `.env` | 機密情報（`.env.example` から作成。Git 管理外） |
| `litellm/config.yaml` | Claude Desktop 用の Claude モデルと全体設定 |
| `nginx/default.conf` | HTTPS 終端、プロキシ設定、アクセス制御 |
| `nginx/entrypoint/40-admin-allow.sh` | 起動時に `ADMIN_ALLOW_CIDRS` から管理系の許可リストを生成する |
| `scripts/certs/` | ルート CA とサーバー証明書の作成スクリプト |
| `scripts/smoke-test.sh` | 接続・モデル一覧・推論の確認スクリプト |
| `certs/` | ルート CA とサーバー証明書（スクリプトで作成。Git 管理外） |

## 構築

### 1. 前提条件

**サーバー**

- Linux、Docker Engine、Docker Compose v2、OpenSSL、Git、curl 7.76 以降
- 社内 PC から、サーバーの IP アドレスの 443 番ポートに接続できること
- サーバーから次の宛先へ HTTPS で接続できること
  - `bedrock-runtime.us-east-1.amazonaws.com`（と、US 推論プロファイルが使う US の各リージョン）
  - 案件の Azure OpenAI リソースのエンドポイント
  - コンテナイメージの取得元: `ghcr.io`、Docker Hub

**AWS**

1. us-east-1 の Bedrock コンソールで、使う Claude モデルの利用を有効にする。
   少なくとも **Claude Sonnet 5** は必須です（Cowork の Auto モードの安全性分類器が使う）。
2. LiteLLM 専用の IAM ユーザーを作り、アクセスキーを発行する。権限は次のとおりです。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:<AWS アカウント ID>:inference-profile/*"
      ]
    }
  ]
}
```

US 推論プロファイル（`us.anthropic.*`）は US 内の複数リージョンにリクエストを振り分けるため、`foundation-model` のリージョンは `*` にしています。

### 2. `.env` の作成

```sh
git clone <このリポジトリの URL> litellm
cd litellm
cp .env.example .env
chmod 600 .env
```

`.env` を編集して値を設定します。ランダムな値は次のように生成できます。

```sh
printf 'sk-%s\n' "$(openssl rand -hex 32)"   # LITELLM_MASTER_KEY、LITELLM_SALT_KEY
openssl rand -hex 24                         # POSTGRES_PASSWORD
```

`ADMIN_ALLOW_CIDRS` には、管理 UI・管理 API を使う端末の IP 範囲を空白区切りで指定します（例: `ADMIN_ALLOW_CIDRS="10.1.5.0/24 10.1.2.3/32"`）。
サーバー上で管理 API を使う場合は、サーバー自身の IP アドレスも含めます。
空の場合は接続元を制限しません（マスターキーの認証だけで守られます）。不正な値や全開放（`/0`）を指定すると、nginx は起動しません。

> [!WARNING]
> Docker のブリッジネットワークの範囲（`172.16.0.0/12` など）は `ADMIN_ALLOW_CIDRS` に入れないでください。
> 外部からの接続元がブリッジのゲートウェイ（例: `172.18.0.1`）に見える構成では、すべての PC が管理系に届いてしまいます。

> [!IMPORTANT]
> `LITELLM_SALT_KEY` は、管理 UI で登録した Azure の API キーなどを暗号化する鍵です。
> **一度設定したら変更しないでください。** 変更・紛失すると、登録済みの認証情報を復号できなくなります。
> `.env` は作成した時点で、サーバー以外の安全な場所にもバックアップしてください。

### 3. 証明書の作成

```sh
scripts/certs/create-ca.sh <許可する IP 範囲>
scripts/certs/issue-server-cert.sh <サーバーの IP アドレス>
```

- `<許可する IP 範囲>`: このルート CA が証明書を発行できる IP アドレスの範囲（CIDR）。
  `10.1.2.3/32`（サーバーの IP だけ）が最も安全です。サーバーの IP が変わる可能性がある場合は `10.1.2.0/24` のようにサブネットを指定すると、範囲内の変更ならサーバー証明書の再発行だけで済みます。
  範囲は `/8` より広くできず、ホスト部は 0 にします。
- `<サーバーの IP アドレス>`: 社内 PC が接続に使う IP アドレス（Gateway base URL に書く IP アドレス）。名前（`localhost` など）は指定できません。

`create-ca.sh` が出力する **拇印（SHA-1）** を控えておきます。社内 PC でルート CA をインストールするときに照合します。
ルート CA は用途をサーバー認証に、発行できる範囲を指定した IP アドレスに限定しているため、秘密鍵が漏れても一般の Web サイトの偽証明書などは作れません。

サーバー証明書（有効期間 825 日）を発行したら、ルート CA の秘密鍵 `certs/ca/ca.key` をサーバーから外し、安全な場所で保管します。

```sh
# 例: 管理者の端末にコピーしてから、サーバー上のファイルを削除する
scp <サーバー>:litellm/certs/ca/ca.key ./litellm-ca.key
ssh <サーバー> 'shred -u litellm/certs/ca/ca.key'
```

### 4. 起動

```sh
docker compose up -d --wait
docker compose ps
```

`--wait` は、`litellm` と `db` が `healthy` になるまで待ちます。初回は DB のマイグレーションがあるため、1〜2 分かかります。

### 5. 動作確認

```sh
set -a; . ./.env; set +a
# HTTPS 接続とモデル一覧（課金なし）
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP アドレス>
# Bedrock への推論（少額の課金あり）
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP アドレス> --inference
```

`--inference` で、イベントが少しずつ表示されれば、ストリーミングがバッファリングされずに届いています。

管理 UI は、ブラウザーで `https://<サーバーの IP アドレス>/ui` を開き、ユーザー名 `admin`、パスワードにマスターキーを入力してログインします。

## 運用

案件の追加・キーの発行・モデルの追加は、管理 UI（または管理 API）だけで完結します。コンテナの設定変更や再起動は不要です。

```
チーム（= 案件）  … 予算の上限（max_budget）と、使えるモデルを持つ
 └─ キー          … 当面は案件ごとに 1 本を共有。将来はメンバーごとに発行する
```

予算は**チームに設定**します（キーには設定しません）。チームに属するすべてのキーの利用額が合算され、上限に達するとチームのすべてのキーが使えなくなります。
予算は案件の期間の総額で、自動ではリセットしません。

### 管理 API の準備

以下のコマンド例は、サーバー上のリポジトリのディレクトリで次の準備をしてから実行します。

```sh
set -a; . ./.env; set +a
B=https://<サーバーの IP アドレス>
# マスターキーをコマンドライン引数に出さない（共用サーバーでは ps で他のユーザーに見えるため）
api() { curl -sS --cacert certs/ca/ca.crt -H @<(printf 'Authorization: Bearer %s\n' "$LITELLM_MASTER_KEY") -H 'content-type: application/json' "$@"; }
```

> [!NOTE]
> `set -a; . ./.env` を実行したシェルでは `.env` の値が環境変数として残り、Docker Compose は `.env` ファイルよりそちらを優先します。
> `.env` を変更したら、新しいシェルで `docker compose` を実行してください。

> [!WARNING]
> マスターキーはすべての操作ができる管理者用の鍵です。メンバーには配布しないでください。

### 案件を追加する

1. 管理 UI の **Teams** でチームを作成する。

| 項目 | 値 |
| --- | --- |
| Team Name | 案件名（例: `projA`） |
| Max Budget (USD) | 案件の予算の総額 |
| Reset Budget | 設定しない |
| Models | 案件で使うモデル。**Cowork を使う案件には必ず `claude-sonnet-5` を含める** |

2. 管理 UI の **Virtual Keys** でキーを作成し、上のチームを選ぶ。Key Alias は `<案件名>-shared` とする。
   案件の終了日が決まっている場合は、有効期限（Expire）も設定できる。
3. キーは作成時に一度だけ表示される。安全な方法で案件のメンバーに渡す。

```sh
api "$B/team/new" -d '{"team_alias":"projA","max_budget":500,"models":["claude-sonnet-5","claude-sonnet-5-5","claude-opus-5-5"]}'
api "$B/key/generate" -d '{"team_id":"<チーム ID>","key_alias":"projA-shared"}'
```

### 予算を変更する・利用状況を確認する

管理 UI でチームの Max Budget を変更すると、すぐに反映されます。利用状況は管理 UI の **Usage** と **Logs** で確認できます。

```sh
api "$B/team/update" -d '{"team_id":"<チーム ID>","max_budget":800}'
api "$B/team/info?team_id=<チーム ID>"     # spend が現在の利用額
```

- 上限に達したチームのキーでリクエストすると、HTTP 422（`budget_exceeded`）が返ります。
- 上限のチェックはリクエストの前に行うため、利用額が上限を少し超えることがあります。
- 利用額は LiteLLM の料金表から計算した見積額で、AWS や Azure の実際の請求額とは一致しないことがあります。

### 共有キーから個別キーに移行する

予算はチームに付いているので、そのまま引き継がれます。

1. 同じチームに、メンバーごとのキーを発行する（Key Alias は `<案件名>-<メンバー名>`）。
2. 各メンバーの Claude Desktop の設定を、新しいキーに切り替えてもらう。
3. 全員の切り替えが終わったら、共有キーを削除する。

```sh
api "$B/key/generate" -d '{"team_id":"<チーム ID>","key_alias":"projA-alice"}'
api "$B/key/delete" -d '{"key_aliases":["projA-shared"]}'
```

### Azure OpenAI のモデルを追加する

Azure の認証情報は管理 UI で登録し、DB に暗号化して保存します。

1. Azure で、案件のリソースにモデルをデプロイしておく。
2. 管理 UI の **Models** で次の値を入力する。

| 項目 | 値 |
| --- | --- |
| Provider | Azure |
| Public Model Name | **`<案件名>-<モデル名>`**（例: `projA-gpt-5`） |
| LiteLLM Model Name | `azure/<Azure のデプロイ名>` |
| API Base | `https://<リソース名>.openai.azure.com` |
| API Key | リソースのキー |
| API Version | Azure で使う API バージョン |

3. 案件のチームの Models に、追加したモデル名を加える。

> [!WARNING]
> モデル名は必ず案件名を先頭に付け、全体で一意にしてください。
> 異なる案件のリソースを同じモデル名で登録すると、LiteLLM はそれらの間で負荷分散し、別の案件のリソースにリクエストが流れます。

### Bedrock のモデルを追加する

Claude Desktop 用の Claude モデルは `litellm/config.yaml` で定義しています。変更した場合は `docker compose restart litellm` で反映します。
それ以外の Bedrock モデルは管理 UI で追加します（Provider: Amazon Bedrock、LiteLLM Model Name: `bedrock/<モデル ID または推論プロファイル ID>`、認証情報は入力しない）。
Claude Desktop のモデル一覧に表示したいモデルは、モデル名に `claude` か `anthropic` を含めます。
追加する前に、Bedrock コンソールで us-east-1 でのモデルの利用を有効にしておきます。

### 案件を終了する

1. チームのキーをすべて削除する。
2. 管理 UI でチームを削除する（利用ログは残ります）。
3. 案件専用の Azure モデルを削除する。

### バックアップとリストア

| 対象 | 内容 | 頻度 |
| --- | --- | --- |
| `.env` | マスターキー・**ソルトキー**・各種パスワード | 作成時と変更時 |
| PostgreSQL | チーム・キー・予算・利用額・管理 UI で登録したモデルと認証情報 | 毎日（cron など） |

DB のバックアップは、ソルトキーがないと認証情報を復号できません。必ず `.env` とセットで保管してください。

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

### LiteLLM を更新する

1. [リリースノート](https://docs.litellm.ai/release_notes)で、破壊的変更を確認する。
2. DB をバックアップする（DB のマイグレーションは元に戻せないため、ロールバックはリストアで行う）。
3. 新しいバージョンのイメージの digest を確認し、`docker-compose.yml` の `image:` を `ghcr.io/berriai/litellm:<バージョン>@sha256:<digest>` に書き換える。

```sh
docker buildx imagetools inspect ghcr.io/berriai/litellm:<バージョン> | grep -m1 '^Digest:'
```

4. 反映して確認する。

```sh
docker compose pull litellm
docker compose up -d --wait litellm
# litellm コンテナを作り直すと IP アドレスが変わることがあるため、nginx を再起動して宛先を読み込み直す
docker compose restart nginx
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh "$B" --inference
```

### サーバー証明書を更新する

有効期間（825 日）の前、またはサーバーの IP アドレスが変わったときに再発行します。

```sh
# 退避していたルート CA の秘密鍵を一時的に certs/ca/ca.key に戻してから実行する
scripts/certs/issue-server-cert.sh <サーバーの IP アドレス>
docker compose restart nginx
# 終わったら certs/ca/ca.key を再び退避する
```

新しい IP アドレスがルート CA の許可範囲の外にある場合は、ルート CA から作り直し、全 PC に配布し直します。

## 社内 PC の設定

各メンバーの Windows PC で、LiteLLM 経由の Claude Desktop / Cowork を使えるようにする手順です。
管理者は、メンバーに次のものを渡します。

| もの | 内容 |
| --- | --- |
| ルート CA 証明書 | `certs/ca/ca.crt` |
| ルート CA の拇印（SHA-1） | `create-ca.sh` が出力した 40 文字の英数字 |
| Gateway base URL | `https://<サーバーの IP アドレス>` |
| キー | 案件のキー（`sk-` で始まる文字列）。パスワードと同じように扱う |

### 1. ルート CA 証明書をインストールする

> [!IMPORTANT]
> インストールする前に、必ず拇印を照合してください。拇印が違う証明書は絶対にインストールしないでください。

```powershell
# 拇印を確認する（管理者から受け取った拇印と一致することを確認する）
(Get-PfxCertificate -FilePath .\ca.crt).Thumbprint

# 現在のユーザーにインストールする（確認ダイアログが表示される）
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```

Cowork で証明書のエラーが出る場合は、管理者権限の PowerShell で「ローカル コンピューター」にもインストールします。

```powershell
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

画面で操作する場合は、`ca.crt` をダブルクリック →「証明書のインストール」→ **信頼されたルート証明機関** に配置します。

ブラウザーを再起動して `https://<サーバーの IP アドレス>/health/liveliness` を開き、証明書の警告が出ずに `"I'm alive!"` と表示されれば成功です。

### 2. Claude Desktop を設定する

1. メニューの **Help → Troubleshooting → Enable Developer Mode** を有効にする。
2. **Developer → Configure Third-Party Inference** を開き、**Connection** に次の値を入力する。

| 項目 | 値 |
| --- | --- |
| Inference provider | Gateway |
| Gateway base URL | `https://<サーバーの IP アドレス>` |
| Credential kind | Static API key |
| Gateway API key | 受け取ったキー |
| Gateway auth scheme | Bearer |

3. **Allow Auto mode** を有効にする。
4. **Apply Changes** をクリックし、Claude Desktop を再起動する。
5. Cowork でタスクを開始し、応答が返ること、権限モードで **Automatically approve**（Auto モード）を選べることを確認する。

メニューの名前は、Claude Desktop のバージョンによって少し異なることがあります。

設定画面の **Export** で書き出した `.reg` ファイルを配布すれば、メンバーはダブルクリックで取り込めます。
`.reg` ファイルにはキーが含まれるため、案件のメンバーだけが読めるように渡してください。

## トラブルシューティング

まずサーバー上で `scripts/smoke-test.sh` を実行し、どの段階で失敗するかを確認します（[動作確認](#5-動作確認)）。

```sh
LITELLM_API_KEY=<確認したいキー> scripts/smoke-test.sh https://<サーバーの IP アドレス> --inference
docker compose ps
docker compose logs --tail=100 litellm nginx
```

| 症状 | 確認すること |
| --- | --- |
| `docker compose up` で `bind source path does not exist: .../certs/server.crt` | 証明書を作成してから起動する（[証明書の作成](#3-証明書の作成)） |
| イメージの取得で `toomanyrequests` | Docker Hub の未認証プルの回数制限。`docker login` してから再実行する |
| 推論で 500（`Unable to locate credentials`） | `.env` の AWS のアクセスキー |
| 推論で `permission_error` | IAM の権限と、Bedrock でモデルの利用を有効にしているか |
| 更新後に 502 | LiteLLM の起動待ち（`docker compose ps` で `healthy` か）。`docker compose restart nginx` |
| 管理 UI・管理 API が 403 | 接続元が `ADMIN_ALLOW_CIDRS` に含まれているか。nginx が見ている接続元は `docker compose logs nginx` の各行の先頭の IP アドレスで確認する |
| PC で接続できない、証明書のエラー | ブラウザーで `/health/liveliness` を開いて警告が出ないか。Claude Desktop を再起動したか。ローカル コンピューターのストアにも入れたか |
| 認証エラー（401） | キーが正しいか。キーが削除されていないか |
| 「モデルを利用できない」というエラー | 案件のチームでそのモデルが許可されているか |
| しばらく使った後にエラー（422 / Budget has been exceeded） | 案件の予算の上限に達している。チームの予算を引き上げる |
| Auto モードを選べない、操作が「安全性を判断できない」として止まる | Allow Auto mode が有効か。案件のチームで `claude-sonnet-5` が許可されているか |
