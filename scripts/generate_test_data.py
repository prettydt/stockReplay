"""
测试数据生成器

生成模拟的股票分时数据写入 MySQL，用于本地开发调试。
用法：
    python scripts/generate_test_data.py

数据规模：
    5 只股票 × 3 个交易日 × ~240 个 tick（每分钟一条）≈ 3600 行
"""

import pymysql
import pymysql.cursors
import os
import random
import datetime
import math

# ──────────────────────────────────────────
# 数据库配置（与 app.py / collector.py 保持一致）
# ──────────────────────────────────────────
DB_CONFIG = {
    "host":     os.environ.get("MYSQL_HOST", "127.0.0.1"),
    "port":     int(os.environ.get("MYSQL_PORT", "3306")),
    "user":     os.environ.get("MYSQL_USER", "root"),
    "password": os.environ.get("MYSQL_PASSWORD", ""),
    "database": os.environ.get("MYSQL_DB", "stock_replay"),
    "charset":  "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
}

# ──────────────────────────────────────────
# 模拟股票基础信息
# ──────────────────────────────────────────
STOCKS = [
    {"code": "sz000001", "name": "平安银行",  "base_price": 11.50},
    {"code": "sh600519", "name": "贵州茅台",  "base_price": 1680.00},
    {"code": "sz300502", "name": "新易盛",    "base_price": 28.30},
    {"code": "sh601318", "name": "中国平安",  "base_price": 52.80},
    {"code": "sz000858", "name": "五粮液",    "base_price": 148.60},
]

# 生成 3 个交易日（最近的工作日）
def last_n_trading_days(n: int):
    days = []
    d = datetime.date(2026, 3, 30)  # 以 2026-03-30 为基准往前推
    while len(days) < n:
        if d.weekday() < 5:  # 跳过周末
            days.append(d)
        d -= datetime.timedelta(days=1)
    return sorted(days)

TRADE_DATES = last_n_trading_days(3)

# ──────────────────────────────────────────
# 建表（与 collector.py 保持一致）
# ──────────────────────────────────────────
def init_db(conn):
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS tick (
            id         INT AUTO_INCREMENT PRIMARY KEY,
            code       VARCHAR(20) NOT NULL,
            trade_date VARCHAR(10) NOT NULL,
            ts         VARCHAR(20) NOT NULL,
            price      DOUBLE NOT NULL,
            volume     DOUBLE NOT NULL,
            amount     DOUBLE NOT NULL,
            `open`     DOUBLE NOT NULL,
            high       DOUBLE NOT NULL,
            low        DOUBLE NOT NULL,
            pre_close  DOUBLE NOT NULL,
            b1p DOUBLE, b1v DOUBLE, b2p DOUBLE, b2v DOUBLE,
            b3p DOUBLE, b3v DOUBLE, b4p DOUBLE, b4v DOUBLE, b5p DOUBLE, b5v DOUBLE,
            a1p DOUBLE, a1v DOUBLE, a2p DOUBLE, a2v DOUBLE,
            a3p DOUBLE, a3v DOUBLE, a4p DOUBLE, a4v DOUBLE, a5p DOUBLE, a5v DOUBLE,
            UNIQUE KEY ux_tick_code_ts (code, ts)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS stock_name (
            code VARCHAR(20) PRIMARY KEY,
            name VARCHAR(50) NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    conn.commit()


# ──────────────────────────────────────────
# 价格随机游走（带均值回归）
# ──────────────────────────────────────────
def random_walk(start_price: float, n_steps: int, volatility: float = 0.0008):
    """生成 n_steps 步的价格序列（随机游走 + 均值回归）"""
    prices = [start_price]
    p = start_price
    for _ in range(n_steps - 1):
        # 均值回归：偏离越大越容易回归
        drift = (start_price - p) * 0.003
        chg = drift + random.gauss(0, p * volatility)
        p = max(p * 0.9, min(p * 1.1, p + chg))  # 单日振幅限制在 ±10%
        p = round(p, 2)
        prices.append(p)
    return prices


# ──────────────────────────────────────────
# 生成订单簿五档（围绕当前价格）
# ──────────────────────────────────────────
def gen_orderbook(price: float, tick_size: float = 0.01):
    """生成模拟买五/卖五档位"""
    ob = {}
    for i in range(1, 6):
        bp = round(price - i * tick_size, 2)
        ap = round(price + i * tick_size, 2)
        ob[f"b{i}p"] = bp
        ob[f"b{i}v"] = random.randint(100, 5000) * 100
        ob[f"a{i}p"] = ap
        ob[f"a{i}v"] = random.randint(100, 5000) * 100
    return ob


# ──────────────────────────────────────────
# 生成一只股票某天的所有 tick
# ──────────────────────────────────────────
def gen_day_ticks(code: str, trade_date: datetime.date,
                  open_price: float, pre_close: float):
    """
    生成交易日分时数据（每分钟一条）
    上午：09:30 ~ 11:29（60 条）
    下午：13:00 ~ 14:59（60 条）
    共 120 条
    """
    sessions = [
        (datetime.time(9, 30),  datetime.time(11, 29)),
        (datetime.time(13, 0), datetime.time(14, 59)),
    ]

    # 统一生成 120 步价格序列
    prices = random_walk(open_price, 120)
    high = open_price
    low  = open_price

    rows = []
    price_idx = 0
    for start_t, end_t in sessions:
        cur_t = datetime.datetime.combine(trade_date, start_t)
        end_dt = datetime.datetime.combine(trade_date, end_t)
        while cur_t <= end_dt and price_idx < len(prices):
            p = prices[price_idx]
            high = max(high, p)
            low  = min(low, p)
            volume = random.randint(5000, 50000) * 100   # 手→股
            amount = round(p * volume, 2)
            ob = gen_orderbook(p)
            ts_str = cur_t.strftime("%Y-%m-%d %H:%M:%S")
            rows.append((
                code,
                trade_date.strftime("%Y-%m-%d"),
                ts_str,
                p, volume, amount,
                open_price, high, low, pre_close,
                ob["b1p"], ob["b1v"], ob["b2p"], ob["b2v"],
                ob["b3p"], ob["b3v"], ob["b4p"], ob["b4v"],
                ob["b5p"], ob["b5v"],
                ob["a1p"], ob["a1v"], ob["a2p"], ob["a2v"],
                ob["a3p"], ob["a3v"], ob["a4p"], ob["a4v"],
                ob["a5p"], ob["a5v"],
            ))
            cur_t += datetime.timedelta(minutes=1)
            price_idx += 1
    return rows


# ──────────────────────────────────────────
# 主逻辑
# ──────────────────────────────────────────
def main():
    conn = pymysql.connect(**DB_CONFIG)
    print("[INFO] 已连接数据库，初始化表结构...")
    init_db(conn)

    cur = conn.cursor()

    # 写入股票名称
    cur.executemany(
        "INSERT INTO stock_name (code, name) VALUES (%s, %s) "
        "ON DUPLICATE KEY UPDATE name=VALUES(name)",
        [(s["code"], s["name"]) for s in STOCKS]
    )
    conn.commit()
    print(f"[INFO] 股票名称表写入 {len(STOCKS)} 条")

    total_rows = 0
    for stock in STOCKS:
        code       = stock["code"]
        base_price = stock["base_price"]
        # 每个交易日的前收盘价从 base_price 出发
        pre_close  = base_price

        for trade_date in TRADE_DATES:
            # 开盘价在前收盘价基础上随机小幅跳空
            open_price = round(pre_close * (1 + random.uniform(-0.02, 0.02)), 2)

            rows = gen_day_ticks(code, trade_date, open_price, pre_close)
            if not rows:
                continue

            cur.executemany("""
                INSERT INTO tick
                (code, trade_date, ts, price, volume, amount, `open`, high, low, pre_close,
                 b1p, b1v, b2p, b2v, b3p, b3v, b4p, b4v, b5p, b5v,
                 a1p, a1v, a2p, a2v, a3p, a3v, a4p, a4v, a5p, a5v)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,
                        %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,
                        %s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON DUPLICATE KEY UPDATE
                  price=VALUES(price), volume=VALUES(volume), amount=VALUES(amount),
                  high=VALUES(high), low=VALUES(low)
            """, rows)
            conn.commit()
            total_rows += len(rows)

            # 以当天最后价格作为下一天的前收盘
            pre_close = rows[-1][3]  # price 字段位于第 4 个
            print(f"  [{code}] {trade_date}  {len(rows)} 条  最后价={pre_close}")

    conn.close()
    print(f"\n[DONE] 共写入 {total_rows} 条 tick 数据")
    print(f"       股票: {[s['code'] for s in STOCKS]}")
    print(f"       日期: {[str(d) for d in TRADE_DATES]}")


if __name__ == "__main__":
    main()
