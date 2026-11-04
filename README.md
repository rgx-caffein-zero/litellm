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

### 無効にしている機能

LiteLLM のうち、この構成で使わない機能は無効にしています。

| 機能 | 無効にする方法 | 結果 |
| --- | --- | --- |
| 料金表などの外部からの取得 | `docker-compose.yml` の `LITELLM_LOCAL_*` | GitHub・docs.litellm.ai に接続せず、イメージに同梱されたものを使う。外への通信は Bedrock と Azure だけになる |
| API ドキュメント | `docker-compose.yml` の `NO_DOCS`・`NO_REDOC`・`NO_OPENAPI` | `/docs`・`/redoc`・`/openapi.json` が 404 になる。管理 UI の API Reference の画面も使えなくなる |
| Moyai・Lens・Auto Router | `nginx/default.conf` で遮断（LiteLLM 側に無効化の設定がないため） | API が管理者の端末からも 404 になる。Moyai と Lens は管理 UI の画面も 404 になる。管理 UI のメニューには残る |
| Enterprise 機能 | ライセンス（`LITELLM_LICENSE`）を設定しない | 管理 UI に「Premium feature」と表示される機能は使えない。ライセンス確認の通信も発生しない |

同梱の料金表は、LiteLLM を更新したときに新しくなります。新しいモデルの料金が反映されない場合は、LiteLLM を更新してください（[LiteLLM を更新する](#litellm-を更新する)）。

| ファイル | 役割 |
| --- | --- |
| `docker-compose.yml` | 3 つのコンテナの定義 |
| `.env` | 機密情報（`.env.example` から作成。Git 管理外） |
| `litellm/config.yaml` | Claude Desktop 用の Claude モデルと全体設定 |
| `nginx/default.conf` | HTTPS 終端、プロキシ設定、アクセス制御 |
| `nginx/entrypoint/40-admin-allow.sh` | 起動時に `ADMIN_ALLOW_CIDRS` から管理系の許可リストを生成する |
| `scripts/certs/` | ルート CA とサーバー証明書の作成スクリプト |
| `scripts/smoke-test.sh` | 接続・モデル一覧・推論の確認スクリプト |
| `scripts/migration/` | 現行環境からの移行（DB のダンプとリストア）のスクリプト |
| `certs/` | ルート CA とサーバー証明書（スクリプトで作成。Git 管理外） |

## 構築

### 1. 前提条件

**サーバー**

- Linux、Docker Engine、Docker Compose v2、OpenSSL、Git、curl 7.76 以降
- 社内 PC から、サーバーの IP アドレスの 443 番ポートに接続できること
- サーバーから次の宛先へ HTTPS で接続できること（直接、またはプロキシ経由）
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

#### プロキシ環境の場合

プロキシがない環境では、この節の設定は不要です。プロキシは次の 3 か所で、それぞれ別に設定します。

| 通信 | 設定する場所 |
| --- | --- |
| LiteLLM コンテナから Bedrock・Azure へ | `.env` の `LITELLM_HTTP_PROXY`・`LITELLM_HTTPS_PROXY`・`LITELLM_NO_PROXY`（空ならプロキシを使わない） |
| イメージの取得（`docker compose pull` / `up`） | Docker デーモンの設定（下記）。`.env` の値は使われない |
| リポジトリの取得（`git clone` / `pull`） | `git config --global http.proxy http://<プロキシ>:<ポート>` |

Docker デーモンのプロキシは `/etc/docker/daemon.json` に設定し、`sudo systemctl restart docker` で反映します（Docker Engine 23.0 以降）。

```json
{
  "proxies": {
    "http-proxy": "http://<プロキシ>:<ポート>",
    "https-proxy": "http://<プロキシ>:<ポート>",
    "no-proxy": "localhost,127.0.0.1"
  }
}
```

サーバーのシェルに `https_proxy` などの環境変数が設定されている場合は、`no_proxy` にサーバー自身の IP アドレスを加えてください。
加えないと、`scripts/smoke-test.sh` や管理 API の `curl` がサーバーへの接続をプロキシに送ってしまいます。

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

### 現行環境から移行する

現行（移行元）の LiteLLM の DB を、この構成（移行先）にコピーします。チーム・キー・予算・利用額・管理 UI で登録したモデルと認証情報が引き継がれます。
移行元には書き込まず、停止も再起動もしません。DB のマイグレーションは、移行先の LiteLLM が起動時に移行先の DB だけに行います。
移行元 LiteLLM v1.83.14-stable.patch.3 / PostgreSQL 15 から、この構成（LiteLLM 1.106.6 / PostgreSQL 17.8）への移行で確認しています。

> [!WARNING]
> 移行先の LiteLLM の接続先（`DATABASE_URL`）を、移行元の DB にしないでください。起動時のマイグレーションで、移行元の DB が書き換わります。

**1. ダンプする（移行元のサーバー）**

`scripts/migration/dump-db.sh` だけを移行元のサーバーにコピーし、利用の少ない時間帯に実行します。

```sh
docker ps    # DB と LiteLLM のコンテナ名を確認する
./dump-db.sh --db-container <DB のコンテナ> --litellm-container <LiteLLM のコンテナ>
```

- `pg_dump` は読み取り専用で動き、LiteLLM の通常の読み書きを止めません。開始時にロックをすぐに取れなければ、待たずに失敗します。
- 出力先の空き容量が DB のサイズの 2 倍より少なければ中止します。足りない場合は `--output` で別のディスクを指定します。
- 利用ログ（管理 UI の Logs の履歴）が不要なら `--exclude-spend-logs` を付けます。チームとキーの利用額は別のテーブルにあるので、予算は引き継がれます。
- 最後に表示される**テーブルの件数と SHA-256** を、移行元の画面から直接控えます。

> [!WARNING]
> ダンプ中は、移行元の LiteLLM を再起動しないでください。pg_dump は終わるまで全テーブルのロックを持ち続けるため、起動時のマイグレーションがロックを待ち、その後ろにリクエストが並んで**移行元が応答しなくなります**。
> 応答しなくなったら、すぐに Ctrl-C で中断してください（移行元の DB で動いている pg_dump も終了させます）。中断時に警告が出た場合は、次の結果が 0 であることを確認します。
>
> ```sh
> docker exec <DB のコンテナ> psql -U <DB のユーザー> -d <DB 名> -Atc \
>   "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'litellm-migration-dump-%'"
> ```

**2. ソルトキーを合わせる（移行先）**

手順 1 の「LITELLM_SALT_KEY の設定」の表示に従って、移行先の `.env` の `LITELLM_SALT_KEY` を設定します。違う値にすると、管理 UI で登録した認証情報を復号できません。

| 移行元の LITELLM_SALT_KEY | 移行先の LITELLM_SALT_KEY に設定する値 |
| --- | --- |
| 設定あり | 移行元の `LITELLM_SALT_KEY` と同じ値 |
| 設定なし | 移行元の `LITELLM_MASTER_KEY` の値（ソルトキーがない場合、LiteLLM はマスターキーで暗号化するため） |

確認するのはコンテナの環境変数だけです。移行元の `config.yaml` の `environment_variables` でソルトキーを設定している場合は、その値を使ってください。
`LITELLM_MASTER_KEY` は移行元と違っても構いません（キーはハッシュで保存されているため、移行元で発行したキーはそのまま使えます）。

**3. リストアする（移行先のサーバー）**

ダンプを scp などの暗号化された経路で移行先にコピーし、リポジトリのディレクトリで実行します。**移行先の DB の内容はすべて削除されます。**

```sh
chmod 600 <ダンプファイル>
scripts/migration/restore-db.sh <ダンプファイル> --sha256 <手順 1 で控えた SHA-256>
```

- SHA-256 が一致しなければ、何もせずに終了します。リストアは DB の管理者の権限で行うので、差し替えられたダンプを入れると DB のコンテナで任意の処理が動きます。SHA-256 はダンプと同じ経路（同じフォルダやメールなど）で受け渡さないでください。
- 同じプロジェクト名のコンテナが別のディレクトリにある場合や、同じプロジェクト名のボリュームだけが残っている場合は、別の環境を消さないよう中止します。中止された場合は `COMPOSE_PROJECT_NAME=<別の名前>` を付けて実行します。docker の接続先（`DOCKER_HOST`・`docker context`）は切り替えずに実行してください。
- 終了後、LiteLLM と nginx は停止したままです。表示を見て、次を確認します。
  - テーブルの件数が、手順 1 の表示と同じである。
  - DB に保存された設定に通知（Slack・メールなど）やコールバックがあれば、移行先からも送られる。不要なら、起動後に管理 UI で無効にする。
  - モデル名の重複があれば、起動後に管理 UI で DB 側のモデルを削除する（同じ名前のモデルの間で負荷分散されるため）。

**4. 起動して確認する（移行先）**

`.env` を変更したので、新しいシェルで実行します。

```sh
docker compose up -d --wait
docker compose logs litellm | grep -i -E 'migrat|error'
set -a; . ./.env; set +a
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP アドレス>
```

管理 UI で、チーム・キー・モデルが移行元と同じであること、Azure のモデルを開いてエラーにならないことを確認します。

LiteLLM が起動しない（`container litellm-litellm-1 is unhealthy`）場合は、新しいシェルで次を実行します。
パスワードなどの値は表示せず、DB に認証できるかと、マイグレーションの状態だけを表示します。

```sh
docker compose stop litellm    # 失敗と再起動の繰り返しを止める
scripts/migration/check-db.sh
```

ログに Prisma の `P1000` が出る場合は、DB のパスワードの不一致です。DB のパスワードは初回の起動時にしか設定されないため、その後 `.env` の `POSTGRES_PASSWORD` を変える（現行環境の値にするなど）と一致しなくなります。
`scripts/migration/check-db.sh --fix-password` で、DB のパスワードを `.env` に合わせられます（DB のデータは変わりません）。

**5. マスターキーとソルトキーを変える（移行元のマスターキーが `sk-1234` などの場合）**

LiteLLM は、マスターキーが公開されている値（ドキュメントの例の `sk-1234`）だと起動を拒否します（ログに `LiteLLM proxy refused to start` が出ます）。
マスターキーは、`.env` の `LITELLM_MASTER_KEY` を新しい値に変えるだけで構いません。

移行元が `LITELLM_SALT_KEY` を設定していなかった場合、手順 2 のとおりソルトキーも同じ公開されている値になり、DB の認証情報を誰でも復号できてしまいます。
次の手順で、認証情報を新しいソルトキーで暗号化し直してください（LiteLLM は止めたままになります）。

```sh
printf 'sk-%s\n' "$(openssl rand -hex 32)"    # 新しいソルトキーを作り、.env の LITELLM_SALT_KEY に設定する
scripts/migration/rotate-salt-key.sh         # 古いソルトキー（移行元のマスターキー）の入力を求められる
docker compose up -d --wait                   # 新しいシェルで実行する
```

- 暗号化し直す処理と対象の列は、LiteLLM 自身の処理をそのまま使います。1 つのトランザクションで行い、古いソルトキーで暗号化された値が 0 件になったことを確かめてからコミットします。確かめられなければ、何も変えません。
- LiteLLM が起動に失敗していても実行できます（リストア済みのコンテナがあれば、処理は LiteLLM のイメージから作る一時的なコンテナで行います）。
- 「古いソルトキーで暗号化された値はありません」と表示された場合、DB は変わっていません。`scripts/migration/rotate-salt-key.sh --check` で、暗号化された値の件数と、候補の鍵（移行元の環境変数と設定ファイルのマスターキーなど）それぞれで復号できる件数を確かめます。
  - 暗号化された値が 0 件なら、暗号化し直すものはありません。新しいソルトキーのまま起動します。
  - ある候補で復号できた件数が、暗号化された値の件数と同じなら、その候補が古いソルトキーです。
  - 移行元の LiteLLM は、設定ファイルの `general_settings.master_key` があれば、環境変数の `LITELLM_MASTER_KEY` よりそちらを使います。
- 終わったら、新しいソルトキーを含む `.env` をバックアップします。これより前の DB のバックアップは、古いソルトキーでないと復号できません。

**注意点**

- 移行先には移行元と同じキーが入り、移行元のキーで移行先も使えます。切り替えるまでは、移行先を利用者に案内しないでください。
- 移行先から推論すると、移行元と同じ AWS・Azure の認証情報を使います（クォータと請求は共有です）。
- コピーは実行した時点のものです。本番を切り替えるときは、移行元の利用を止めてから、手順 1 からやり直します。
- 移行元の `config.yaml` に書いたモデルは DB にないため移行されません。必要なら管理 UI で登録します。
- ダンプにはキーのハッシュや暗号化された認証情報が含まれます。移行が終わったら、移行元と移行先の両方で削除してください。

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
| イメージの取得がタイムアウトする | プロキシ環境では Docker デーモンのプロキシ設定（[プロキシ環境の場合](#プロキシ環境の場合)） |
| 推論がタイムアウトする、接続できない | プロキシ環境では `.env` の `LITELLM_HTTPS_PROXY`。変更後は `docker compose up -d --wait litellm` で反映する |
| `smoke-test.sh` がサーバーに接続できない | シェルの `https_proxy` が設定されている場合は、`no_proxy` にサーバーの IP アドレスを加える |
| 推論で 500（`Unable to locate credentials`） | `.env` の AWS のアクセスキー |
| 推論で `permission_error` | IAM の権限と、Bedrock でモデルの利用を有効にしているか |
| 更新後に 502 | LiteLLM の起動待ち（`docker compose ps` で `healthy` か）。`docker compose restart nginx` |
| 管理 UI・管理 API が 403 | 接続元が `ADMIN_ALLOW_CIDRS` に含まれているか。nginx が見ている接続元は `docker compose logs nginx` の各行の先頭の IP アドレスで確認する |
| PC で接続できない、証明書のエラー | ブラウザーで `/health/liveliness` を開いて警告が出ないか。Claude Desktop を再起動したか。ローカル コンピューターのストアにも入れたか |
| 認証エラー（401） | キーが正しいか。キーが削除されていないか |
| 「モデルを利用できない」というエラー | 案件のチームでそのモデルが許可されているか |
| しばらく使った後にエラー（422 / Budget has been exceeded） | 案件の予算の上限に達している。チームの予算を引き上げる |
| Auto モードを選べない、操作が「安全性を判断できない」として止まる | Allow Auto mode が有効か。案件のチームで `claude-sonnet-5` が許可されているか |
