"""LiteLLM の設定（config.yaml と DB）を読み、点検の結果を出力する。

scripts/audit/audit-config.sh から、LiteLLM のイメージで作る一時的なコンテナの中で実行する。
環境変数（LITELLM_MASTER_KEY、LITELLM_SALT_KEY、DATABASE_URL など）は LiteLLM と同じものを使う。
DB は読むだけで変更しない。

結果は 1 行に 1 つ、タブ区切りで出力し、最後に END を出力する。
  <種類>\t<分類>\t<内容>
  種類: SET（現在の設定）/ ADD（設定したほうがよい）/ CHANGE（変更したほうがよい）
キーや認証情報の値は出力しない（LiteLLM が伏せ字にしたキー名 sk-...abcd だけを出す）。
"""

import asyncio
import base64
import hashlib
import json
import os
import re
from datetime import datetime, timedelta, timezone

import psycopg
import yaml
from psycopg.rows import dict_row

from litellm.proxy._types import UI_TEAM_ID
from litellm.proxy.auth.master_key_boot_check import PUBLICLY_KNOWN_MASTER_KEY_SHA256_DIGESTS
from litellm.proxy.common_utils.encrypt_decrypt_utils import V2_GCM_PREFIX

# 対象の列と復号の判定は、LiteLLM 自身の処理を使う（scripts/migration/rotate-salt-key.sh と同じ。バージョンは固定している）
from litellm.proxy.db.master_key_migration import (
    _rows_of,
    _secret_columns_in,
    count_values_encrypted_with,
    replace_ciphertexts,
)

CONFIG_PATH = "/app/config.yaml"
# Auto モードの安全性分類器が既定で呼ぶモデル（litellm/config.yaml）
REQUIRED_MODEL = "claude-sonnet-5"
# チームの models にこの名前があるか、空のときは、すべてのモデルを使える
ALL_MODELS = "all-proxy-models"
SPEND_WARN_RATIO = 0.8
# これより長く使われていないキーを、不要の候補として挙げる
UNUSED_KEY_DAYS = 90
# 作成からこの日数が経っても一度も使われていないキーを、不要の候補として挙げる
NEVER_USED_KEY_DAYS = 30
CALLBACK_SETTINGS = ("callbacks", "success_callback", "failure_callback", "service_callback", "input_callback")
# 値を表示しない設定の名前
SECRET_NAME = re.compile(r"key|secret|password|token|webhook|url|dsn|credential", re.I)
# この構成では使っていない機能のうち、外部への通信が発生しうるもの
UNUSED_FEATURE_TABLES = (
    ("LiteLLM_MCPServerTable", "MCP サーバー"),
    ("LiteLLM_GuardrailsTable", "ガードレール"),
    ("LiteLLM_AgentsTable", "エージェント"),
)
OTHER_FEATURE_TABLES = (
    ("LiteLLM_OrganizationTable", "組織"),
    ("LiteLLM_EndUserTable", "エンドユーザー"),
    ("LiteLLM_PolicyTable", "ポリシー"),
    ("LiteLLM_PromptTable", "プロンプト"),
    ("LiteLLM_SSOConfig", "SSO の設定"),
    ("LiteLLM_CacheConfig", "キャッシュの設定"),
    ("LiteLLM_ConfigOverrides", "設定の上書き"),
)
# nacl の暗号文は URL セーフな Base64 で、ノンス（24 バイト）と MAC（16 バイト）の 40 バイト以上になる
_LEGACY_CIPHERTEXT = re.compile(r"[A-Za-z0-9_-]+={0,2}")


def emit(kind, category, message):
    print(f"{kind}\t{category}\t{' '.join(str(message).split())}", flush=True)


def checked(category):
    """例外が出ても残りの確認を続ける。本文には接続先などが含まれることがあるため、種類だけを出す。"""

    def decorate(function):
        def run(*args):
            try:
                return function(*args)
            except Exception as e:
                emit("CHANGE", category, f"確認できませんでした（{type(e).__name__}）")

        return run

    return decorate


def shown(name, value):
    if isinstance(value, str) and value.startswith("os.environ/"):
        return value
    if SECRET_NAME.search(name):
        return "（値は表示しない）"
    if isinstance(value, dict):
        # 入れ子の中に認証情報があることがあるため、名前だけを出す
        return "{" + ", ".join(value) + "}"
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= 120 else text[:117] + "..."


def money(value):
    return "なし" if value is None else f"{value:,.2f} USD"


def provider_of(params):
    model = params.get("model") or ""
    return params.get("custom_llm_provider") or (model.split("/", 1)[0] if "/" in model else "")


def bedrock_claude_without_invoke(params):
    # Converse 経路では Claude Code / Cowork のプロンプトキャッシュが効かない（litellm/config.yaml）
    model = params.get("model") or ""
    return provider_of(params) == "bedrock" and "anthropic.claude" in model and not model.startswith("bedrock/invoke/")


def hardcoded_secrets(value, path=""):
    """os.environ/ で参照せず、値が直接書かれた認証情報の場所を返す。"""
    if isinstance(value, dict):
        return [found for name, child in value.items() for found in hardcoded_secrets(child, f"{path}.{name}" if path else name)]
    if isinstance(value, list):
        return [found for i, child in enumerate(value) for found in hardcoded_secrets(child, f"{path}[{i}]")]
    name = path.rsplit(".", 1)[-1]
    if isinstance(value, str) and value and re.search(r"key|secret|password|token", name, re.I) and not value.startswith("os.environ/"):
        return [path]
    return []


def days_since(moment, now):
    return (now - moment).days


def is_publicly_known(value):
    return hashlib.sha256(value.encode()).hexdigest() in PUBLICLY_KNOWN_MASTER_KEY_SHA256_DIGESTS


class Database:
    """LiteLLM の SupportsRawQueries を psycopg で実装する（Prisma の $1 形式の引数を %s に変える）。"""

    def __init__(self, conn):
        self.conn = conn

    def _run(self, query, args):
        cur = self.conn.cursor(row_factory=dict_row)
        if args:
            numbers = [int(n) for n in re.findall(r"\$(\d+)", query)]
            query = re.sub(r"\$\d+", "%s", query.replace("%", "%%"))
            cur.execute(query, [args[n - 1] for n in numbers])
        else:
            cur.execute(query)
        return cur

    def rows(self, query):
        return self._run(query, ()).fetchall()

    def value(self, query):
        return next(iter(self.rows(query)[0].values()))

    async def query_raw(self, query, *args):
        return self._run(query, args).fetchall()

    async def execute_raw(self, query, *args):
        return self._run(query, args).rowcount


def looks_encrypted(value):
    if value.startswith(V2_GCM_PREFIX):
        return True
    if not _LEGACY_CIPHERTEXT.fullmatch(value):
        return False
    try:
        return len(base64.urlsafe_b64decode(value)) >= 40
    except ValueError:
        return False


async def count_encrypted_looking(db):
    total = 0
    for secret_column in await _secret_columns_in(db):
        for row in await _rows_of(db, secret_column):
            total += replace_ciphertexts(row[secret_column.column], lambda v: v if looks_encrypted(v) else None)[1]
    return total


class Audit:
    def __init__(self, db):
        self.db = db
        self.now = datetime.now(timezone.utc).replace(tzinfo=None)
        self.config = {}
        self.db_settings = {}
        self.teams = []
        self.db_models = []
        self.config_model_names = set()
        self.access_groups = set()

    # --- .env（シークレットの強さ。値は表示しない） ---------------------------------
    @checked(".env")
    def secrets(self):
        master = os.environ.get("LITELLM_MASTER_KEY", "")
        salt = os.environ.get("LITELLM_SALT_KEY", "")
        if is_publicly_known(master):
            emit("CHANGE", ".env", "LITELLM_MASTER_KEY が公開されている値（ドキュメントの例の sk-1234）です。LiteLLM が起動を拒否します。新しい値に変えてください")
        elif len(master) < 32:
            emit("CHANGE", ".env", f"LITELLM_MASTER_KEY が短すぎます（{len(master)} 文字）。printf 'sk-%s\\n' \"$(openssl rand -hex 32)\" で作り直してください")
        if is_publicly_known(salt):
            emit("CHANGE", ".env", "LITELLM_SALT_KEY が公開されている値です。DB の認証情報を誰でも復号できます。scripts/migration/rotate-salt-key.sh で変えてください")
        elif salt and salt == master:
            emit("CHANGE", ".env", "LITELLM_MASTER_KEY と LITELLM_SALT_KEY が同じ値です（移行元がソルトキーを設定していなかった場合）。マスターキーだけを新しい値に変えてください（.env を変えるだけでよい）")
        elif len(salt) < 32:
            emit("CHANGE", ".env", f"LITELLM_SALT_KEY が短すぎます（{len(salt)} 文字）。scripts/migration/rotate-salt-key.sh で長い値に変えてください")

    # --- config.yaml --------------------------------------------------------------
    @checked("config.yaml")
    def config_file(self):
        with open(CONFIG_PATH) as f:
            self.config = yaml.safe_load(f) or {}
        region = os.environ.get("AWS_REGION_NAME", "")
        models = self.config.get("model_list") or []
        for entry in models:
            name = entry.get("model_name", "")
            params = entry.get("litellm_params") or {}
            self.config_model_names.add(name)
            self.access_groups.update((entry.get("model_info") or {}).get("access_groups") or [])
            emit("SET", "config.yaml", f"モデル {name} → {params.get('model', '')}")
            if bedrock_claude_without_invoke(params):
                emit("CHANGE", "config.yaml", f"モデル {name} が Bedrock の Converse 経路です。プロンプトキャッシュが効かないため bedrock/invoke/ にしてください")
            if ".anthropic." in params.get("model", "") and params.get("model", "").split("/")[-1].startswith("us.") and region and not region.startswith("us-"):
                emit("CHANGE", "config.yaml", f"モデル {name} は米国の推論プロファイル（us.）ですが、AWS_REGION_NAME が {region} です。us-east-1 などにしてください")
        if not models:
            emit("CHANGE", "config.yaml", "model_list にモデルがありません")
        if REQUIRED_MODEL not in self.config_model_names:
            emit("CHANGE", "config.yaml", f"{REQUIRED_MODEL} がありません。Cowork の Auto モードに必要です")
        for path in hardcoded_secrets(self.config):
            emit("CHANGE", "config.yaml", f"{path} に値が直接書かれています。.env に移し、os.environ/<変数名> で参照してください")
        for section in ("general_settings", "litellm_settings", "router_settings"):
            for name, value in (self.config.get(section) or {}).items():
                emit("SET", "config.yaml", f"{section}.{name} = {shown(name, value)}")
        for name in self.config.get("environment_variables") or {}:
            emit("SET", "config.yaml", f"environment_variables.{name}（値は表示しない）")
        self._callbacks("config.yaml", self.config.get("litellm_settings") or {})
        if (self.config.get("general_settings") or {}).get("store_prompts_in_spend_logs") is True:
            emit("CHANGE", "config.yaml", "store_prompts_in_spend_logs が true です。プロンプトと応答の本文が DB に保存されます")

    def _callbacks(self, category, settings):
        for name in CALLBACK_SETTINGS:
            value = settings.get(name)
            if value:
                emit("CHANGE", category, f"{name} に {shown(name, value)} が設定されています。外部に送信するものなら、外への通信を Bedrock・Azure だけにする方針と異なります。不要なら削除してください")

    # --- 管理 UI で保存した全体設定（DB の LiteLLM_Config など） -----------------------
    @checked("全体設定（DB）")
    def db_global_settings(self):
        category = "全体設定（DB）"
        for row in self.db.rows('SELECT param_name, param_value FROM "LiteLLM_Config" ORDER BY param_name'):
            self.db_settings[row["param_name"]] = row["param_value"]
        for section in ("general_settings", "litellm_settings", "router_settings"):
            settings = self.db_settings.get(section) or {}
            config_settings = self.config.get(section) or {}
            for name, value in settings.items():
                emit("SET", category, f"{section}.{name} = {shown(name, value)}")
                if name in config_settings and config_settings[name] != value:
                    emit("CHANGE", category, f"{section}.{name} が config.yaml と管理 UI（DB）の両方にあり、値が違います。どちらかに揃えてください")
        for name in self.db_settings.get("environment_variables") or {}:
            emit("SET", category, f"environment_variables.{name}（暗号化して保存。値は表示しない）")
        others = sorted(set(self.db_settings) - {"general_settings", "litellm_settings", "router_settings", "environment_variables"})
        if others:
            emit("SET", category, f"その他の保存値: {', '.join(others)}")

        general = self.db_settings.get("general_settings") or {}
        self._callbacks(category, self.db_settings.get("litellm_settings") or {})
        if general.get("store_prompts_in_spend_logs") is True:
            emit("CHANGE", category, "store_prompts_in_spend_logs が true です。プロンプトと応答の本文が DB に保存されます。管理 UI で無効にしてください")
        alerting = general.get("alerting") or (self.config.get("general_settings") or {}).get("alerting")
        if alerting:
            emit("CHANGE", category, f"通知（alerting: {shown('alerting', alerting)}）が設定されています。移行元から引き継いだ場合、移行元と移行先の両方から送られます。不要なら管理 UI で無効にしてください")

        for row in self.db.rows('SELECT ui_settings FROM "LiteLLM_UISettings"'):
            for name, value in (row["ui_settings"] or {}).items():
                emit("SET", category, f"管理 UI の設定 {name} = {shown(name, value)}")

    # --- チーム（= 案件） -----------------------------------------------------------
    @checked("チーム")
    def teams_check(self):
        category = "チーム"
        self.db_models = self.db.rows('SELECT model_name, litellm_params, model_info, blocked FROM "LiteLLM_ProxyModelTable" ORDER BY model_name')
        for model in self.db_models:
            self.access_groups.update((model["model_info"] or {}).get("access_groups") or [])
        known = self.config_model_names | {m["model_name"] for m in self.db_models} | self.access_groups | {ALL_MODELS, "no-default-models"}
        self.teams = self.db.rows(
            """SELECT t.team_id, t.team_alias, t.max_budget, t.spend, t.models, t.budget_duration, t.blocked,
                      t.tpm_limit, t.rpm_limit,
                      (SELECT count(*) FROM "LiteLLM_VerificationToken" k WHERE k.team_id = t.team_id) AS key_count
               FROM "LiteLLM_TeamTable" t ORDER BY t.team_alias NULLS LAST"""
        )
        if not self.teams:
            emit("ADD", category, "チームがありません。案件ごとにチームを作り、予算の上限を設定してください（README.md の「案件を追加する」）")
        aliases = [t["team_alias"] for t in self.teams if t["team_alias"]]
        for alias in sorted({a for a in aliases if aliases.count(a) > 1}):
            emit("CHANGE", category, f"チーム名 {alias} が重複しています。案件ごとに一意の名前にしてください")

        for team in self.teams:
            name = team["team_alias"] or f"（名前なし {team['team_id'][:8]}）"
            models = team["models"] or []
            spend = team["spend"] or 0
            budget = team["max_budget"]
            ratio = spend / budget if budget else None
            details = [
                f"予算 {money(budget)}",
                f"利用 {money(spend)}" + (f"（{ratio:.0%}）" if ratio is not None else ""),
                "モデル " + (", ".join(models) if models else "すべて"),
                f"キー {team['key_count']} 本",
            ]
            if team["budget_duration"]:
                details.append(f"リセット {team['budget_duration']}")
            if team["tpm_limit"] or team["rpm_limit"]:
                details.append(f"TPM {team['tpm_limit'] or '-'} / RPM {team['rpm_limit'] or '-'}")
            if team["blocked"]:
                details.append("停止中")
            emit("SET", category, f"{name}: " + " / ".join(details))

            if not team["team_alias"]:
                emit("CHANGE", category, f"チーム {team['team_id']} に名前（Team Name）がありません。案件名を付けてください")
            if budget is None:
                emit("ADD", category, f"{name}: 予算の上限（Max Budget）がありません。案件の予算の総額を設定してください")
            elif ratio >= 1:
                emit("CHANGE", category, f"{name}: 利用額が予算の上限に達していて、キーが使えません。予算を増やすか、案件を終了してください")
            elif ratio >= SPEND_WARN_RATIO:
                emit("CHANGE", category, f"{name}: 利用額が予算の {ratio:.0%} に達しています。必要なら予算を増やしてください")
            if team["budget_duration"]:
                emit("CHANGE", category, f"{name}: 予算が自動でリセットされます（{team['budget_duration']}）。README.md の方針は案件の期間の総額で、リセットしません")
            if not models or ALL_MODELS in models:
                emit("CHANGE", category, f"{name}: すべてのモデル（他の案件の Azure モデルを含む）を使えます。案件で使うモデルだけを指定してください")
            else:
                if REQUIRED_MODEL not in models and any("claude" in m for m in models):
                    emit("ADD", category, f"{name}: Claude のモデルがありますが {REQUIRED_MODEL} がありません。Cowork を使う案件なら加えてください（Auto モードに必要）")
                missing = [m for m in models if m not in known and "*" not in m]
                if missing:
                    emit("CHANGE", category, f"{name}: 存在しないモデル {', '.join(missing)} が許可されています。モデルの一覧から外してください")
            if team["key_count"] == 0:
                emit("CHANGE", category, f"{name}: キーがありません。案件が終了しているならチームを削除してください")

    # --- キー -----------------------------------------------------------------------
    @checked("キー")
    def keys_check(self):
        category = "キー"
        teams = {t["team_id"]: t for t in self.teams}
        keys = self.db.rows(
            """SELECT key_name, key_alias, team_id, expires, spend, models, blocked, max_budget,
                      budget_duration, created_at, last_active
               FROM "LiteLLM_VerificationToken" ORDER BY key_alias NULLS LAST, created_at"""
        )
        ui_keys = [k for k in keys if k["team_id"] == UI_TEAM_ID]
        if ui_keys:
            expired = sum(1 for k in ui_keys if k["expires"] and k["expires"] < self.now)
            emit("SET", category, f"管理 UI のログインで作られたキー: {len(ui_keys)} 本（うち期限切れ {expired} 本。自動で作られるもので、対応は不要）")
        keys = [k for k in keys if k["team_id"] != UI_TEAM_ID]
        if not keys:
            emit("ADD", category, "利用者向けのキーがありません。案件のチームにキーを発行してください（README.md の「案件を追加する」）")

        for key in keys:
            team = teams.get(key["team_id"])
            team_alias = team["team_alias"] if team else None
            name = key["key_alias"] or key["key_name"] or "（名前なし）"
            last_active = key["last_active"]
            details = [
                f"チーム {team_alias or key['team_id'] or 'なし'}",
                f"有効期限 {key['expires']:%Y-%m-%d}" if key["expires"] else "有効期限なし",
                f"利用 {money(key['spend'] or 0)}",
                f"最終利用 {last_active:%Y-%m-%d}" if last_active else "最終利用の記録なし",
            ]
            if key["max_budget"] is not None:
                details.append(f"キーの予算 {money(key['max_budget'])}")
            if key["models"]:
                details.append("モデル " + ", ".join(key["models"]))
            if key["blocked"]:
                details.append("停止中")
            label = f"{name}（{key['key_name']}）" if key["key_alias"] else name
            emit("SET", category, f"{label}: " + " / ".join(details))

            if not key["team_id"]:
                emit("CHANGE", category, f"{name}: チームに属していません。チームの予算の上限がかからないため、案件のチームのキーとして作り直してください")
            elif not team:
                emit("CHANGE", category, f"{name}: 属しているチーム（{key['team_id']}）がありません。不要なら削除してください")
            if not key["key_alias"]:
                emit("ADD", category, f"{key['key_name']}: Key Alias がありません。<案件名>-shared または <案件名>-<メンバー名> を付けてください")
            elif team_alias and not key["key_alias"].startswith(f"{team_alias}-"):
                emit("CHANGE", category, f"{name}: 名前が命名規則（{team_alias}-shared / {team_alias}-<メンバー名>）と違います")
            if key["expires"] and key["expires"] < self.now:
                emit("CHANGE", category, f"{name}: 有効期限が切れています（{key['expires']:%Y-%m-%d}）。不要なら削除してください")
            if key["max_budget"] is not None or key["budget_duration"]:
                emit("CHANGE", category, f"{name}: キーにも予算が設定されています。README.md の方針はチームだけに設定します（どちらかの上限に達すると使えなくなります）")
            if last_active and days_since(last_active, self.now) >= UNUSED_KEY_DAYS:
                emit("CHANGE", category, f"{name}: {days_since(last_active, self.now)} 日使われていません。不要なら削除してください")
            elif not last_active and not key["spend"] and key["created_at"] and days_since(key["created_at"], self.now) >= NEVER_USED_KEY_DAYS:
                emit("CHANGE", category, f"{name}: 作成から {days_since(key['created_at'], self.now)} 日、一度も使われていません。不要なら削除してください")
            team_models = (team["models"] or []) if team else []
            if key["models"] and team_models and ALL_MODELS not in team_models:
                outside = [m for m in key["models"] if m not in team_models and "*" not in m]
                if outside:
                    emit("CHANGE", category, f"{name}: チームに許可されていないモデル {', '.join(outside)} が指定されています（使えません）")

    # --- 管理 UI で登録したモデル ------------------------------------------------------
    @checked("モデル")
    def models_check(self):
        category = "モデル"
        team_aliases = [t["team_alias"] for t in self.teams if t["team_alias"]]
        assigned = {m for t in self.teams for m in (t["models"] or [])}
        some_team_has_all = any(not t["models"] or ALL_MODELS in t["models"] for t in self.teams)
        if not self.db_models:
            emit("SET", category, "管理 UI で登録したモデルはありません（config.yaml のモデルだけ）")
        by_name = {}
        for model in self.db_models:
            by_name.setdefault(model["model_name"], []).append(model)

        for model in self.db_models:
            name = model["model_name"]
            params = model["litellm_params"] or {}
            provider = provider_of(params)
            api_base = params.get("api_base") or ""
            host = re.sub(r"^https?://([^/]+).*", r"\1", api_base) if api_base else ""
            details = [params.get("model", "")]
            if host:
                details.append(f"接続先 {host}")
            if params.get("litellm_credential_name"):
                details.append(f"認証情報 {params['litellm_credential_name']}")
            if model["blocked"]:
                details.append("停止中")
            emit("SET", category, f"{name} → " + " / ".join(details))

            if name in self.config_model_names:
                emit("CHANGE", category, f"{name}: config.yaml のモデルと同じ名前のため、両者の間で負荷分散されます。管理 UI で DB 側を削除してください")
            if provider.startswith("azure") and team_aliases and not any(name.startswith(f"{a}-") for a in team_aliases):
                emit("CHANGE", category, f"{name}: 名前の先頭が案件名ではありません。別の案件と同じ名前になると負荷分散されるため、<案件名>-<モデル名> にしてください")
            groups = set((model["model_info"] or {}).get("access_groups") or [])
            if self.teams and not some_team_has_all and name not in assigned and not groups & assigned:
                emit("CHANGE", category, f"{name}: どのチームにも割り当てられていません。使うチームの Models に加えるか、不要なら削除してください")
            if provider == "bedrock" and any(params.get(p) and not str(params[p]).startswith("os.environ/") for p in ("aws_access_key_id", "aws_secret_access_key")):
                emit("CHANGE", category, f"{name}: Bedrock の認証情報がモデルに保存されています。README.md の方針では入力せず、.env の値を使います")
            if bedrock_claude_without_invoke(params):
                emit("CHANGE", category, f"{name}: Bedrock の Converse 経路です。Claude Code / Cowork のプロンプトキャッシュが効かないため、bedrock/invoke/ にしてください")

        for name, same in by_name.items():
            targets = {((m["litellm_params"] or {}).get("model"), (m["litellm_params"] or {}).get("api_base")) for m in same}
            if len(same) > 1 and len(targets) > 1:
                emit("CHANGE", category, f"{name}: 同じ名前で接続先の違うモデルが {len(same)} 件あり、負荷分散されます。別の案件のリソースなら名前を分けてください")

    # --- DB に保存した認証情報 ----------------------------------------------------------
    @checked("認証情報")
    def credentials_check(self):
        category = "認証情報"
        used = {(m["litellm_params"] or {}).get("litellm_credential_name") for m in self.db_models}
        for row in self.db.rows('SELECT credential_name, credential_info FROM "LiteLLM_CredentialsTable" ORDER BY credential_name'):
            provider = (row["credential_info"] or {}).get("custom_llm_provider") or "-"
            emit("SET", category, f"{row['credential_name']}（{provider}）")
            if row["credential_name"] not in used:
                emit("CHANGE", category, f"{row['credential_name']}: どのモデルからも使われていません。不要なら削除してください")

        encrypted = asyncio.run(count_encrypted_looking(self.db))
        decryptable = asyncio.run(count_values_encrypted_with(self.db, os.environ["LITELLM_SALT_KEY"]))
        emit("SET", category, f"暗号化して保存された値: {encrypted} 件（.env の LITELLM_SALT_KEY で復号できる: {decryptable} 件）")
        if decryptable < encrypted:
            emit("CHANGE", category, f"{encrypted - decryptable} 件の値を、今のソルトキーで復号できません。移行元とソルトキーが違う可能性があります。scripts/migration/rotate-salt-key.sh --check で確認してください")

    # --- ユーザーと、この構成で使っていない機能 --------------------------------------------
    @checked("ユーザー")
    def users_check(self):
        for row in self.db.rows('SELECT user_role, count(*) AS n, count(password) AS with_password FROM "LiteLLM_UserTable" GROUP BY user_role ORDER BY user_role'):
            emit("SET", "ユーザー", f"{row['user_role'] or '（役割なし）'}: {row['n']} 人（パスワードでログインできる: {row['with_password']} 人）")

    @checked("その他の機能")
    def features_check(self):
        category = "その他の機能"
        found = False
        for table, label in UNUSED_FEATURE_TABLES + OTHER_FEATURE_TABLES:
            count = self.db.value(f'SELECT count(*) FROM "{table}"')
            if count:
                found = True
                emit("SET", category, f"{label}: {count} 件")
                if (table, label) in UNUSED_FEATURE_TABLES:
                    emit("CHANGE", category, f"{label}が {count} 件登録されています。この構成では使っておらず、外部への通信が発生することがあります。不要なら管理 UI で削除してください")
        if not found:
            emit("SET", category, "組織・MCP・ガードレール・SSO などの登録はありません")

    # --- DB（利用ログとマイグレーション） ---------------------------------------------------
    @checked("DB")
    def db_check(self):
        category = "DB"
        db_size = self.db.value("SELECT pg_database_size(current_database())")
        logs = self.db.rows('SELECT count(*) AS n, max("startTime") AS latest FROM "LiteLLM_SpendLogs"')[0]
        logs_size = self.db.value("""SELECT pg_total_relation_size('"LiteLLM_SpendLogs"')""")
        latest = f"、最新 {logs['latest']:%Y-%m-%d %H:%M}（UTC）" if logs["latest"] else ""
        emit("SET", category, f"DB のサイズ: {db_size / 1024**2:,.0f} MB")
        emit("SET", category, f"利用ログ（Logs）: {logs['n']:,} 件、{logs_size / 1024**2:,.0f} MB{latest}")
        general = {**(self.config.get("general_settings") or {}), **(self.db_settings.get("general_settings") or {})}
        retention = general.get("maximum_spend_logs_retention_period")
        if retention:
            emit("SET", category, f"利用ログの保存期間: {retention}")
        elif logs["n"]:
            emit("ADD", category, f"利用ログの保存期間がなく、無期限に増えます（現在 {logs['n']:,} 件、{logs_size / 1024**2:,.0f} MB）。期間を決めるなら general_settings.maximum_spend_logs_retention_period（例: \"180d\"）を設定してください。チームの利用額と予算には影響しません")

        total = self.db.value("SELECT count(*) FROM _prisma_migrations")
        failed = self.db.rows("SELECT migration_name FROM _prisma_migrations WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL ORDER BY started_at")
        emit("SET", category, f"マイグレーション: {total} 件（失敗・未完了 {len(failed)} 件）")
        if failed:
            emit("CHANGE", category, f"失敗・未完了のマイグレーションがあります: {', '.join(r['migration_name'] for r in failed)}。scripts/migration/check-db.sh で確認してください")


def main():
    audit = Audit(None)
    audit.secrets()
    audit.config_file()
    try:
        # 1 つの確認が失敗しても次の確認に影響しないよう、文ごとにコミットする。
        # 読むだけなので、誤って書き込まないようセッションを読み取り専用にする
        conn = psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=10, autocommit=True)
        conn.execute("SET default_transaction_read_only = on")
    except Exception as e:
        # 本文には接続先などが含まれることがあるため、種類だけを出す
        emit("CHANGE", "DB", f"DB に接続できませんでした（{type(e).__name__}）。scripts/migration/check-db.sh で確認してください")
        return
    with conn:
        audit.db = Database(conn)
        audit.db_global_settings()
        audit.teams_check()
        audit.keys_check()
        audit.models_check()
        audit.credentials_check()
        audit.users_check()
        audit.features_check()
        audit.db_check()


main()
print("END")
