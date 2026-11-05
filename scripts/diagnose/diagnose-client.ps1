<#
.SYNOPSIS
  Claude Desktop / Cowork から LiteLLM へのリクエストが失敗するときに、社内 PC 側の原因を調べる。

.DESCRIPTION
  社内 PC（Windows）の PowerShell で実行する。サーバー側の確認は scripts/diagnose/diagnose-server.sh。

  確かめること:
    1. Gateway base URL の形
    2. Claude Desktop の状態と、レジストリに保存された設定
    3. サーバーの 443 番ポートに届くか
    4. プロキシ（Claude Desktop はシステムのプロキシ設定に従う）
    5. サーバー証明書と、ルート CA のインストール
    6. ヘルスチェック、キー、モデル一覧（-Inference で推論も）
    7. Claude Desktop のログのエラー

  何も変更しない。キーは表示しない（ログに含まれる sk-... も伏せる）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\diagnose\diagnose-client.ps1 -BaseUrl https://10.1.2.3
#>
param(
    # Claude Desktop に設定した Gateway base URL（例: https://10.1.2.3）
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    # 管理者から受け取ったルート CA 証明書（ca.crt）のパス。任意
    [string]$CaCert,
    # 管理者から受け取ったルート CA の拇印（SHA-1、40 文字）。任意
    [string]$Thumbprint,
    # claude-sonnet-5 に短い推論を送る（少額の利用料が発生する）
    [switch]$Inference,
    # Claude Desktop のログを調べる期間（時間）
    [int]$LogHours = 24
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RequiredModel = 'claude-sonnet-5'
$script:Problems = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$Title) { Write-Host ''; Write-Host "== $Title" }
function Write-Ok([string]$Message) { Write-Host "  OK   $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "  注意 $Message" -ForegroundColor Yellow }
function Write-Info([string]$Message) { Write-Host "       $Message" }
function Write-Ng([string]$Message, [string]$Hint) {
    Write-Host "  NG   $Message" -ForegroundColor Red
    if ($Hint) {
        Write-Host "       → $Hint"
        $script:Problems.Add("$Message → $Hint")
    } else {
        $script:Problems.Add($Message)
    }
}

# キーやトークンを伏せる
function Hide-Secret([string]$Text) {
    $Text = $Text -replace 'sk-[A-Za-z0-9_\-]+', 'sk-***'
    $Text = $Text -replace '(?i)(bearer\s+)\S+', '$1***'
    $Text = $Text -replace '://[^/@\s]*@', '://***@'
    return $Text
}

function Limit-Length([string]$Text, [int]$Max) {
    if ($Text.Length -gt $Max) { return $Text.Substring(0, $Max) + '...' }
    return $Text
}

# HTTP ステータスから考えられる原因を返す
function Get-StatusHint([int]$Status) {
    switch ($Status) {
        400 { return 'リクエストの内容を LiteLLM が受け付けていない。サーバーで diagnose-server.sh を実行して LiteLLM のエラーを確認する' }
        401 { return 'キーが無効（違う・削除済み・期限切れ）か、キーのチームにそのモデルが許可されていない。管理者にキーを確認してもらう' }
        403 { return 'nginx が遮断している。Gateway base URL の末尾に /v1 などのパスを付けていないか確認する' }
        404 { return 'パスかモデル名が違う。Gateway base URL の末尾にパスを付けていないか確認する' }
        422 { return '案件の予算の上限に達している。管理者に予算の引き上げを依頼する' }
        429 { return 'レート制限。しばらく待ってから再実行する' }
        500 { return 'サーバー（LiteLLM か Bedrock）のエラー。サーバーで diagnose-server.sh を実行する' }
        502 { return 'nginx が LiteLLM に接続できない。サーバーで docker compose ps を確認する' }
        504 { return 'サーバーの応答がタイムアウトした' }
        default { return '' }
    }
}

# HTTP リクエストを送り、ステータスと本文を返す。$Proxy が $null なら直接接続する
function Invoke-Http([string]$Method, [string]$Url, [string]$Key, [string]$Body, $Proxy, [int]$TimeoutSec = 30) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Proxy = $Proxy
    if ($Key) { $request.Headers.Add('Authorization', "Bearer $Key") }
    if ($Body) {
        $request.ContentType = 'application/json'
        $request.Headers.Add('anthropic-version', '2023-06-01')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            return @{ Status = 0; Body = ''; Error = "$($_.Exception.Status): $($inner.Message)" }
        }
    }
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $status = [int]$response.StatusCode
    $response.Close()
    return @{ Status = $status; Body = $text; Error = '' }
}

function Test-BaseUrl {
    Write-Step '1. Gateway base URL'
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri)) {
        Write-Ng "URL として解釈できません: $BaseUrl" 'https://<サーバーの IP アドレス> の形で指定する'
        return $null
    }
    $problemsBefore = $script:Problems.Count
    if ($uri.Scheme -ne 'https') {
        Write-Ng "https ではありません: $BaseUrl" 'https://<サーバーの IP アドレス> にする'
    }
    if ($uri.AbsolutePath -ne '/') {
        Write-Ng "末尾にパス（$($uri.AbsolutePath)）があります" 'Gateway base URL は https://<サーバーの IP アドレス> だけにする（/v1 などを付けると、推論 API ではないパスとして nginx に遮断される）'
    }
    if ($uri.HostNameType -ne [UriHostNameType]::IPv4) {
        Write-Note "ホスト名（$($uri.Host)）です。サーバー証明書は IP アドレスで発行しているため、IP アドレスで指定してください"
    } elseif ($script:Problems.Count -eq $problemsBefore) {
        Write-Ok "$($uri.Scheme)://$($uri.Authority)"
    }
    return $uri
}

function Test-ClaudeDesktop([Uri]$Uri) {
    Write-Step '2. Claude Desktop'
    $process = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    if ($process) {
        $started = ($process | Sort-Object StartTime | Select-Object -First 1).StartTime
        Write-Ok "起動しています（起動 $($started.ToString('yyyy-MM-dd HH:mm'))）"
        Write-Info '設定を変えた後に再起動していなければ、Claude Desktop を終了して起動し直してください（タスクトレイのアイコンからも終了する）'
    } else {
        Write-Note '起動していません'
    }

    # 設定の保存先はバージョンによって違うため、名前に Claude・Anthropic を含むキーを探す
    $roots = 'HKCU:\Software\Policies', 'HKLM:\SOFTWARE\Policies', 'HKCU:\Software', 'HKLM:\SOFTWARE'
    $found = $false
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'Claude|Anthropic' })) {
            foreach ($item in @($key) + @(Get-ChildItem $key.PSPath -Recurse -ErrorAction SilentlyContinue)) {
                $properties = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
                if (-not $properties) { continue }
                foreach ($property in $properties.PSObject.Properties) {
                    if ($property.Name -match '^PS') { continue }
                    if (-not $found) { Write-Info 'レジストリの設定:'; $found = $true }
                    $value = "$($property.Value)"
                    if ($property.Name -match '(?i)key|token|secret|password|credential') {
                        $shown = if ($value) { "（設定あり、$($value.Length) 文字。値は表示しない）" } else { '（空）' }
                    } else {
                        $shown = Limit-Length (Hide-Secret $value) 120
                    }
                    Write-Info "  $($item.Name -replace '^HKEY_CURRENT_USER', 'HKCU' -replace '^HKEY_LOCAL_MACHINE', 'HKLM') : $($property.Name) = $shown"
                    if ($value -match '^https?://') { $urls.Add($value) }
                }
            }
        }
    }
    if (-not $found) {
        Write-Note 'レジストリに Claude の設定が見つかりませんでした（Configure Third-Party Inference で Apply Changes を押したか確認してください）'
    }
    $expected = "$($Uri.Scheme)://$($Uri.Authority)"
    foreach ($url in $urls) {
        if ($url.TrimEnd('/') -ne $expected -and $url -match [regex]::Escape($Uri.Host)) {
            Write-Ng "レジストリの URL（$url）が、指定した Gateway base URL（$expected）と違います" '末尾の / やパス、ポート番号を揃える'
        }
    }
}

function Test-Tcp([Uri]$Uri) {
    Write-Step "3. サーバーへの接続（$($Uri.Host):$($Uri.Port)、プロキシを通さない）"
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Uri.Host, $Uri.Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(5000) -and $client.Connected) {
            $client.EndConnect($async)
            Write-Ok '接続できます'
            return $true
        }
        Write-Ng '接続できません（タイムアウト）' 'IP アドレスが正しいか、サーバーと途中のファイアウォールで 443 番が許可されているか。サーバーが WSL で動いている場合は、Windows 側のポート転送（ミラーモードか netsh portproxy）が必要'
    } catch {
        Write-Ng "接続できません（$($_.Exception.Message)）" 'IP アドレスが正しいか、サーバーで nginx が動いているか（docker compose ps）'
    } finally {
        $client.Close()
    }
    return $false
}

function Test-Proxy([Uri]$Uri) {
    Write-Step '4. プロキシ'
    $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if ($systemProxy.IsBypassed($Uri)) {
        Write-Ok 'システムのプロキシ設定では、サーバーへは直接接続します'
    } else {
        $proxyUri = $systemProxy.GetProxy($Uri)
        Write-Note "システムのプロキシ設定では、サーバーへの接続がプロキシ（$(Hide-Secret $proxyUri.Authority)）を経由します"
        Write-Info 'Claude Desktop もこのプロキシを経由します。手順 6 で失敗する場合は、プロキシの例外にサーバーの IP アドレスを加えてください（設定 → ネットワークとインターネット → プロキシ、または社内の PAC ファイル）'
    }
    foreach ($name in 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { Write-Info "環境変数 $name = $(Hide-Secret $value)" }
    }
    $winhttp = (netsh winhttp show proxy 2>$null) -join ' '
    Write-Info "WinHTTP: $(($winhttp -replace '\s+', ' ').Trim())"
    return $systemProxy
}

function Find-RootCertificate([string]$Thumb) {
    $result = @{}
    foreach ($store in 'CurrentUser', 'LocalMachine') {
        $result[$store] = [bool](Get-ChildItem "Cert:\$store\Root" -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Thumb })
    }
    return $result
}

function Test-Certificate([Uri]$Uri) {
    Write-Step '5. サーバー証明書とルート CA'
    # 期待するルート CA の拇印（-Thumbprint か -CaCert から）
    $expected = $null
    if ($Thumbprint) { $expected = ($Thumbprint -replace '[\s:]', '').ToUpper() }
    if ($CaCert) {
        if (Test-Path $CaCert) {
            $fileThumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path $CaCert).Path)).Thumbprint
            Write-Info "ca.crt の拇印: $fileThumb"
            if ($expected -and $expected -ne $fileThumb) {
                Write-Ng 'ca.crt の拇印が、指定した拇印と違います' '管理者から正しい ca.crt を受け取り直す。拇印が違う証明書はインストールしない'
            }
            $expected = $fileThumb
        } else {
            Write-Ng "ca.crt が見つかりません: $CaCert" ''
        }
    }

    # 証明書の検証結果を、接続を拒否せずに取り出す（プロキシを通さない）
    $script:CertInfo = $null
    $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
        param($sender, $certificate, $chain, $errors)
        $elements = @($chain.ChainElements | ForEach-Object { $_.Certificate })
        $script:CertInfo = @{
            Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificate)
            Errors      = $errors
            Root        = $elements[-1]
            Status      = @($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() })
        }
        return $true
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($Uri.Host, $Uri.Port)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($Uri.Host)
        $ssl.Close()
    } catch {
        if (-not $script:CertInfo) {
            Write-Ng "TLS で接続できません（$($_.Exception.Message)）" 'サーバーで nginx が動いているか確認する'
            return
        }
    } finally {
        $client.Close()
    }

    $certificate = $script:CertInfo.Certificate
    $san = ($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }) -join ', '
    Write-Info "サーバー証明書: $san、期限 $($certificate.NotAfter.ToString('yyyy-MM-dd'))、発行元 $($certificate.Issuer)"
    $errors = $script:CertInfo.Errors
    if ($errors -eq [System.Net.Security.SslPolicyErrors]::None) {
        Write-Ok 'この PC はサーバー証明書を信頼しています'
    }
    if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) {
        Write-Ng "サーバー証明書の IP アドレス（$san）が、Gateway base URL の $($Uri.Host) と違います" 'Gateway base URL を証明書の IP アドレスにするか、管理者に正しい IP アドレスで証明書を発行し直してもらう'
    }
    if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) {
        Write-Ng "サーバー証明書を信頼できません（$($script:CertInfo.Status -join ' / ')）" 'ルート CA 証明書（ca.crt）を「信頼されたルート証明機関」にインストールする（README.md の「ルート CA 証明書をインストールする」）'
    }

    # ルート CA がどの証明書ストアにあるか（Cowork は「ローカル コンピューター」のストアも必要になることがある）
    $rootThumb = $expected
    if (-not $rootThumb -and $script:CertInfo.Root -and $script:CertInfo.Root.Subject -eq $certificate.Issuer) {
        $rootThumb = $script:CertInfo.Root.Thumbprint
    }
    if (-not $rootThumb) {
        Write-Note 'ルート CA の拇印が分からないため、インストール先を確認できません。-Thumbprint か -CaCert を指定してください'
        return
    }
    Write-Info "ルート CA の拇印: $rootThumb（管理者から受け取った拇印と同じか確認してください）"
    if ($expected -and $script:CertInfo.Root -and $script:CertInfo.Root.Subject -eq $certificate.Issuer -and $script:CertInfo.Root.Thumbprint -ne $expected) {
        Write-Ng 'サーバー証明書の発行元が、受け取ったルート CA と違います' '別の CA で発行された証明書か、途中で TLS を復号する機器がある。管理者に確認する'
    }
    $stores = Find-RootCertificate $rootThumb
    if ($stores['CurrentUser']) { Write-Ok '現在のユーザーのストアにあります' } else { Write-Ng '現在のユーザーの「信頼されたルート証明機関」にありません' 'Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\CurrentUser\Root' }
    if ($stores['LocalMachine']) { Write-Ok 'ローカル コンピューターのストアにあります' } else { Write-Note 'ローカル コンピューターのストアにはありません。Cowork で証明書のエラーが出る場合は、管理者権限の PowerShell で Cert:\LocalMachine\Root にもインストールしてください' }
}

function Test-Api([Uri]$Uri, $SystemProxy, [string]$Key) {
    Write-Step '6. テスト接続と推論の違い（Claude Desktop と同じく、システムのプロキシ設定に従う）'
    $base = "$($Uri.Scheme)://$($Uri.Authority)"
    $health = Invoke-Http 'GET' "$base/health/liveliness" '' '' $SystemProxy
    if ($health.Status -eq 200) {
        Write-Ok "/health/liveliness: $($health.Body.Trim())"
    } else {
        $detail = if ($health.Status) { "HTTP $($health.Status)" } else { $health.Error }
        $direct = Invoke-Http 'GET' "$base/health/liveliness" '' '' $null
        if ($direct.Status -eq 200 -and -not $SystemProxy.IsBypassed($Uri)) {
            Write-Ng "/health/liveliness: プロキシ経由で失敗し（$detail）、直接なら成功します" 'プロキシの例外にサーバーの IP アドレスを加える（社内の情報システム部門に依頼するか、PAC ファイルを確認する）'
        } else {
            Write-Ng "/health/liveliness: $detail" '手順 3〜5 の NG を先に解決する'
        }
        return
    }

    if (-not $Key) {
        Write-Note 'キーが入力されていないため、キーとモデル一覧は確認しません'
        return
    }
    $models = Invoke-Http 'GET' "$base/v1/models" $Key '' $SystemProxy
    if ($models.Status -ne 200) {
        Write-Ng "/v1/models: HTTP $($models.Status) $(Limit-Length (Hide-Secret $models.Body) 200)" (Get-StatusHint $models.Status)
        return
    }
    $ids = @(($models.Body | ConvertFrom-Json).data | ForEach-Object { $_.id })
    Write-Ok "キーは有効です。使えるモデル: $($ids -join ', ')"
    if ($ids -notcontains $RequiredModel) {
        Write-Ng "$RequiredModel を使えません" "Cowork の Auto モードに必要。管理者に、案件のチームのモデルに $RequiredModel を加えてもらう"
    }
    if (-not ($ids | Where-Object { $_ -match 'claude|anthropic' })) {
        Write-Ng 'Claude のモデルを使えません' '管理者に、案件のチームで Claude のモデルを許可してもらう'
    }

    # 大きな本文が途中で止められないか（課金なし）。存在しないモデル名で送るため、Bedrock には届かない。
    # LiteLLM の JSON のエラー（Invalid model name など）が返れば、大きな本文がサーバーまで届いている
    $padding = 'x' * 600000
    $bigBody = '{"model":"diagnose-no-such-model","max_tokens":1,"messages":[{"role":"user","content":"' + $padding + '"}]}'
    $big = Invoke-Http 'POST' "$base/v1/messages" $Key $bigBody $SystemProxy 60
    if ($big.Status -ge 400 -and $big.Status -lt 500 -and $big.Body -match '"error"' -and $big.Body -match 'model') {
        Write-Ok '大きな本文（約 600 KB）のリクエストがサーバーまで届きます（課金なし）'
    } else {
        $detail = if ($big.Status) { "HTTP $($big.Status) $(Limit-Length (Hide-Secret $big.Body) 200)" } else { $big.Error }
        Write-Ng "大きな本文（約 600 KB）のリクエストがサーバーまで届きません: $detail" 'Claude Desktop の推論は、システムプロンプトや tools で数百 KB になることがある。途中のプロキシやセキュリティ機器が大きな POST を止めていないか、社内の情報システム部門に確認する（プロキシの例外にサーバーの IP アドレスを加える）'
    }

    if (-not $Inference) {
        Write-Note '推論は送っていません。-Inference を付けると、使えるすべての Claude のモデルにストリーミングで推論を送ります（少額の利用料が発生する）'
        return
    }
    foreach ($model in ($ids | Where-Object { $_ -match 'claude|anthropic' })) {
        $result = Invoke-Stream "$base/v1/messages" $Key $model $SystemProxy
        $label = "推論（ストリーミング、$model）"
        if ($result.Status -ne 200) {
            $detail = if ($result.Status) { "HTTP $($result.Status) $(Limit-Length (Hide-Secret $result.Body) 300)" } else { $result.Error }
            Write-Ng "${label}: $detail" (Get-StatusHint $result.Status)
        } elseif ($result.ErrorEvent) {
            Write-Ng "${label}: ストリームの途中でエラー: $(Limit-Length (Hide-Secret $result.ErrorEvent) 300)" 'サーバーで diagnose-server.sh を実行し、手順 3 のエラーの本文を確認する'
        } elseif (-not $result.Completed) {
            Write-Ng "${label}: ストリームが最後まで届きませんでした（$($result.Error)）" '途中のプロキシがストリーミング（Server-Sent Events）を切っている可能性がある。プロキシの例外にサーバーの IP アドレスを加える'
        } else {
            Write-Ok "${label}: 成功しました（最初のイベントまで $($result.FirstEventMs) ms、全体 $($result.TotalMs) ms、イベント $($result.Events) 件）"
            if ($result.Events -gt 3 -and $result.TotalMs - $result.FirstEventMs -lt 50 -and $result.FirstEventMs -gt 2000) {
                Write-Note 'イベントがまとめて届いています。途中のプロキシがストリーミングをバッファリングしている可能性があります（長い応答でタイムアウトする原因になる）'
            }
        }
    }
}

# ストリーミングで推論を送り、イベントを読み終えるまでの結果を返す
function Invoke-Stream([string]$Url, [string]$Key, [string]$Model, $Proxy) {
    $body = '{"model":"' + $Model + '","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"Reply with OK."}]}'
    $result = @{ Status = 0; Body = ''; Error = ''; ErrorEvent = ''; Completed = $false; Events = 0; FirstEventMs = 0; TotalMs = 0 }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'POST'
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 120000
    $request.Proxy = $Proxy
    $request.ContentType = 'application/json'
    $request.Headers.Add('Authorization', "Bearer $Key")
    $request.Headers.Add('anthropic-version', '2023-06-01')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) {
            $result.Error = "$($_.Exception.Status): $($_.Exception.Message)"
            return $result
        }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $result.Status = [int]$response.StatusCode
        $result.Body = $reader.ReadToEnd()
        $reader.Close()
        return $result
    }
    $result.Status = [int]$response.StatusCode
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $lastEvent = ''
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.StartsWith('event:')) {
                if ($result.Events -eq 0) { $result.FirstEventMs = $watch.ElapsedMilliseconds }
                $result.Events++
                $lastEvent = $line.Substring(6).Trim()
                if ($lastEvent -eq 'message_stop') { $result.Completed = $true }
            } elseif ($line.StartsWith('data:') -and $lastEvent -eq 'error') {
                $result.ErrorEvent = $line.Substring(5).Trim()
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        $reader.Close()
        $response.Close()
    }
    $result.TotalMs = $watch.ElapsedMilliseconds
    if (-not $result.Completed -and -not $result.Error) { $result.Error = "最後のイベント: $lastEvent" }
    return $result
}

function Test-Logs([Uri]$Uri) {
    Write-Step "7. Claude Desktop のログ（$LogHours 時間前から）"
    $directories = "$env:LOCALAPPDATA\Claude\Logs", "$env:APPDATA\Claude\logs"
    $since = (Get-Date).AddHours(-$LogHours)
    # Gateway への通信と関係しないログ（MCP、SSH、Chrome 連携、リモート操作）は除く
    $files = @($directories | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Filter '*.log' -File } |
        Where-Object { $_.LastWriteTime -gt $since -and $_.Name -notmatch '^(mcp|ssh|chrome-native-host|remote-control)' })
    if (-not $files) {
        Write-Note "ログが見つかりません（$($directories -join '、')）"
        return
    }
    # Node.js・Chromium のエラーコードは大文字小文字を区別して照合する（poll_err_by_class などに一致させない）
    $codePattern = 'ERR_[A-Z_]+|ECONN[A-Z]+|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|CERT_[A-Z_]+|self.signed|unable to verify'
    $hostPattern = [regex]::Escape($Uri.Host)
    $sinceText = $since.ToString('yyyy-MM-dd HH:mm:ss')
    $hits = New-Object System.Collections.Generic.List[string]
    $hostSeen = $false
    foreach ($file in $files) {
        foreach ($line in (Get-Content $file.FullName -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            # 行の先頭の時刻（yyyy-MM-dd HH:mm:ss か yyyy-MM-ddTHH:mm:ss）で期間を絞る
            if ($line -match '^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})' -and "$($Matches[1]) $($Matches[2])" -lt $sinceText) { continue }
            if ($line -match $hostPattern) { $hostSeen = $true }
            # エラーの行と、サーバーへのリクエストが 4xx・5xx になった行
            if ($line -match '\[(error|warn)\]' -or $line -cmatch $codePattern -or ($line -match $hostPattern -and $line -match '\b[45]\d\d\b')) {
                $hits.Add("$($file.Name): $(Limit-Length (Hide-Secret $line) 250)")
            }
        }
    }
    if ($hostSeen) {
        Write-Ok "ログにサーバーの IP アドレス（$($Uri.Host)）への接続があります"
    } else {
        Write-Note "ログにサーバーの IP アドレス（$($Uri.Host)）が出てきません。Claude Desktop がこの URL を使っていない可能性があります（設定の保存・再起動を確認）"
    }
    if ($hits.Count -eq 0) {
        Write-Ok 'エラーらしい行はありません'
        return
    }
    Write-Note "エラーらしい行が $($hits.Count) 行あります（直近 30 行）。原因の手がかりになります"
    $hits | Select-Object -Last 30 | ForEach-Object { Write-Info "  $_" }
}

# --- main ---------------------------------------------------------------------
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]'Tls13'
} catch {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

$key = $env:LITELLM_API_KEY
if (-not $key) {
    $secure = Read-Host 'Claude Desktop に設定したキー（sk- で始まる。画面には表示されません。空のまま Enter で省略）' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$uri = Test-BaseUrl
if ($uri) {
    Test-ClaudeDesktop $uri
    $reachable = Test-Tcp $uri
    $systemProxy = Test-Proxy $uri
    if ($reachable) { Test-Certificate $uri }
    Test-Api $uri $systemProxy $key
    Test-Logs $uri
}

Write-Step "考えられる原因（$($script:Problems.Count) 件）"
if ($script:Problems.Count -eq 0) {
    Write-Host '  社内 PC 側では問題が見つかりませんでした。サーバーで scripts/diagnose/diagnose-server.sh を実行してください。'
} else {
    $script:Problems | ForEach-Object { Write-Host "  - $_" }
}
