# 構築手順

共用サーバーに LiteLLM を構築し、Claude Desktop / Cowork から HTTPS で接続できる状態にするまでの手順です。
要件は [requirements.md](requirements.md)、構築後の運用は [operations.md](operations.md) を参照してください。

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
nginx は、一般の PC には推論 API とヘルスチェックだけを公開し、管理 UI・管理 API は管理者の端末（`.env` の `ADMIN_ALLOW_CIDRS`）からだけ受け付けます（`ADMIN_ALLOW_CIDRS` が空の場合は制限しません）。
使わない LiteLLM の機能（API ドキュメント、Moyai、Lens、Auto Router）は無効にしており、管理者の端末からも使えません（[requirements.md](requirements.md) の R6・R7）。

| ファイル | 役割 |
| --- | --- |
| `docker-compose.yml` | 3 つのコンテナの定義 |
| `.env` | 機密情報（`.env.example` から作成。Git 管理外） |
| `litellm/config.yaml` | Claude Desktop 用の Claude モデルと全体設定 |
| `nginx/default.conf` | HTTPS 終端、プロキシ設定、アクセス制御 |
| `nginx/entrypoint/40-admin-allow.sh` | 起動時に `ADMIN_ALLOW_CIDRS` から管理系の許可リストを生成する |
| `certs/` | ルート CA とサーバー証明書（スクリプトで作成。Git 管理外） |

## 1. 前提条件

### サーバー

- Linux、Docker Engine、Docker Compose v2、OpenSSL、Git、curl 7.76 以降（`scripts/smoke-test.sh` が `--fail-with-body` を使う）
- 社内 PC から、サーバーの IP アドレスの 443 番ポートに接続できること
- サーバーから次の宛先へ HTTPS で接続できること
  - `bedrock-runtime.us-east-1.amazonaws.com`（と、US 推論プロファイルが使う US の各リージョン）
  - 案件の Azure OpenAI リソースのエンドポイント
  - コンテナイメージの取得元: `ghcr.io`、Docker Hub

### AWS

1. us-east-1 の Bedrock コンソールで、使う Claude モデルの利用を有効にする。
   少なくとも **Claude Sonnet 5** は必須です（Auto モードの安全性分類器が使う）。
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

US 推論プロファイル（`us.anthropic.*`）は、US 内の複数リージョンにリクエストを振り分けます。
そのため、`foundation-model` のリージョンは `*` にしています。

## 2. リポジトリの取得

```sh
git clone <このリポジトリの URL> litellm
cd litellm
```

## 3. `.env` の作成

```sh
cp .env.example .env
chmod 600 .env
```

`.env` を編集して値を設定します。ランダムな値は次のように生成できます。

```sh
printf 'sk-%s\n' "$(openssl rand -hex 32)"   # LITELLM_MASTER_KEY、LITELLM_SALT_KEY
openssl rand -hex 24                         # POSTGRES_PASSWORD
```

`AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` は任意です。空でも LiteLLM は起動しますが、Bedrock のモデル（`litellm/config.yaml` の Claude モデルを含む）へのリクエストは 500 エラー（`Unable to locate credentials`）になります。

`ADMIN_ALLOW_CIDRS` には、管理 UI・管理 API を使う端末の IP 範囲を空白区切りで指定します（任意。設定を推奨）。
サーバー上で管理 API を使う場合（[operations.md](operations.md)）は、サーバー自身の IP アドレスも含めます。
空の場合は接続元を制限せず、すべての PC から管理 UI・管理 API に届きます（マスターキーの認証だけで守られます。nginx の起動時に警告を出します）。
値に数字・ドット・スラッシュ以外が含まれている場合や、全開放（`/0`）を指定した場合は、nginx は起動しません。

> [!WARNING]
> Docker のブリッジネットワークの範囲（`172.16.0.0/12` など）は `ADMIN_ALLOW_CIDRS` に入れないでください。
> Docker の構成によっては、外部からの接続元がブリッジのゲートウェイ（例: `172.18.0.1`）に見えることがあり、その場合はすべての PC が管理系に届いてしまいます。
> 管理 API が 403 になるときは、nginx が見ている接続元を `docker compose logs nginx` の各行の先頭の IP アドレスで確認し、管理者の端末の実際の IP アドレスが表示されていることを確かめてから、その IP アドレスを追加してください。

```sh
ADMIN_ALLOW_CIDRS="10.1.5.0/24 10.1.2.3/32"
```

> [!IMPORTANT]
> `LITELLM_SALT_KEY` は、管理 UI で登録した Azure の API キーなどを暗号化する鍵です。
> **一度設定したら変更しないでください。** 変更・紛失すると、登録済みの認証情報を復号できなくなります。
> `.env` は作成した時点で、サーバー以外の安全な場所にもバックアップしてください。

## 4. 証明書の作成

### 4.1 ルート CA の作成

```sh
scripts/certs/create-ca.sh <許可する IP 範囲>
```

`<許可する IP 範囲>` は、このルート CA が証明書を発行できる IP アドレスの範囲です（CIDR 表記）。

| 指定例 | 意味 | サーバーの IP が変わったとき |
| --- | --- | --- |
| `10.1.2.3/32` | サーバーの IP だけ（最も安全） | ルート CA を作り直し、全 PC に配布し直す |
| `10.1.2.0/24` | サーバーが属するサブネット | 範囲内なら、サーバー証明書の再発行だけで済む |

このルート CA は社内 PC に「信頼されたルート証明機関」として入れます。
秘密鍵が漏れたときの被害を抑えるため、CA 証明書に次の制限を入れています（[ADR 0002](adr/0002-self-signed-root-ca-with-constraints.md)）。

- 用途はサーバー認証だけ（Extended Key Usage）。コード署名や S/MIME（メールの署名）の証明書は、この CA の下では信頼されない。
- 発行できるのは指定した範囲の IP アドレスだけ（Name Constraints）。一般の Web サイト（DNS 名）やメールアドレスの証明書は発行できない。

範囲は `/8` より広くできず、ホスト部は 0 にします（`10.1.2.3/24` ではなく `10.1.2.0/24`）。

出力された **拇印（SHA-1）** を控えておきます。各 PC でインストールするときに照合します。

### 4.2 サーバー証明書の発行

```sh
scripts/certs/issue-server-cert.sh <サーバーの IP アドレス>
```

`certs/server.crt` と `certs/server.key` が作成されます。有効期間は 825 日です。

`<サーバーの IP アドレス>` には、社内 PC が接続に使う IP アドレス（Gateway base URL に書く IP アドレス）を指定します。
`127.0.0.1` で発行した証明書は、サーバー自身からの接続でしか使えません（他の PC からは名前が一致せず、証明書のエラーになります）。
`localhost` のような名前は指定できません（IP アドレスだけを受け付けます）。

証明書を作る前に `docker compose up` を実行すると、`bind source path does not exist: .../certs/server.crt` のエラーで nginx が起動しません。証明書を作成してから起動してください。

### 4.3 ルート CA の秘密鍵の退避

サーバー証明書を発行したら、`certs/ca/ca.key` をサーバーから外し、アクセスを制限した安全な場所で保管します。
次にサーバー証明書を更新するときだけ、一時的に戻して使います。

```sh
# 例: 管理者の端末にコピーしてから、サーバー上のファイルを削除する
scp <サーバー>:litellm/certs/ca/ca.key ./litellm-ca.key
ssh <サーバー> 'shred -u litellm/certs/ca/ca.key'
```

## 5. 起動

```sh
docker compose up -d --wait
docker compose ps
```

`--wait` は、すべてのコンテナが起動し、`litellm` と `db` が `healthy` になるまで待ちます。
初回は DB のマイグレーションがあるため、1〜2 分かかります。

> [!NOTE]
> イメージの取得で `toomanyrequests` が出た場合は、Docker Hub の未認証プルの回数制限です。
> `docker login` してから再度実行してください。

## 6. 動作確認

### 6.1 HTTPS とモデル一覧（課金なし）

```sh
set -a; . ./.env; set +a
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP アドレス>
```

### 6.2 Bedrock への推論（少額の課金あり）

```sh
LITELLM_API_KEY="$LITELLM_MASTER_KEY" scripts/smoke-test.sh https://<サーバーの IP アドレス> --inference
```

イベントが少しずつ表示されれば、ストリーミングがバッファリングされずに届いています（要件 C4）。
`permission_error` が返る場合は、IAM の権限と、Bedrock でモデルの利用を有効にしているかを確認してください。

### 6.3 管理 UI

ブラウザーで `https://<サーバーの IP アドレス>/ui` を開き、ユーザー名 `admin`、パスワードにマスターキーを入力してログインします。
ブラウザーで証明書の警告が出ないようにするには、管理者の PC にもルート CA を入れます（[client-setup.md](client-setup.md)）。

## 7. PoC での確認

構築後、[requirements.md の「PoC 検証項目」](requirements.md#4-poc-検証項目)を実際の Claude Desktop で確認します。

| ID | 確認方法 |
| --- | --- |
| P0 | `litellm/config.yaml` の 4 つのモデル ID（`us.anthropic.claude-*`）が Bedrock で実在し、呼び出せる。構築時は AWS に接続せずに確認したため未検証。Claude Desktop のモデル選択で各モデルを選び、応答が返ることを確認する |
| P1 | [client-setup.md](client-setup.md) の手順で PC を設定し、Cowork でタスクを開始できる |
| P2 | Cowork で「Automatically approve（Auto モード）」を選び、ファイル操作などが確認なしで進む。LiteLLM の Logs に `claude-sonnet-5` へのリクエスト（安全性分類器）が記録される |
| P3 | 同じ Cowork セッションで数往復した後、Logs の各リクエストでキャッシュ読み取りのトークン数が 0 より大きい |
| P4 | 予算を小さくしたテスト用チームで上限まで使い、Claude Desktop での表示を確認する |
| P5 | Azure のモデルを管理 UI で追加し（[operations.md](operations.md#azure-openai-のモデルを追加する)）、チームのキーで呼び出せる |
| P6 | 存在しないモデル名などでエラーを起こし、管理 UI の Logs にリクエスト本文が表示されないことを確認する |

構築時にローカル環境で確認済みの内容は、[operations.md の「検証済みの動作」](operations.md#検証済みの動作)にまとめています。
