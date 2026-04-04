"""
分时数据采集器

单只股票模式：
    python collector.py --code sz300502

全A股模式（自动从东方财富获取股票列表，批量采集）：
    python collector.py --all
    python collector.py --all --interval 10
"""

import pymysql
import pymysql.cursors
import time
import datetime
import argparse
import requests
import os
import re
from pathlib import Path
from typing import Optional, List, Dict

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


def get_conn():
    return pymysql.connect(**DB_CONFIG)

# 新浪实时行情接口（支持批量，逗号分隔）
SINA_URL = "http://hq.sinajs.cn/list={code}"
HEADERS = {
    "Referer": "https://finance.sina.com.cn",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
}

BATCH_SIZE = 200
BASE_DIR = Path(__file__).resolve().parents[1]
STOCK_LIST_CACHE = str(BASE_DIR / "data" / "stock_list.json")

# 东方财富股票列表接口（主备两个地址）
EMF_LIST_URLS = [
    (
        "http://push2.eastmoney.com/api/qt/clist/get"
        "?pn={page}&pz={size}&po=1&np=1"
        "&ut=bd1d9ddb04089700cf9c27f6f7426281"
        "&fltt=2&invt=2&fid=f3"
        "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048"
        "&fields=f12,f13,f14"
    ),
    (
        "http://80.push2.eastmoney.com/api/qt/clist/get"
        "?pn={page}&pz={size}&po=1&np=1"
        "&ut=bd1d9ddb04089700cf9c27f6f7426281"
        "&fltt=2&invt=2&fid=f3"
        "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048"
        "&fields=f12,f13,f14"
    ),
]


def init_db():
    conn = get_conn()
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
    # 迁移：为旧数据库补加买卖五档字段
    cur.execute("""
        SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tick'
    """)
    existing_cols = {row['COLUMN_NAME'] for row in cur.fetchall()}
    ob_cols = ["b1p","b1v","b2p","b2v","b3p","b3v","b4p","b4v","b5p","b5v",
               "a1p","a1v","a2p","a2v","a3p","a3v","a4p","a4v","a5p","a5v"]
    for col in ob_cols:
        if col not in existing_cols:
            cur.execute(f"ALTER TABLE tick ADD COLUMN {col} DOUBLE")
    # 股票名称缓存表
    cur.execute("""
        CREATE TABLE IF NOT EXISTS stock_name (
            code VARCHAR(20) PRIMARY KEY,
            name VARCHAR(50) NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    conn.commit()
    conn.close()


def get_all_codes() -> List[Dict]:
    """从东方财富获取全A股代码列表，优先读当日本地缓存。"""
    import json

    # 读缓存（当天有效）
    today = datetime.date.today().isoformat()
    if os.path.exists(STOCK_LIST_CACHE):
        try:
            with open(STOCK_LIST_CACHE, "r", encoding="utf-8") as f:
                cached = json.load(f)
            stocks = cached.get("stocks", [])
            if cached.get("date") == today and len(stocks) >= 3000:
                print(f"[INFO] 使用本地股票列表缓存（{len(stocks)} 只）")
                return stocks
            elif cached.get("date") == today and stocks:
                print(f"[WARN] 本地缓存只有 {len(stocks)} 只，重新拉取")
            elif len(stocks) >= 3000:
                # 网络不稳定时，允许使用最近一天的足量缓存，避免采集器因拉取列表失败而退出。
                print(f"[WARN] 使用过期股票列表缓存（{cached.get('date')}，{len(stocks)} 只）")
                return stocks
        except Exception:
            pass

    result = []
    market_map = {0: "sz", 1: "sh"}
    page_size = 500
    print("[INFO] 正在从东方财富获取全A股列表...")

    for base_url in EMF_LIST_URLS:
        result = []
        page = 1
        success = True
        while True:
            url = base_url.format(page=page, size=page_size)
            try:
                resp = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=10)
                if not resp.text.strip():
                    break
                data = resp.json()
            except Exception as e:
                print(f"[WARN] page={page} 失败: {e}")
                if page == 1:
                    success = False  # 第一页就失败，换备用地址
                break
            items = (data.get("data") or {}).get("diff") or []
            if not items:
                break
            for item in items:
                mkt = item.get("f13", -1)
                code_num = item.get("f12", "")
                name = item.get("f14", "")
                if mkt in market_map and code_num:
                    result.append({"code": f"{market_map[mkt]}{code_num}", "name": name})
            total = (data.get("data") or {}).get("total", 0)
            if len(result) >= total:
                break
            page += 1

        if result and success:
            break  # 主地址成功，不用备用

    if not result:
        print("[ERROR] 无法获取股票列表，主备地址均失败")
        return []

    print(f"[INFO] 共获取 {len(result)} 只股票")

    # 写缓存
    try:
        os.makedirs(os.path.dirname(STOCK_LIST_CACHE), exist_ok=True)
        with open(STOCK_LIST_CACHE, "w", encoding="utf-8") as f:
            json.dump({"date": today, "stocks": result}, f, ensure_ascii=False)
    except Exception as e:
        print(f"[WARN] 缓存写入失败: {e}")

    return result


def fetch_batch(codes: List[str]) -> Dict[str, dict]:
    """
    批量从新浪拉取行情，返回 {code: {name, price, ...}, ...}
    codes 格式: ['sz000001', 'sh600000', ...]
    DNS失败时自动重试最多3次。
    """
    batch_str = ",".join(codes)
    url = SINA_URL.format(code=batch_str)
    text = None
    for attempt in range(3):
        try:
            resp = requests.get(url, headers=HEADERS, timeout=10)
            resp.encoding = "gbk"
            text = resp.text
            break
        except Exception as e:
            wait = 5 * (attempt + 1)  # 5s, 10s, 15s
            print(f"[WARN] 批量请求失败(第{attempt+1}次): {e}，{wait}s后重试...")
            time.sleep(wait)
    if text is None:
        print(f"[ERROR] 批量请求连续失败3次，跳过本批次")
        return {}

    result = {}
    # 每行格式: var hq_str_sz000001="平安银行,11.09,...,2026-04-01,09:30:03,...";
    for line in text.strip().split("\n"):
        # 提取代码
        code_m = re.search(r'hq_str_([^=]+)=', line)
        val_m  = re.search(r'"([^"]+)"', line)
        if not code_m or not val_m:
            continue
        code  = code_m.group(1)
        parts = val_m.group(1).split(",")
        if len(parts) < 32 or not parts[0]:
            continue
        try:
            price = float(parts[3])
            if price <= 0:
                continue  # 停牌或无效
            def _f(idx): return float(parts[idx]) if len(parts) > idx else 0.0
            result[code] = {
                "name":      parts[0],
                "open":      float(parts[1]),
                "pre_close": float(parts[2]),
                "price":     price,
                "high":      float(parts[4]),
                "low":       float(parts[5]),
                "volume":    float(parts[8]),
                "amount":    float(parts[9]),
                "date":      parts[30],
                "time":      parts[31],
                # 买一~买五：量(手), 价
                "b1v": _f(10), "b1p": _f(11),
                "b2v": _f(12), "b2p": _f(13),
                "b3v": _f(14), "b3p": _f(15),
                "b4v": _f(16), "b4p": _f(17),
                "b5v": _f(18), "b5p": _f(19),
                # 卖一~卖五：量(手), 价
                "a1v": _f(20), "a1p": _f(21),
                "a2v": _f(22), "a2p": _f(23),
                "a3v": _f(24), "a3p": _f(25),
                "a4v": _f(26), "a4p": _f(27),
                "a5v": _f(28), "a5p": _f(29),
            }
        except (ValueError, IndexError):
            continue
    return result


def save_batch(batch_data: Dict[str, dict], collect_ts: str = None):
    """
    批量写入数据库。
    collect_ts: 采集时刻（服务器时间），格式 'YYYY-MM-DD HH:MM:SS'。
                以采集时间为 ts，保证每轮采集都能生成新行。
                为 None 时回退到新浪返回的交易时间（兼容快照脚本）。
    """
    if not batch_data:
        return
    conn = get_conn()
    cur = conn.cursor()
    rows = []
    names = []
    for code, d in batch_data.items():
        ts = collect_ts if collect_ts else f"{d['date']} {d['time']}"
        rows.append((
            code, d["date"], ts,
            d["price"], d["volume"], d["amount"],
            d["open"], d["high"], d["low"], d["pre_close"],
            d.get("b1p"), d.get("b1v"), d.get("b2p"), d.get("b2v"),
            d.get("b3p"), d.get("b3v"), d.get("b4p"), d.get("b4v"),
            d.get("b5p"), d.get("b5v"),
            d.get("a1p"), d.get("a1v"), d.get("a2p"), d.get("a2v"),
            d.get("a3p"), d.get("a3v"), d.get("a4p"), d.get("a4v"),
            d.get("a5p"), d.get("a5v"),
        ))
        names.append((code, d["name"]))
    cur.executemany("""
        INSERT INTO tick
        (code, trade_date, ts, price, volume, amount, `open`, high, low, pre_close,
         b1p, b1v, b2p, b2v, b3p, b3v, b4p, b4v, b5p, b5v,
         a1p, a1v, a2p, a2v, a3p, a3v, a4p, a4v, a5p, a5v)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        ON DUPLICATE KEY UPDATE
          price=VALUES(price), volume=VALUES(volume), amount=VALUES(amount),
          `open`=VALUES(`open`), high=VALUES(high), low=VALUES(low),
          b1p=VALUES(b1p), b1v=VALUES(b1v), b2p=VALUES(b2p), b2v=VALUES(b2v),
          b3p=VALUES(b3p), b3v=VALUES(b3v), b4p=VALUES(b4p), b4v=VALUES(b4v),
          b5p=VALUES(b5p), b5v=VALUES(b5v),
          a1p=VALUES(a1p), a1v=VALUES(a1v), a2p=VALUES(a2p), a2v=VALUES(a2v),
          a3p=VALUES(a3p), a3v=VALUES(a3v), a4p=VALUES(a4p), a4v=VALUES(a4v),
          a5p=VALUES(a5p), a5v=VALUES(a5v)
    """, rows)
    cur.executemany("""
        INSERT INTO stock_name (code, name) VALUES (%s, %s)
        ON DUPLICATE KEY UPDATE name=VALUES(name)
    """, names)
    conn.commit()
    conn.close()
    return len(rows)


def get_active_codes(all_codes: List[str], min_amount: float = 1e8) -> List[str]:
    """
    返回各股票自身最近一个交易日总成交额 >= min_amount 的股票代码列表。
    每只股票独立取其最新 trade_date，避免因个别股票当日漏采而被错误剔除。
    若数据库中无历史数据（首次运行），返回全部代码。
    """
    try:
        conn = get_conn()
        cur = conn.cursor()
        # 检查是否有任何历史数据
        cur.execute("SELECT MAX(trade_date) AS d FROM tick")
        row = cur.fetchone()
        if not (row and row["d"]):
            conn.close()
            print("[INFO] 无历史数据，本日采集全部股票")
            return all_codes
        # 每只股票取其自身最新一天的最大累计成交额
        # 用 JOIN 代替相关子查询，在大表上性能更优
        cur.execute("""
            SELECT t.code, MAX(t.amount) AS total_amount
            FROM tick t
            INNER JOIN (
                SELECT code, MAX(trade_date) AS max_date
                FROM tick
                GROUP BY code
            ) m ON t.code = m.code AND t.trade_date = m.max_date
            GROUP BY t.code
        """)
        active = {r["code"] for r in cur.fetchall() if (r["total_amount"] or 0) >= min_amount}
        conn.close()
        result = [c for c in all_codes if c in active]
        filtered = len(all_codes) - len(result)
        print(f"[INFO] 按各股自身最新交易日成交额过滤："
              f"保留 {len(result)} 只，排除 {filtered} 只（<{min_amount/1e8:.0f}亿）")
        return result if result else all_codes  # 保底：若全被过滤则返回全部
    except Exception as e:
        print(f"[WARN] 活跃股票过滤失败：{e}，使用全部代码")
        return all_codes


def fetch_tick(code: str) -> Optional[dict]:
    """单只股票拉取（保留兼容）"""
    result = fetch_batch([code])
    return result.get(code)


def save_tick(code: str, data: dict):
    """单只股票写入（保留兼容）"""
    save_batch({code: data})


def is_trading() -> bool:
    """判断当前是否在交易时间（工作日 9:15-15:05，留出缓冲）"""
    now = datetime.datetime.now()
    if now.weekday() >= 5:  # 周六日
        return False
    t = now.time()
    morning_start = datetime.time(9, 15)
    morning_end   = datetime.time(11, 35)
    afternoon_start = datetime.time(12, 55)
    afternoon_end   = datetime.time(15, 5)
    return (morning_start <= t <= morning_end) or (afternoon_start <= t <= afternoon_end)


def run(code: str, interval: int = 3):
    """单只股票采集模式"""
    init_db()
    print(f"[INFO] 开始采集 {code}，间隔 {interval}s，Ctrl+C 停止")
    while True:
        if is_trading():
            data = fetch_tick(code)
            if data:
                save_tick(code, data)
                print(f"[{data['date']} {data['time']}] {data['name']} "
                      f"价格={data['price']} 成交量={data['volume']}手")
        else:
            print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] 非交易时间，等待...")
            time.sleep(60)
            continue
        time.sleep(interval)


def run_all(interval: int = 10):
    """全A股批量采集模式"""
    init_db()
    stock_list = get_all_codes()
    if not stock_list:
        print("[ERROR] 无法获取股票列表，退出")
        return

    all_codes = [s["code"] for s in stock_list]
    print(f"[INFO] 全A股模式：{len(all_codes)} 只，间隔 {interval}s，Ctrl+C 停止")

    active_codes = get_active_codes(all_codes)  # 首次按前日成交额过滤
    current_date = datetime.date.today()

    while True:
        if not is_trading():
            print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] 非交易时间，等待...")
            time.sleep(60)
            continue

        # 每天第一轮刷新白名单
        today = datetime.date.today()
        if today != current_date:
            current_date = today
            active_codes = get_active_codes(all_codes)

        round_start = time.time()
        # 以本轮采集开始时刻作为所有 tick 的时间戳
        collect_ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        total_saved = 0
        valid_count = 0

        # 分批请求
        for i in range(0, len(active_codes), BATCH_SIZE):
            batch = active_codes[i:i + BATCH_SIZE]
            batch_data = fetch_batch(batch)
            n = save_batch(batch_data, collect_ts=collect_ts)
            total_saved += n or 0
            valid_count += len(batch_data)

        elapsed = time.time() - round_start
        now_str = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{now_str}] 采集完成：{valid_count} 只有效 / {len(active_codes)} 只，写入 {total_saved} 条，耗时 {elapsed:.1f}s")

        # 动态等待，确保整体间隔为 interval 秒
        wait = max(1, interval - elapsed)
        time.sleep(wait)


def main():
    parser = argparse.ArgumentParser(description="分时数据采集器")
    parser.add_argument("--code", default="", help="单只股票代码，例如 sz300502")
    parser.add_argument("--all", action="store_true", help="采集全A股（约5800只）")
    parser.add_argument("--interval", type=int, default=10, help="采集间隔（秒），默认10")
    args = parser.parse_args()
    try:
        if args.all:
            run_all(args.interval)
        elif args.code:
            run(args.code, args.interval)
        else:
            parser.print_help()
    except KeyboardInterrupt:
        print("\n[INFO] 采集已停止")


if __name__ == "__main__":
    main()
