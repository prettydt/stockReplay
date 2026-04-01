"""
Flask 后端
启动: python app.py
访问: http://localhost:5000
"""

import sqlite3
import os
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)
DB_PATH = os.path.join(os.path.dirname(__file__), "data", "stock.db")


def query(sql: str, params: tuple = ()):
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/dates")
def api_dates():
    """返回某支股票所有有数据的日期"""
    code = request.args.get("code", "sz300502")
    rows = query(
        "SELECT DISTINCT trade_date FROM tick WHERE code=? ORDER BY trade_date DESC",
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
        """SELECT ts, price, volume, amount, open, high, low, pre_close,
                  b1p, b1v, b2p, b2v, b3p, b3v, b4p, b4v, b5p, b5v,
                  a1p, a1v, a2p, a2v, a3p, a3v, a4p, a4v, a5p, a5v
           FROM tick WHERE code=? AND trade_date=? ORDER BY ts""",
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
        """SELECT price, volume, amount, open, high, low, pre_close, ts
           FROM tick WHERE code=? AND trade_date=? ORDER BY ts""",
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
    # 数据库不存在时给出提示
    if not os.path.exists(DB_PATH):
        print("[WARN] 数据库不存在，请先运行 collector.py 采集数据")
        print("       示例: python collector.py --code sz300502")
    app.run(debug=True, port=5000)
