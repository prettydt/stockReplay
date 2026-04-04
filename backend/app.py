"""
Flask 后端
启动: python app.py
访问: http://localhost:5001
"""

import hashlib
import hmac
import json
import os
import subprocess
import time
from pathlib import Path
from uuid import uuid4

import pymysql
import pymysql.cursors
from flask import Flask, render_template, jsonify, request, redirect, url_for
from flask_compress import Compress

try:
    import stripe
except Exception:  # pragma: no cover - 环境未装 stripe 时仍允许网页启动
    stripe = None

PROJECT_ROOT = Path(__file__).resolve().parents[1]

app = Flask(__name__, template_folder=str(PROJECT_ROOT / "templates"))
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "stock-replay-dev-secret")
Compress(app)  # 自动 gzip 压缩 JSON 响应，茅台分时数据从 ~2MB 压缩至 ~150KB

BASE_DIR = PROJECT_ROOT
MEMBER_DB_FILE = BASE_DIR / "data" / "member_db.json"
FREE_PREVIEW_DAYS = int(os.environ.get("FREE_PREVIEW_DAYS", "7"))
SITE_URL = os.environ.get("SITE_URL", "http://localhost:5001")
AFDIAN_PAGE_URL = os.environ.get("AFDIAN_PAGE_URL", "https://ifdian.net/a/stockreplay")
AFDIAN_TOKEN = os.environ.get("AFDIAN_TOKEN", "").strip()
STRIPE_SECRET_KEY = os.environ.get("STRIPE_SECRET_KEY", "").strip()
STRIPE_WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
STRIPE_READY = bool(STRIPE_SECRET_KEY)

if stripe and STRIPE_SECRET_KEY:
    stripe.api_key = STRIPE_SECRET_KEY

PLANS = {
    "monthly": {"name": "月度会员", "price": 39, "days": 30},
    "yearly": {"name": "年度会员", "price": 299, "days": 365},
}
APPLE_PRODUCT_PLAN_MAP = {
    "com.prettydt.stockreplay.monthly": "monthly",
    "com.prettydt.stockreplay.yearly": "yearly",
}
APPLE_SYNC_MODE = (os.environ.get("APPLE_SYNC_MODE", "sandbox") or "sandbox").strip().lower()

# MySQL 连接配置，可通过环境变量覆盖
DB_CONFIG = {
    "host": os.environ.get("MYSQL_HOST", "127.0.0.1"),
    "port": int(os.environ.get("MYSQL_PORT", "3306")),
    "user": os.environ.get("MYSQL_USER", "root"),
    "password": os.environ.get("MYSQL_PASSWORD", ""),
    "database": os.environ.get("MYSQL_DB", "stock_replay"),
    "charset": "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
}


def load_member_db() -> dict:
    if not MEMBER_DB_FILE.exists():
        return {}
    try:
        data = json.loads(MEMBER_DB_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


MEMBER_DB = load_member_db()


def save_member_db() -> None:
    MEMBER_DB_FILE.parent.mkdir(parents=True, exist_ok=True)
    MEMBER_DB_FILE.write_text(json.dumps(MEMBER_DB, ensure_ascii=False, indent=2), encoding="utf-8")


def stripe_value(obj, key: str, default=None):
    """同时兼容 dict 和 StripeObject 的取值方式。"""
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(key, default)
    try:
        return obj[key]
    except Exception:
        return getattr(obj, key, default)


def query(sql: str, params: tuple = ()):
    conn = pymysql.connect(**DB_CONFIG)
    cur = conn.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall()
    conn.close()
    return rows


def get_member_token() -> str:
    return (request.headers.get("X-Member-Token") or request.args.get("token", "")).strip()


def get_account_id() -> str:
    return (request.headers.get("X-Account-Id") or request.args.get("account_id", "")).strip()


def get_afdian_uid() -> str:
    return (request.headers.get("X-Afdian-Uid") or request.args.get("afdian_uid", "")).strip()


def get_recent_dates(code: str, limit: int = FREE_PREVIEW_DAYS):
    rows = query(
        "SELECT DISTINCT trade_date FROM tick WHERE code=%s ORDER BY trade_date DESC",
        (code,),
    )
    return [r["trade_date"] for r in rows[:limit]]


def find_member_by_account_id(account_id: str):
    if not account_id:
        return None, None
    for token, info in MEMBER_DB.items():
        if info.get("account_id") == account_id or info.get("uid") == account_id:
            return token, info
    return None, None


def find_member_by_afdian_uid(afdian_uid: str):
    if not afdian_uid:
        return None, None
    for token, info in MEMBER_DB.items():
        if info.get("afdian_uid") == afdian_uid or (info.get("provider") == "afdian" and info.get("uid") == afdian_uid):
            return token, info
    return None, None


def resolve_member(token: str = "", account_id: str = "", afdian_uid: str = ""):
    if token:
        info = MEMBER_DB.get(token)
        if info:
            return token, info
    token, info = find_member_by_account_id(account_id)
    if info:
        return token, info
    return find_member_by_afdian_uid(afdian_uid)


def is_member(token: str = "", account_id: str = "", afdian_uid: str = "") -> bool:
    _, info = resolve_member(token, account_id, afdian_uid)
    return bool(info and info.get("expire_ts", 0) > time.time())


def can_access_date(code: str, date: str, token: str = "", account_id: str = "", afdian_uid: str = ""):
    if is_member(token, account_id, afdian_uid):
        return True, []
    preview_dates = get_recent_dates(code)
    return date in preview_dates, preview_dates


def grant_membership(plan_key: str, user_id: str, order_no: str, account_id: str = "", provider: str = "manual", afdian_uid: str = "") -> str:
    plan_key = plan_key if plan_key in PLANS else "monthly"
    stable_id = account_id or user_id
    member_token = hashlib.sha256(f"member:{stable_id}".encode()).hexdigest()[:32]
    days = PLANS[plan_key]["days"]

    current = MEMBER_DB.get(member_token)
    base_ts = current["expire_ts"] if current and current.get("expire_ts", 0) > time.time() else time.time()

    MEMBER_DB[member_token] = {
        "uid": user_id,
        "account_id": stable_id,
        "afdian_uid": afdian_uid,
        "provider": provider,
        "plan": plan_key,
        "expire_ts": base_ts + days * 86400,
        "order_no": order_no,
    }
    save_member_db()
    return member_token


def build_member_response(valid: bool, token: str = "", info: dict = None, reason: str = "") -> dict:
    if not valid or not info:
        return {
            "valid": False,
            "reason": reason or "当前账号未开通会员",
        }

    expire_hours = max(int((info.get("expire_ts", 0) - time.time()) / 3600), 0)
    plan_key = info.get("plan", "monthly")
    plan_name = PLANS.get(plan_key, PLANS["monthly"])["name"]
    return {
        "valid": True,
        "token": token,
        "account_id": info.get("account_id", ""),
        "afdian_uid": info.get("afdian_uid", ""),
        "provider": info.get("provider", "manual"),
        "plan": plan_name,
        "expire_in": f"{expire_hours} 小时",
        "reason": "",
    }


def stripe_request_via_curl(path: str, method: str = "GET", data: dict = None) -> dict:
    """在本机 Python SSL 环境不稳定时，使用系统 curl 直连 Stripe。"""
    if not STRIPE_SECRET_KEY:
        raise RuntimeError("未配置 STRIPE_SECRET_KEY")

    command = [
        "curl", "-sS",
        "-u", f"{STRIPE_SECRET_KEY}:",
        "https://api.stripe.com" + path,
    ]

    if method.upper() != "GET":
        command.extend(["-X", method.upper()])

    for key, value in (data or {}).items():
        command.extend(["--data-urlencode", f"{key}={value}"])

    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "curl 调用 Stripe 失败")

    payload = json.loads(result.stdout)
    if isinstance(payload, dict) and payload.get("error"):
        raise RuntimeError(payload["error"].get("message", "Stripe API 返回错误"))
    return payload


def build_checkout_payload(plan_key: str, demo_uid: str) -> dict:
    plan = PLANS[plan_key]
    return {
        "mode": "payment",
        "success_url": f"{SITE_URL}/payment/success?session_id={{CHECKOUT_SESSION_ID}}",
        "cancel_url": f"{SITE_URL}/payment/cancel",
        "metadata[plan_key]": plan_key,
        "metadata[demo_uid]": demo_uid,
        "line_items[0][quantity]": 1,
        "line_items[0][price_data][currency]": "cny",
        "line_items[0][price_data][unit_amount]": int(plan["price"] * 100),
        "line_items[0][price_data][product_data][name]": f"{plan['name']} · 分时回放会员",
        "line_items[0][price_data][product_data][description]": "支付成功后自动解锁全量历史与会员功能",
    }


@app.route("/")
def index():
    return render_template(
        "index.html",
        stripe_enabled=STRIPE_READY,
        prefill_token=request.args.get("token", ""),
        prefill_account_id=request.args.get("account_id", ""),
        prefill_afdian_uid=request.args.get("afdian_uid", ""),
        payment_message=request.args.get("message", ""),
        preview_days=FREE_PREVIEW_DAYS,
        afdian_page_url=AFDIAN_PAGE_URL,
        plans=PLANS,
    )


@app.route("/api/health")
def api_health():
    return jsonify({
        "ok": True,
        "service": "stock_replay",
        "preview_days": FREE_PREVIEW_DAYS,
        "membership_mode": "afdian+apple-mvp",
        "apple_sync_mode": APPLE_SYNC_MODE,
        "store_products": list(APPLE_PRODUCT_PLAN_MAP.keys()),
        "server_time": int(time.time()),
    })


@app.route("/api/verify")
def api_verify():
    token = request.args.get("token", "").strip()
    account_id = request.args.get("account_id", "").strip()
    afdian_uid = request.args.get("afdian_uid", "").strip()
    if not token and not account_id and not afdian_uid:
        return jsonify(build_member_response(False, reason="缺少 token、account_id 或 afdian_uid"))

    resolved_token, info = resolve_member(token, account_id, afdian_uid)
    if not info:
        return jsonify(build_member_response(False, reason="账号未开通会员"))
    if info.get("expire_ts", 0) <= time.time():
        return jsonify(build_member_response(False, reason="会员已过期"))

    updated = False
    if account_id and info.get("account_id") != account_id:
        info["account_id"] = account_id
        updated = True
    if afdian_uid and info.get("afdian_uid") != afdian_uid:
        info["afdian_uid"] = afdian_uid
        updated = True
    if updated:
        MEMBER_DB[resolved_token] = info
        save_member_db()

    return jsonify(build_member_response(True, token=resolved_token, info=info))


@app.route("/api/subscription/apple/sync", methods=["POST"])
def api_subscription_apple_sync():
    """iOS MVP 用：把 StoreKit 成功交易同步到当前账号。后续可替换为正式的 Apple 校验。"""
    data = request.get_json(silent=True) or {}
    token = (data.get("token") or "").strip()
    account_id = (data.get("account_id") or "").strip()
    afdian_uid = (data.get("afdian_uid") or "").strip()
    product_id = (data.get("product_id") or "").strip()
    transaction_id = str(data.get("transaction_id") or "").strip()

    if product_id not in APPLE_PRODUCT_PLAN_MAP:
        return jsonify(build_member_response(False, reason="未知 Apple 订阅产品")), 400
    if not token and not account_id and not afdian_uid:
        return jsonify(build_member_response(False, reason="请先填写账号，再同步 Apple 订阅。")), 400

    resolved_token, info = resolve_member(token, account_id, afdian_uid)
    if info:
        account_id = account_id or info.get("account_id", "")
        afdian_uid = afdian_uid or info.get("afdian_uid", "")

    stable_user = account_id or afdian_uid or (info or {}).get("uid") or "apple_user"
    plan_key = APPLE_PRODUCT_PLAN_MAP[product_id]
    order_no = transaction_id or f"apple_{int(time.time())}_{uuid4().hex[:8]}"
    member_token = grant_membership(
        plan_key=plan_key,
        user_id=stable_user,
        order_no=order_no,
        account_id=account_id or stable_user,
        provider="apple_iap",
        afdian_uid=afdian_uid,
    )
    resolved_token, info = resolve_member(member_token, account_id or stable_user, afdian_uid)
    response = build_member_response(True, token=resolved_token or member_token, info=info)
    response["sync_mode"] = APPLE_SYNC_MODE
    response["product_id"] = product_id
    return jsonify(response)


@app.route("/api/stripe/create-checkout-session", methods=["POST"])
def create_stripe_checkout_session():
    data = request.get_json(silent=True) or {}
    plan_key = data.get("plan", "monthly")
    if plan_key not in PLANS:
        return jsonify({"error": "未知套餐"}), 400
    if not STRIPE_SECRET_KEY:
        return jsonify({"error": "未配置 STRIPE_SECRET_KEY"}), 400

    account_id = (data.get("account_id") or data.get("uid") or "").strip()
    if not account_id:
        return jsonify({"error": "请先输入账号，再发起支付。"}), 400

    demo_uid = account_id
    payload = build_checkout_payload(plan_key, demo_uid)
    payload["metadata[account_id]"] = account_id

    try:
        if stripe is None:
            raise RuntimeError("stripe SDK 不可用，改用 curl fallback")
        checkout_session = stripe.checkout.Session.create(
            mode="payment",
            success_url=payload["success_url"],
            cancel_url=payload["cancel_url"],
            metadata={"plan_key": plan_key, "demo_uid": demo_uid, "account_id": account_id},
            line_items=[{
                "quantity": 1,
                "price_data": {
                    "currency": "cny",
                    "unit_amount": payload["line_items[0][price_data][unit_amount]"],
                    "product_data": {
                        "name": payload["line_items[0][price_data][product_data][name]"],
                        "description": payload["line_items[0][price_data][product_data][description]"],
                    },
                },
            }],
        )
        return jsonify({"checkout_url": checkout_session.url, "transport": "stripe-sdk"})
    except Exception as sdk_error:
        try:
            checkout_session = stripe_request_via_curl("/v1/checkout/sessions", method="POST", data=payload)
            return jsonify({"checkout_url": checkout_session["url"], "transport": "curl-fallback"})
        except Exception as curl_error:
            return jsonify({
                "error": "Stripe Checkout 创建失败",
                "sdk_error": str(sdk_error),
                "curl_error": str(curl_error),
            }), 502


@app.route("/payment/success")
def payment_success():
    session_id = request.args.get("session_id", "")
    if not (STRIPE_READY and session_id):
        return redirect(url_for("index", message="支付已返回，但当前未完成 Stripe 校验。"))

    try:
        if stripe is None:
            raise RuntimeError("stripe SDK 不可用，改用 curl fallback")
        checkout_session = stripe.checkout.Session.retrieve(session_id)
    except Exception:
        try:
            checkout_session = stripe_request_via_curl(f"/v1/checkout/sessions/{session_id}")
        except Exception as exc:
            return redirect(url_for("index", message=f"Stripe 回跳校验失败：{exc}"))

    payment_status = stripe_value(checkout_session, "payment_status", "")
    if payment_status != "paid":
        return redirect(url_for("index", message="支付尚未完成，请稍后再试。"))

    metadata = stripe_value(checkout_session, "metadata", {}) or {}
    plan_key = stripe_value(metadata, "plan_key", "monthly")
    account_id = stripe_value(metadata, "account_id") or stripe_value(metadata, "demo_uid") or ""
    user_id = account_id or stripe_value(checkout_session, "customer_email") or "stripe_user"
    order_no = stripe_value(checkout_session, "payment_intent") or session_id
    token = grant_membership(plan_key, user_id, order_no, account_id=account_id, provider="stripe")

    return redirect(url_for(
        "index",
        token=token,
        account_id=account_id,
        message=f"Stripe 支付成功，已开通 {PLANS[plan_key]['name']}。",
    ))


@app.route("/payment/cancel")
def payment_cancel():
    return redirect(url_for("index", message="已取消支付，未扣款。"))


@app.route("/webhook/afdian", methods=["POST"])
def afdian_webhook():
    """爱发电支付回调：激活会员并等待用户绑定本地账号。"""
    if not AFDIAN_TOKEN:
        return jsonify({"ec": 400, "em": "未配置 AFDIAN_TOKEN"}), 400

    data = request.get_json(silent=True) or {}
    received_sign = data.get("sign", "")
    ts = str(data.get("ts", ""))
    params_str = json.dumps(data.get("data", {}), separators=(",", ":"), sort_keys=True)
    expected_sign = hashlib.md5(f"{AFDIAN_TOKEN}params{params_str}ts{ts}".encode()).hexdigest()

    if not hmac.compare_digest(received_sign, expected_sign):
        return jsonify({"ec": 400, "em": "签名错误"}), 400

    order = data.get("data", {}).get("order", {})
    plan_id = (order.get("plan_id", "") or "").lower()
    afdian_uid = order.get("user_id", "") or f"afd_{uuid4().hex[:8]}"
    order_no = order.get("out_trade_no", f"afdian_{int(time.time())}")
    plan_key = "yearly" if "year" in plan_id else "monthly"

    grant_membership(
        plan_key=plan_key,
        user_id=afdian_uid,
        order_no=order_no,
        provider="afdian",
        afdian_uid=afdian_uid,
    )
    return jsonify({"ec": 200, "em": "success"})


@app.route("/webhook/stripe", methods=["POST"])
def stripe_webhook():
    if stripe is None or not STRIPE_WEBHOOK_SECRET:
        return jsonify({"received": False, "message": "未配置 STRIPE_WEBHOOK_SECRET"}), 400

    payload = request.data
    sig_header = request.headers.get("Stripe-Signature", "")

    try:
        event = stripe.Webhook.construct_event(payload, sig_header, STRIPE_WEBHOOK_SECRET)
    except ValueError:
        return jsonify({"received": False, "message": "无效 payload"}), 400
    except stripe.error.SignatureVerificationError:
        return jsonify({"received": False, "message": "签名校验失败"}), 400

    if event["type"] == "checkout.session.completed":
        session_obj = event["data"]["object"]
        metadata = stripe_value(session_obj, "metadata", {}) or {}
        plan_key = stripe_value(metadata, "plan_key", "monthly")
        account_id = stripe_value(metadata, "account_id") or stripe_value(metadata, "demo_uid") or ""
        customer_details = stripe_value(session_obj, "customer_details", {}) or {}
        user_id = account_id or stripe_value(customer_details, "email") or "stripe_webhook_user"
        order_no = stripe_value(session_obj, "payment_intent") or stripe_value(session_obj, "id") or f"stripe_{int(time.time())}"
        grant_membership(plan_key, user_id, order_no, account_id=account_id, provider="stripe")

    return jsonify({"received": True})


@app.route("/api/dates")
def api_dates():
    """返回某支股票所有有数据的日期；免费版默认仅展示最近几天。"""
    code = request.args.get("code", "sz300502")
    rows = query(
        "SELECT DISTINCT trade_date FROM tick WHERE code=%s ORDER BY trade_date DESC",
        (code,),
    )
    dates = [r["trade_date"] for r in rows]
    if is_member(get_member_token(), get_account_id(), get_afdian_uid()):
        return jsonify(dates)
    return jsonify(dates[:FREE_PREVIEW_DAYS])


@app.route("/api/codes")
def api_codes():
    """返回数据库中所有股票代码，附带名称"""
    rows = query("""
        SELECT t.code, COALESCE(n.name, t.code) AS name
        FROM (SELECT DISTINCT code FROM tick ORDER BY code) t
        LEFT JOIN stock_name n ON t.code = n.code
    """)
    return jsonify([{"code": r["code"], "name": r["name"]} for r in rows])


@app.route("/api/ticks")
def api_ticks():
    """返回某支股票某天的所有分时 tick；非会员默认仅可看最近几天。"""
    code = request.args.get("code", "sz300502")
    date = request.args.get("date", "")
    if not date:
        return jsonify([])

    allowed, preview_dates = can_access_date(code, date, get_member_token(), get_account_id(), get_afdian_uid())
    if not allowed:
        return jsonify({
            "error": f"免费版仅可查看最近 {FREE_PREVIEW_DAYS} 个交易日，开通会员可解锁全量历史。",
            "preview_dates": preview_dates,
            "need_member": True,
        }), 403

    rows = query(
        """SELECT ts, price, volume, amount, `open`, high, low, pre_close,
                  b1p, b1v, b2p, b2v, b3p, b3v, b4p, b4v, b5p, b5v,
                  a1p, a1v, a2p, a2v, a3p, a3v, a4p, a4v, a5p, a5v
           FROM tick WHERE code=%s AND trade_date=%s ORDER BY ts""",
        (code, date),
    )
    return jsonify(rows)


@app.route("/api/summary")
def api_summary():
    """返回某支股票某天的基本统计（用于页面顶部信息栏）"""
    code = request.args.get("code", "sz300502")
    date = request.args.get("date", "")
    if not date:
        return jsonify({})

    allowed, preview_dates = can_access_date(code, date, get_member_token(), get_account_id(), get_afdian_uid())
    if not allowed:
        return jsonify({
            "error": f"免费版仅可查看最近 {FREE_PREVIEW_DAYS} 个交易日，开通会员可解锁全量历史。",
            "preview_dates": preview_dates,
            "need_member": True,
        }), 403

    rows = query(
        """SELECT price, volume, amount, `open`, high, low, pre_close, ts
           FROM tick WHERE code=%s AND trade_date=%s ORDER BY ts""",
        (code, date),
    )
    if not rows:
        return jsonify({})

    last = rows[-1]
    pre_close = rows[0]["pre_close"]
    high = max(r["price"] for r in rows)
    low = min(r["price"] for r in rows)
    total_vol = sum(r["volume"] for r in rows)
    total_amt = sum(r["amount"] for r in rows)
    close = last["price"]
    chg = round(close - pre_close, 2)
    pct = round(chg / pre_close * 100, 2) if pre_close else 0
    return jsonify({
        "code": code,
        "date": date,
        "open": rows[0]["open"],
        "pre_close": pre_close,
        "close": close,
        "high": high,
        "low": low,
        "volume": round(total_vol),
        "amount": round(total_amt),
        "chg": chg,
        "pct": pct,
    })


def main():
    try:
        conn = pymysql.connect(**{k: v for k, v in DB_CONFIG.items() if k != "cursorclass"})
        conn.close()
    except Exception as e:
        print(f"[WARN] 无法连接 MySQL：{e}")
        print("       请确保 MySQL 已启动，并创建数据库: CREATE DATABASE stock_replay;")

    print(f"[app] Stripe ready: {STRIPE_READY}")
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=5001, debug=debug)


if __name__ == "__main__":
    main()
