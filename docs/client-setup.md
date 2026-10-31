# 社内 PC の設定手順（Claude Desktop / Cowork）

各メンバーの Windows PC で、LiteLLM 経由の Claude Desktop / Cowork を使えるようにする手順です。

## 管理者から受け取るもの

| もの | 内容 |
| --- | --- |
| ルート CA 証明書 | `ca.crt`（LiteLLM サーバーの証明書を信頼するために使う） |
| ルート CA の拇印（SHA-1） | `ca.crt` が本物かを確認するための 40 文字の英数字 |
| Gateway base URL | `https://<サーバーの IP アドレス>` |
| キー | 案件のキー（`sk-` で始まる文字列） |

キーはパスワードと同じように扱ってください。チャットやメールに貼り付けたり、他の人に渡したりしないでください。

## 1. ルート CA 証明書をインストールする

LiteLLM サーバーの証明書は社内で発行したものです。PC に信頼させるため、ルート CA 証明書をインストールします。

> [!IMPORTANT]
> インストールする前に、必ず拇印を照合してください。拇印が違う証明書は絶対にインストールしないでください。
> 偽の証明書を入れると、通信を盗聴されるおそれがあります。

### 方法 A: 画面で操作する

1. `ca.crt` をダブルクリックし、「証明書のインストール」をクリックする。
2. 保存場所を選び、「次へ」をクリックする。
   - 「現在のユーザー」: 自分のアカウントだけで信頼する。管理者権限は不要。
   - 「ローカル コンピューター」: PC のすべてのアカウントで信頼する。管理者権限が必要。
   - どちらが必要かは PoC（Claude Desktop の Cowork が参照するストア）で確認します。まずは「現在のユーザー」で試し、Cowork で証明書のエラーが出る場合は「ローカル コンピューター」に入れてください。
3. 「証明書をすべて次のストアに配置する」を選び、「参照」から **信頼されたルート証明機関** を選ぶ。
4. 「次へ」→「完了」をクリックする。
5. セキュリティ警告が表示されたら、**表示された拇印が管理者から受け取った拇印と一致することを確認してから**「はい」をクリックする。

### 方法 B: PowerShell で操作する

```powershell
# 拇印を確認する（管理者から受け取った拇印と一致することを確認する）
(Get-PfxCertificate -FilePath .\ca.crt).Thumbprint

# 現在のユーザーにインストールする（確認ダイアログが表示される）
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```

PC のすべてのユーザーにインストールする場合（ローカル コンピューター）は、管理者権限の PowerShell で実行します。

```powershell
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

### 確認

ブラウザーで `https://<サーバーの IP アドレス>/health/liveliness` を開きます。
証明書の警告が出ずに `"I'm alive!"` と表示されれば成功です。インストールの直後は、ブラウザーを再起動してから確認してください。

## 2. Claude Desktop を設定する

### 管理者が配布した設定ファイル（`.reg`）がある場合

ダブルクリックして取り込み、Claude Desktop を再起動します。手順 3 に進んでください。

### 手動で設定する場合

1. Claude Desktop のメニューから **Help → Troubleshooting → Enable Developer Mode** を有効にする。
2. **Developer → Configure Third-Party Inference** を開く。
3. **Connection** に次の値を入力する。

| 項目 | 値 |
| --- | --- |
| Inference provider | Gateway |
| Gateway base URL | `https://<サーバーの IP アドレス>` |
| Credential kind | Static API key |
| Gateway API key | 受け取ったキー |
| Gateway auth scheme | Bearer |

4. **Allow Auto mode**（Cowork で Auto モードを使えるようにする設定）を有効にする。
5. **Apply Changes** をクリックし、Claude Desktop を再起動する。

メニューの名前は、Claude Desktop のバージョンによって少し異なることがあります。

## 3. 動作を確認する

1. Cowork でタスクを開始し、応答が返ることを確認する。
2. モデルの選択肢に、案件で許可された Claude モデルが表示されることを確認する。
3. 権限モードで **Automatically approve**（Auto モード）を選べることを確認する。

## うまくいかないとき

| 症状 | 確認すること |
| --- | --- |
| 接続できない、証明書のエラーが出る | 手順 1 の確認でブラウザーに警告が出ないか。Claude Desktop を再起動したか |
| 認証エラー（401） | キーが正しいか。キーが削除されていないか（管理者に確認） |
| 「モデルを利用できない」というエラー | 案件のチームでそのモデルが許可されているか（管理者に確認） |
| しばらく使った後にエラー（422 / Budget has been exceeded） | 案件の予算の上限に達しています。管理者に予算の引き上げを相談してください |
| Auto モードを選べない、操作が「安全性を判断できない」として止まる | Allow Auto mode が有効か。案件のチームで `claude-sonnet-5` が許可されているか（管理者に確認） |

## 管理者向け: 設定ファイル（`.reg`）の配布

1. 自分の PC で、上の「手動で設定する場合」の手順どおりに設定する（キーは配布先の案件のもの）。
2. 設定画面の **Export** で `.reg` ファイルを書き出す。
3. 案件のメンバーに、ルート CA 証明書・拇印と一緒に渡す。

`.reg` ファイルにはキーが含まれます。共有フォルダーに置く場合は、案件のメンバーだけが読めるようにしてください。
