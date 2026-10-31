# 要件定義: Claude Cowork 連携対応 LiteLLM

- 最終更新: 2026-10-31
- ステータス: 確定（PoC で検証する項目は「4. PoC 検証項目」を参照）

## 1. 背景と目的

社内 PC で Claude Cowork（Claude Desktop）を、Claude の契約なしにサードパーティ推論（Gateway モード）で利用する。
推論は LiteLLM を経由させ、案件ごとにキーと予算上限を管理する。

既存の社内 LiteLLM は HTTP で公開されているため Claude Desktop に設定できず、Auto モードにも対応していない。
そのため、以下の要件を満たす LiteLLM を新規に構築する。

### 利用イメージ

1. 共用サーバーに LiteLLM を構築する。
2. 案件・用途ごとにキーを発行し、予算上限を設定する。
3. 各メンバーは割り当てられたキーを Claude Desktop に設定する。
4. 予算上限に達したら、そのキーは使えなくなる。

### スコープ

- 対象: Claude Desktop（Cowork / Code タブ）からの利用、および Claude 以外のモデルを含む汎用 LLM ゲートウェイとしての利用
- 対象外: SSO（OIDC / JWT）認証、LiteLLM の MCP ゲートウェイ機能、既存 LiteLLM の改修、外部サービスとの連携や有料ライセンスが前提の LiteLLM の機能（R7）

## 2. 確定事項

| 項目 | 決定内容 |
| --- | --- |
| 用途 | 汎用 LLM ゲートウェイ兼 Claude Cowork 用 |
| 構成 | docker-compose（LiteLLM / PostgreSQL / HTTPS 終端リバースプロキシ） |
| 接続先 | `https://<サーバー IP>`。証明書は自前のルート CA で発行し、SAN に IP アドレスを入れる |
| ルート CA の配布 | 各 PC への手動インストール |
| キーの単位 | 案件ごとにチーム（Team）を作り、チームにキーを 1 本発行して共有する。将来は同じチーム内でメンバーごとのキーに移行する |
| 予算 | チームの `max_budget`。期間の総額とし、`budget_duration` は設定しない（リセットしない） |
| AWS Bedrock | 主に us-east-1。IAM アクセスキーを `.env` に置く（任意。未設定でも LiteLLM は起動する）。AWS アカウントは 1 つ（全案件で共有） |
| Azure OpenAI | 案件ごとに別リソース。認証情報は管理 UI で登録する（DB に暗号化して保存。下記 R2 を参照） |
| モデル | 案件ごとに選べる。Bedrock / Azure OpenAI にデプロイできるモデルを幅広く提供する |
| ログ | プロンプトと応答の本文は保存しない（LiteLLM の既定値のまま）。利用ログ（日時・モデル・トークン数・金額）は残す |
| LiteLLM のバージョン | Auto モード要件（A1〜A2）を満たす安定版に固定する（構築時点: 1.106.6） |

## 3. 要件

### 3.1 基盤

| ID | 要件 |
| --- | --- |
| R1 | LiteLLM は docker-compose で定義した Docker コンテナとして構築する。 |
| R2 | 機密情報はコード・`docker-compose.yml`・`config.yaml` に書かない。<br>`.env` に置くもの: `LITELLM_MASTER_KEY`、`LITELLM_SALT_KEY`、DB のパスワード、AWS のアクセスキー。<br>Azure の認証情報は管理 UI で登録し、DB に暗号化して保存する（案件の追加時にコンテナの設定変更をなくすため）。<br>Git で管理するのは `.env.example` のみとする。 |
| R3 | LiteLLM のイメージはバージョンを固定し、更新手順を文書化する。 |
| R4 | `STORE_MODEL_IN_DB=True` とし、モデル・チーム・キー・予算を管理 UI で管理できるようにする。 |
| R5 | PostgreSQL と `.env` のバックアップ手順を用意する。`LITELLM_SALT_KEY` は一度決めたら変更しない（失うか変更すると、DB 内の認証情報を復号できなくなる）。 |
| R6 | LiteLLM から外部への通信は、推論の上流（Bedrock・Azure OpenAI）だけにする。料金表などは GitHub・docs.litellm.ai から取得せず、イメージに同梱されたものを使う。 |
| R7 | 使わない機能は無効にする。<br>- API ドキュメント（`/docs`・`/redoc`・`/openapi.json`）<br>- 外部サービスとの連携が前提の機能（Moyai、Lens）<br>- Auto Router（リクエストの難易度でモデルを振り分ける機能）<br>- Enterprise 機能（ライセンス `LITELLM_LICENSE` を設定しない）<br>LiteLLM 側に無効化の設定がない機能は、nginx で 404 にする（docs/adr/0004）。 |

### 3.2 運用（管理 UI だけで完結すること）

| 操作 | 方法 | コンテナ設定の変更 |
| --- | --- | --- |
| 案件の追加と予算設定 | チームを作成し、`max_budget` を設定する | 不要 |
| 共有キーの発行 | チームに所属するキーを 1 本発行する | 不要 |
| 個別キーへの移行 | 同じチームにメンバーごとのキーを追加し、共有キーを削除する。予算はチーム単位なので引き継がれる | 不要 |
| 案件ごとのモデル制限 | チームに許可するモデルを設定する | 不要 |
| モデルの追加（Azure を含む） | 管理 UI でモデルと認証情報を登録する | 不要 |
| 案件終了時の停止 | キーの有効期限を設定するか、キーを削除する | 不要 |

### 3.3 Claude Desktop / Cowork 接続

| ID | 要件 |
| --- | --- |
| C1 | HTTPS で公開する。サーバー証明書の SAN にサーバーの IP アドレスを含める。ルート CA は、Name Constraints で署名できる範囲を IP アドレス範囲に、Extended Key Usage で用途をサーバー認証に限定する（鍵の漏えい時の被害を抑えるため。docs/adr/0002）。 |
| C2 | `POST /v1/messages`（ストリーミング・tool use）と `GET /v1/models` が動作する。 |
| C3 | Claude モデルの `model_name` に `claude` または `anthropic` を含める（含まないとモデル一覧に表示されない）。 |
| C4 | リバースプロキシはレスポンスをバッファリングしない。タイムアウトは 10 分より長くする。 |
| C5 | `cache_control`（プロンプトキャッシュ）を上流まで渡す。 |
| C6 | 上流のエラー（ステータスコードとエラー本文）を書き換えずにクライアントへ返す。 |
| C7 | 一般の PC に公開するのは推論 API とヘルスチェックだけとする。管理 UI・管理 API・プロバイダーへのパススルーは、管理者の端末（`.env` の `ADMIN_ALLOW_CIDRS`）からだけ接続できるようにする。`ADMIN_ALLOW_CIDRS` は任意とし、空の場合は接続元を制限しない（マスターキーの認証のみ）。 |

### 3.4 Auto モード

| ID | 要件 |
| --- | --- |
| A1 | `claude-sonnet-5` というモデル名をそのまま受け付け、Bedrock の Sonnet 5（`us.` の推論プロファイル）に転送する。Auto モードの安全性分類器はこのモデル名でリクエストを送る。 |
| A2 | `anthropic-beta: context-1m-2025-08-07` ヘッダを受け付ける。 |
| A3 | Cowork を使う案件のチームには `claude-sonnet-5` を必ず許可する。分類器の利用料も案件の予算から引かれる。 |
| A4 | クライアントの設定で `autoModeEnabled: true` にする（未設定だと Cowork では Auto モードが提供されない）。 |

メインのモデルは、Sonnet 5 以降、Opus 4.7 以降、Haiku 5.5、または Fable である必要がある（Bedrock 経由の場合）。

### 3.5 モデル提供

| ID | 要件 |
| --- | --- |
| M1 | Bedrock: AWS 側でモデルの利用を有効にしたうえで登録する。Claude モデルは個別に登録する。 |
| M2 | Azure OpenAI: 案件のリソースごとにデプロイを登録する。`model_name` は `<案件名>-<モデル名>`（例: `projA-gpt-5`）とし、全体で一意にする。同じ名前で登録すると、異なる案件のリソース間で負荷分散されてしまうため。 |

### 3.6 クライアント配布

| ID | 要件 |
| --- | --- |
| D1 | ルート CA 証明書を Windows の「信頼されたルート証明機関」へ手動でインストールする手順書を用意する（ユーザーストアとコンピューターストアの両方）。 |
| D2 | Claude Desktop の設定（Gateway URL、キー、`autoModeEnabled` など）を Export（`.reg`）で作成し、配布する。共有キーの間は案件ごとに用意する。 |

## 4. PoC 検証項目

| ID | 検証内容 | 失敗時の対応 |
| --- | --- | --- |
| P1 | 自前 CA の証明書（SAN は IP アドレス）で、Claude Desktop と Cowork が接続できる | 証明書のストアや形式を見直す。社内 CA の利用を検討する |
| P2 | Cowork の Auto モードが動作する（A1・A2） | LiteLLM のバージョンやヘッダの転送設定を見直す |
| P3 | 2 回目以降のリクエストで `cache_read_input_tokens` が 0 より大きい | Bedrock への変換設定を見直す |
| P4 | 予算超過時のステータスコードと Claude Desktop での表示を確認する | `budget_exceeded_status_code` で 402 にできるかを検証する |
| P5 | 管理 UI で登録した Azure の認証情報で、モデルの追加と疎通ができる | 登録手順を見直す |
| P6 | エラーログにリクエスト本文が残るかを確認する | `disable_error_logs` を検討する |

## 5. 運用上の注意

- 予算は LiteLLM の料金表をもとにした見積額であり、AWS や Azure の実際の請求額とずれることがある。料金表にない新しいモデルは、単価を手動で設定する。
- 料金表はイメージに同梱されたものを使うため（R6）、LiteLLM を更新するまで新しくならない。
- LiteLLM v1.104.0 以降、予算超過時は HTTP 422 を返す。Claude Desktop では一般的なエラーとして表示される（429 だと約 3 分リトライし、`billing_error` 付きの 402 だと「Billing issue」として表示される）。
- サーバーの IP アドレスが変わった場合は、サーバー証明書を再発行する。新しい IP アドレスがルート CA の許可範囲内なら、PC への再配布は不要。範囲外なら、ルート CA を作り直して全 PC に配布し直す。
- Bedrock の `us.` 推論プロファイルは、US 内の複数リージョンで推論を処理する。
- 予算の上限チェックはリクエストの前に行われるため、上限の直前に始まったリクエストの分だけ利用額が上限を超えることがある。

## 6. 参考資料

- [LiteLLM: Claude Desktop / Cowork チュートリアル](https://docs.litellm.ai/docs/tutorials/claude_desktop_cowork)
- [LiteLLM: Claude Desktop（Virtual keys）](https://docs.litellm.ai/docs/proxy/client_setup/claude_desktop)
- [Claude Desktop on 3P: LLM gateway](https://claude.com/docs/third-party/claude-desktop/gateway)
- [Claude Desktop on 3P: Configuration reference（`autoModeEnabled` ほか）](https://claude.com/docs/third-party/claude-desktop/configuration)
- [Claude Code: Permission modes（Auto モードの要件）](https://code.claude.com/docs/en/permission-modes)
- [Claude Code: Enterprise network configuration（CA 証明書）](https://code.claude.com/docs/en/network-config)
- [LiteLLM: Model management（`STORE_MODEL_IN_DB`、認証情報）](https://docs.litellm.ai/docs/proxy/model_management)
- [LiteLLM: Team budgets](https://docs.litellm.ai/docs/proxy/team_budgets)
