"""
会员付费 Demo —— 独立运行，不依赖现有数据库
启动:
  cd demo
  export STRIPE_SECRET_KEY=sk_test_xxx   # 可选；不配也能走本地模拟开通
  python app_demo.py

访问: http://localhost:5100
"""

import hashlib
import hmac
import json
import os
import subprocess
import time
from functools import wraps
from uuid import uuid4

from flask import Flask, render_template, jsonify, request, redirect, url_for

try:
    import stripe
except Exception:  # pragma: no cover - demo 中允许未安装 stripe 也能运行
    stripe = None

app = Flask(__name__)
app.secret_key = os.environ.get("DEMO_SECRET_KEY", "demo-secret-change-in-prod")

# ──────────────────────────────────────────────
# 本地模拟数据（真实接入时换成数据库）
# ──────────────────────────────────────────────

# 模拟已付费用户表：{ token: {uid, plan, expire_ts} }
MEMBER_DB: dict = {}

# 爱发电 Webhook 密钥（真实项目从环境变量读取）
AFDIAN_TOKEN = os.environ.get("AFDIAN_TOKEN", "demo_afdian_token_replace_me")

# Stripe Demo 配置
SITE_URL = os.environ.get("SITE_URL", "http://localhost:5100")
STRIPE_SECRET_KEY = os.environ.get("STRIPE_SECRET_KEY", "").strip()
STRIPE_WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
STRIPE_READY = bool(STRIPE_SECRET_KEY)

if stripe and STRIPE_SECRET_KEY:
    stripe.api_key = STRIPE_SECRET_KEY

PLANS = {
    "monthly": {"name": "月度会员", "price": 39, "days": 30},
    "yearly": {"name": "年度会员", "price": 299, "days": 365},
}


# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────

def grant_membership(plan_key: str, user_id: str, order_no: str) -> str:
    """开通或续费会员，返回稳定 token。"""
    plan_key = plan_key if plan_key in PLANS else "monthly"
    days = PLANS[plan_key]["days"]
    member_token = hashlib.sha256(f"member:{user_id}".encode()).hexdigest()[:32]

    current = MEMBER_DB.get(member_token)
    base_ts = current["expire_ts"] if current and current["expire_ts"] > time.time() else time.time()

    MEMBER_DB[member_token] = {
        "uid": user_id,
        "plan": plan_key,
        "expire_ts": base_ts + days * 86400,
        "order_no": order_no,
    }
    return member_token


def stripe_request_via_curl(path: str, method: str = "GET", data: dict = None) -> dict:
    """在本机 Python SSL 有问题时，使用系统 curl 直连 Stripe。"""
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
        message = payload["error"].get("message", "Stripe API 返回错误")
        raise RuntimeError(message)
    return payload


def build_checkout_payload(plan_key: str, demo_uid: str) -> dict:
    """生成创建 Checkout Session 所需的表单参数。"""
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
        "line_items[0][price_data][product_data][name]": f"{plan['name']} · 分时回放会员 Demo",
        "line_items[0][price_data][product_data][description]": "支付成功后会自动回跳并生成会员 Token",
    }


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


def is_member(token: str) -> bool:
    """检查 token 是否为有效会员"""
    info = MEMBER_DB.get(token)
    if not info:
        return False
    return info["expire_ts"] > time.time()


def require_member(f):
    """装饰器：未付费用户返回 403"""
    @wraps(f)
    def wrapper(*args, **kwargs):
        token = request.headers.get("X-Member-Token") or request.args.get("token", "")
        if not is_member(token):
            return jsonify({"error": "请先开通会员", "code": 403}), 403
        return f(*args, **kwargs)
    return wrapper


# ──────────────────────────────────────────────
# 页面路由
# ──────────────────────────────────────────────

@app.route("/")
def index():
    return render_template(
        "demo_index.html",
        plans=PLANS,
        stripe_enabled=STRIPE_READY,
        stripe_python_available=stripe is not None,
        stripe_webhook_enabled=bool(STRIPE_WEBHOOK_SECRET),
        prefill_token=request.args.get("token", ""),
        payment_message=request.args.get("message", ""),
    )


# ──────────────────────────────────────────────
# Stripe Checkout Demo
# ──────────────────────────────────────────────

@app.route("/api/stripe/create-checkout-session", methods=["POST"])
def create_stripe_checkout_session():
    """创建 Stripe Checkout Session（测试模式）。"""
    data = request.get_json(silent=True) or {}
    plan_key = data.get("plan", "monthly")
    if plan_key not in PLANS:
        return jsonify({"error": "未知套餐"}), 400

    if not STRIPE_SECRET_KEY:
        return jsonify({
            "error": "未配置 STRIPE_SECRET_KEY，已保留本地模拟开通模式",
            "hint": "设置测试密钥后即可跳转到 Stripe Checkout",
            "demo_fallback": url_for("dev_activate", plan=plan_key, _external=True),
        }), 400

    demo_uid = data.get("uid") or f"demo_{uuid4().hex[:8]}"
    checkout_payload = build_checkout_payload(plan_key, demo_uid)

    try:
        if stripe is None:
            raise RuntimeError("stripe SDK 不可用，改用 curl fallback")

        checkout_session = stripe.checkout.Session.create(
            mode="payment",
            success_url=checkout_payload["success_url"],
            cancel_url=checkout_payload["cancel_url"],
            metadata={"plan_key": plan_key, "demo_uid": demo_uid},
            line_items=[{
                "quantity": 1,
                "price_data": {
                    "currency": "cny",
                    "unit_amount": checkout_payload["line_items[0][price_data][unit_amount]"],
                    "product_data": {
                        "name": checkout_payload["line_items[0][price_data][product_data][name]"],
                        "description": checkout_payload["line_items[0][price_data][product_data][description]"],
                    },
                },
            }],
        )
        return jsonify({"checkout_url": checkout_session.url, "transport": "stripe-sdk"})
    except Exception as sdk_error:
        try:
            checkout_session = stripe_request_via_curl(
                "/v1/checkout/sessions",
                method="POST",
                data=checkout_payload,
            )
            return jsonify({"checkout_url": checkout_session["url"], "transport": "curl-fallback"})
        except Exception as curl_error:
            return jsonify({
                "error": "Stripe Checkout 创建失败",
                "sdk_error": str(sdk_error),
                "curl_error": str(curl_error),
            }), 502


@app.route("/payment/success")
def payment_success():
    """Stripe 支付成功回跳：读取 Session 并激活会员。"""
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
    user_id = stripe_value(metadata, "demo_uid") or stripe_value(checkout_session, "customer_email") or "stripe_user"
    order_no = stripe_value(checkout_session, "payment_intent") or session_id
    member_token = grant_membership(plan_key, user_id, order_no)

    return redirect(url_for(
        "index",
        token=member_token,
        message=f"Stripe 支付成功，已开通 {PLANS[plan_key]['name']}。",
    ))


@app.route("/payment/cancel")
def payment_cancel():
    return redirect(url_for("index", message="已取消支付，未扣款。"))


@app.route("/webhook/stripe", methods=["POST"])
def stripe_webhook():
    """真实项目建议使用 webhook 做最终入账确认。"""
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
        customer_details = stripe_value(session_obj, "customer_details", {}) or {}
        user_id = stripe_value(metadata, "demo_uid") or stripe_value(customer_details, "email") or "stripe_webhook_user"
        order_no = stripe_value(session_obj, "payment_intent") or stripe_value(session_obj, "id") or f"stripe_{int(time.time())}"
        grant_membership(plan_key, user_id, order_no)
    return jsonify({"received": True})


# ──────────────────────────────────────────────
# 爱发电 Webhook（付费成功后爱发电主动回调此地址）
# 文档: https://afdian.com/p/9c65d9be67df11ed8e3552540025c377
# ──────────────────────────────────────────────

@app.route("/webhook/afdian", methods=["POST"])
def afdian_webhook():
    """接收爱发电付费通知，激活会员"""
    data = request.get_json(silent=True) or {}

    received_sign = data.get("sign", "")
    ts = str(data.get("ts", ""))
    params_str = json.dumps(data.get("data", {}), separators=(",", ":"), sort_keys=True)
    expected_sign = hashlib.md5(f"{AFDIAN_TOKEN}params{params_str}ts{ts}".encode()).hexdigest()

    if not hmac.compare_digest(received_sign, expected_sign):
        return jsonify({"ec": 400, "em": "签名错误"}), 400

    order = data.get("data", {}).get("order", {})
    plan_id = order.get("plan_id", "")
    user_id = order.get("user_id", "") or "afdian_user"
    out_trade_no = order.get("out_trade_no", f"afdian_{int(time.time())}")

    plan_key = "yearly" if "year" in plan_id.lower() else "monthly"
    member_token = grant_membership(plan_key, user_id, out_trade_no)

    print(f"[Webhook] 新会员: uid={user_id} plan={plan_key} token={member_token}")
    return jsonify({"ec": 200, "em": "success"})


# ──────────────────────────────────────────────
# 开发调试：手动激活会员（生产环境删掉）
# ──────────────────────────────────────────────

@app.route("/dev/activate")
def dev_activate():
    """调试用：生成一个测试会员 token"""
    plan_key = request.args.get("plan", "monthly")
    token = grant_membership(
        plan_key=plan_key,
        user_id=f"dev_user_{plan_key}",
        order_no=f"DEV-{int(time.time())}",
    )
    days = PLANS.get(plan_key, PLANS["monthly"])["days"]
    return jsonify({"token": token, "plan": plan_key, "expire_days": days})


@app.route("/dev/members")
def dev_members():
    """调试用：查看当前所有会员"""
    result = {}
    now = time.time()
    for token, info in MEMBER_DB.items():
        result[token] = {
            **info,
            "valid": info["expire_ts"] > now,
            "expire_in": f"{int((info['expire_ts'] - now) / 3600)} 小时后",
        }
    return jsonify(result)


# ──────────────────────────────────────────────
# 受保护的 API（付费才能访问）
# ──────────────────────────────────────────────

@app.route("/api/tick/realtime")
@require_member
def api_tick_realtime():
    """实时 tick（付费功能，免费版无法访问）"""
    fake_ticks = [
        {"ts": "09:30:01", "price": 12.50, "vol": 1000, "amount": 12500},
        {"ts": "09:30:03", "price": 12.52, "vol": 500, "amount": 6260},
        {"ts": "09:30:05", "price": 12.48, "vol": 800, "amount": 9984},
    ]
    return jsonify({"code": "sz300502", "ticks": fake_ticks})


@app.route("/api/tick/delayed")
def api_tick_delayed():
    """延迟 15 分钟数据（免费功能）"""
    fake_ticks = [
        {"ts": "09:15:01", "price": 12.30, "vol": 2000, "amount": 24600},
        {"ts": "09:15:03", "price": 12.32, "vol": 1500, "amount": 18480},
    ]
    return jsonify({"code": "sz300502", "ticks": fake_ticks, "delay": "15min"})


@app.route("/api/verify")
def api_verify():
    """前端用于验证 token 是否有效"""
    token = request.args.get("token", "")
    if not token:
        return jsonify({"valid": False, "reason": "缺少 token"})
    info = MEMBER_DB.get(token)
    if not info:
        return jsonify({"valid": False, "reason": "token 不存在"})
    if info["expire_ts"] <= time.time():
        return jsonify({"valid": False, "reason": "会员已过期"})
    return jsonify({
        "valid": True,
        "plan": PLANS[info["plan"]]["name"],
        "expire_in": f"{int((info['expire_ts'] - time.time()) / 3600)} 小时",
    })


if __name__ == "__main__":
    print(f"[demo] Stripe ready: {STRIPE_READY}")
    app.run(host="0.0.0.0", port=5100, debug=True)
