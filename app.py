"""
Flask 后端
启动: python app.py
访问: http://localhost:5000
"""

import pymysql
import pymysql.cursors
import os
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# MySQL 连接配置，可通过环境变量覆盖
DB_CONFIG = {
    "host":     os.environ.get("MYSQL_HOST", "127.0.0.1"),
    "port":     int(os.environ.get("MYSQL_PORT", "3306")),
    "user":     os.environ.get("MYSQL_USER", "root"),
    "password": os.environ.get("MYSQL_PASSWORD", ""),
    "database": os.environ.get("MYSQL_DB", "stock_replay"),
    "charset":  "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
}


def query(sql: str, params: tuple = ()):
    conn = pymysql.connect(**DB_CONFIG)
    cur = conn.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall()
    conn.close()
    return rows


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/dates")
def api_dates():
    """返回某支股票所有有数据的日期"""
    code = request.args.get("code", "sz300502")
    rows = query(
        "SELECT DISTINCT trade_date FROM tick WHERE code=%s ORDER BY trade_date DESC",
        (code,)
    )
    return jsonify([r["trade_date"] for r in rows])


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
    """
    返回某支股票某天的所有分时 tick
    参数: code, date
    返回: [{ts, price, volume, amount, open, high, low, pre_close}, ...]
    """
    code = request.args.get("code", "sz300502")
    date = request.args.get("date", "")
    if not date:
        return jsonify([])
    rows = query(
        """SELECT ts, price, volume, amount, `open`, high, low, pre_close,
                  b1p, b1v, b2p, b2v, b3p, b3v, b4p, b4v, b5p, b5v,
                  a1p, a1v, a2p, a2v, a3p, a3v, a4p, a4v, a5p, a5v
           FROM tick WHERE code=%s AND trade_date=%s ORDER BY ts""",
        (code, date)
    )
    return jsonify(rows)


@app.route("/api/summary")
def api_summary():
    """
    返回某支股票某天的基本统计（用于页面顶部信息栏）
    """
    code = request.args.get("code", "sz300502")
    date = request.args.get("date", "")
    if not date:
        return jsonify({})
    rows = query(
        """SELECT price, volume, amount, `open`, high, low, pre_close, ts
           FROM tick WHERE code=%s AND trade_date=%s ORDER BY ts""",
        (code, date)
    )
    if not rows:
        return jsonify({})
    last   = rows[-1]
    pre_close = rows[0]["pre_close"]
    high   = max(r["price"] for r in rows)
    low    = min(r["price"] for r in rows)
    total_vol = sum(r["volume"] for r in rows)
    total_amt = sum(r["amount"] for r in rows)
    close  = last["price"]
    chg    = round(close - pre_close, 2)
    pct    = round(chg / pre_close * 100, 2) if pre_close else 0
    return jsonify({
        "code":      code,
        "date":      date,
        "open":      rows[0]["open"],
        "pre_close": pre_close,
        "close":     close,
        "high":      high,
        "low":       low,
        "volume":    round(total_vol),
        "amount":    round(total_amt),
        "chg":       chg,
        "pct":       pct,
    })


if __name__ == "__main__":
    try:
        conn = pymysql.connect(**{k: v for k, v in DB_CONFIG.items() if k != 'cursorclass'})
        conn.close()
    except Exception as e:
        print(f"[WARN] 无法连接 MySQL：{e}")
        print("       请确保 MySQL 已启动，并创建数据库: CREATE DATABASE stock_replay;")
    app.run(debug=True, port=5001)
