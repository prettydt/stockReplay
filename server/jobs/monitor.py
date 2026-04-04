"""
采集监控器

目标：尽可能保证“完整采集一天分时数据”。
做法：
1) 交易时段每分钟检查全局写入是否持续推进（是否断流）。
2) 重点股票（前一交易日成交额TOP）检查是否跟上当前时刻。
3) 收盘后输出当日完整性报告与告警。

运行示例：
    python monitor.py --interval 60
"""

import argparse
import datetime
import json
import os
import time
from typing import Dict, List

import pymysql
import pymysql.cursors


DB_CONFIG = {
    "host": os.environ.get("MYSQL_HOST", "127.0.0.1"),
    "port": int(os.environ.get("MYSQL_PORT", "3306")),
    "user": os.environ.get("MYSQL_USER", "root"),
    "password": os.environ.get("MYSQL_PASSWORD", ""),
    "database": os.environ.get("MYSQL_DB", "stock_replay"),
    "charset": "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
    "connect_timeout": 5,
    "read_timeout": 30,
    "write_timeout": 30,
}

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA_DIR = os.path.join(BASE_DIR, "data")
STATUS_FILE = os.path.join(DATA_DIR, "monitor_status.json")
ALERT_LOG_FILE = os.path.join(DATA_DIR, "monitor_alerts.log")
SUMMARY_FILE = os.path.join(DATA_DIR, "monitor_summary.json")


def get_conn():
    return pymysql.connect(**DB_CONFIG)


def now_ts() -> str:
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def trading_windows():
    return [
        (datetime.time(9, 15), datetime.time(11, 35)),
        (datetime.time(12, 55), datetime.time(15, 5)),
    ]


def is_trading_time(t: datetime.datetime = None) -> bool:
    t = t or datetime.datetime.now()
    if t.weekday() >= 5:
        return False
    now_t = t.time()
    for start, end in trading_windows():
        if start <= now_t <= end:
            return True
    return False


def should_run_eod_check(t: datetime.datetime = None) -> bool:
    t = t or datetime.datetime.now()
    if t.weekday() >= 5:
        return False
    return t.time() >= datetime.time(15, 10)


def ensure_data_dir():
    os.makedirs(DATA_DIR, exist_ok=True)


def write_alert(level: str, msg: str):
    line = f"[{now_ts()}] [{level}] {msg}"
    print(line)
    ensure_data_dir()
    with open(ALERT_LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def write_status(payload: Dict):
    ensure_data_dir()
    payload = dict(payload)
    payload["updated_at"] = now_ts()
    with open(STATUS_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def fetch_watch_codes(limit: int = 30) -> List[str]:
    """取最近交易日成交额最高的一批股票作为重点监控对象。"""
    conn = get_conn()
    cur = conn.cursor()
    try:
        cur.execute("SELECT MAX(trade_date) AS d FROM tick")
        row = cur.fetchone() or {}
        last_date = row.get("d")
        if not last_date:
            return []

        # 可能在大表上较慢，先尝试按成交额选重点股票。
        cur.execute(
            """
            SELECT code, MAX(amount) AS total_amount
            FROM tick
            WHERE trade_date=%s
            GROUP BY code
            ORDER BY total_amount DESC
            LIMIT %s
            """,
            (last_date, limit),
        )
        result = [r["code"] for r in cur.fetchall()]
        if result:
            return result
    except Exception as e:
        write_alert("WARN", f"重点股票按成交额选取失败，降级为静态名单: {e}")
    finally:
        conn.close()

    # 降级：使用 stock_name 前 N 只，避免监控启动被卡住。
    conn = get_conn()
    cur = conn.cursor()
    try:
        cur.execute("SELECT code FROM stock_name ORDER BY code LIMIT %s", (limit,))
        return [r["code"] for r in cur.fetchall()]
    except Exception as e:
        write_alert("WARN", f"重点股票静态名单选取失败: {e}")
        return []
    finally:
        conn.close()


def get_global_metrics(today: str) -> Dict:
    """轻量实时指标：避免每分钟全表聚合造成超时。"""
    conn = get_conn()
    cur = conn.cursor()

    cur.execute(
        """
        SELECT MAX(ts) AS max_ts
        FROM tick
        WHERE trade_date=%s
        """,
        (today,),
    )
    base = cur.fetchone() or {}

    cur.execute(
        """
                SELECT COUNT(*) AS rows_5m
        FROM tick
        WHERE ts >= NOW() - INTERVAL 5 MINUTE
          AND trade_date=%s
        """,
        (today,),
    )
    recent = cur.fetchone() or {}

    conn.close()

    max_ts = base.get("max_ts")
    lag_seconds = None
    if max_ts:
        if isinstance(max_ts, str):
            max_ts_dt = datetime.datetime.strptime(max_ts, "%Y-%m-%d %H:%M:%S")
        else:
            max_ts_dt = max_ts
        lag_seconds = int((datetime.datetime.now() - max_ts_dt).total_seconds())

    return {
        "max_ts": str(base.get("max_ts") or ""),
        "rows_5m": int(recent.get("rows_5m") or 0),
        "lag_seconds": lag_seconds,
    }


def get_eod_metrics(today: str) -> Dict:
    """较重指标，仅在收盘后执行一次。"""
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT COUNT(*) AS rows_today,
               COUNT(DISTINCT code) AS codes_today,
               MIN(ts) AS min_ts,
               MAX(ts) AS max_ts
        FROM tick
        WHERE trade_date=%s
        """,
        (today,),
    )
    row = cur.fetchone() or {}
    conn.close()
    return {
        "rows_today": int(row.get("rows_today") or 0),
        "codes_today": int(row.get("codes_today") or 0),
        "min_ts": str(row.get("min_ts") or ""),
        "max_ts": str(row.get("max_ts") or ""),
    }


def get_watch_metrics(today: str, watch_codes: List[str]) -> Dict:
    if not watch_codes:
        return {"watch_total": 0, "watch_seen": 0, "watch_fresh": 0, "lagging_codes": []}

    placeholders = ",".join(["%s"] * len(watch_codes))
    params = [today] + watch_codes
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        f"""
        SELECT code, MAX(ts) AS max_ts
        FROM tick
        WHERE trade_date=%s AND code IN ({placeholders})
        GROUP BY code
        """,
        tuple(params),
    )
    rows = cur.fetchall()
    conn.close()

    seen_map = {r["code"]: r.get("max_ts") for r in rows}
    lagging = []
    fresh = 0
    for code in watch_codes:
        ts = seen_map.get(code)
        if not ts:
            lagging.append({"code": code, "lag_seconds": None})
            continue
        ts_dt = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S") if isinstance(ts, str) else ts
        lag = int((datetime.datetime.now() - ts_dt).total_seconds())
        # 5分钟内更新过，视为新鲜
        if lag <= 300:
            fresh += 1
        else:
            lagging.append({"code": code, "lag_seconds": lag})

    return {
        "watch_total": len(watch_codes),
        "watch_seen": len(seen_map),
        "watch_fresh": fresh,
        "lagging_codes": lagging[:20],
    }


def run_eod_check(today: str, watch_codes: List[str]):
    metrics = get_eod_metrics(today)
    watch = get_watch_metrics(today, watch_codes)

    # 收盘完整性阈值：
    # 1) 全局必须至少有一定规模数据
    # 2) 重点股票里 >=90% 在 14:55 后仍有更新
    ok_rows = metrics["rows_today"] >= 200000

    fresh_ratio = 0.0
    if watch["watch_total"] > 0:
        fresh_ratio = watch["watch_fresh"] / watch["watch_total"]
    ok_watch = fresh_ratio >= 0.9

    summary = {
        "date": today,
        "rows_today": metrics["rows_today"],
        "codes_today": metrics["codes_today"],
        "max_ts": metrics["max_ts"],
        "watch_total": watch["watch_total"],
        "watch_fresh": watch["watch_fresh"],
        "watch_fresh_ratio": round(fresh_ratio, 4),
        "pass": bool(ok_rows and ok_watch),
        "generated_at": now_ts(),
    }

    ensure_data_dir()
    with open(SUMMARY_FILE, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    if summary["pass"]:
        write_alert("INFO", f"EOD检查通过: rows={metrics['rows_today']}, watch_fresh_ratio={fresh_ratio:.2%}")
    else:
        write_alert(
            "ERROR",
            f"EOD检查失败: rows={metrics['rows_today']}, watch_fresh_ratio={fresh_ratio:.2%}, max_ts={metrics['max_ts']}",
        )


def monitor_loop(interval: int, watch_limit: int):
    try:
        watch_codes = fetch_watch_codes(limit=watch_limit)
    except Exception as e:
        write_alert("WARN", f"初始化重点股票失败，将继续运行: {e}")
        watch_codes = []
    print(f"[INFO] 监控启动，watch_codes={len(watch_codes)}，interval={interval}s")
    eod_done_date = ""
    tick_count = 0
    watch = {"watch_total": len(watch_codes), "watch_seen": 0, "watch_fresh": 0, "lagging_codes": []}

    while True:
        now = datetime.datetime.now()
        today = now.date().isoformat()

        try:
            metrics = get_global_metrics(today)
            if is_trading_time(now) and watch_codes and tick_count % 5 == 0:
                # 重点股票检查每5轮执行一次，降低数据库压力。
                watch = get_watch_metrics(today, watch_codes)
            status = {
                "date": today,
                "is_trading": is_trading_time(now),
                "global": metrics,
                "watch": watch,
            }
            write_status(status)

            if is_trading_time(now):
                lag = metrics.get("lag_seconds")
                if not metrics["max_ts"] and now.time() > datetime.time(9, 40):
                    write_alert("ERROR", "交易时段仍无数据写入，请立即排查collector")
                if lag is None:
                    write_alert("WARN", "交易时段 max_ts 为空，可能还未写入")
                elif lag > 600:
                    write_alert("ERROR", f"检测到断流：全局最新数据延迟 {lag}s")
                if metrics["rows_5m"] < 100:
                    write_alert("WARN", f"最近5分钟写入偏少：rows_5m={metrics['rows_5m']}")

                if watch["watch_total"] > 0:
                    ratio = watch["watch_fresh"] / watch["watch_total"]
                    if ratio < 0.7:
                        write_alert("ERROR", f"重点股票新鲜度过低：{watch['watch_fresh']}/{watch['watch_total']}")

            # 每天收盘后只做一次 EOD 完整性检查
            if should_run_eod_check(now) and eod_done_date != today:
                run_eod_check(today, watch_codes)
                eod_done_date = today

        except Exception as e:
            write_alert("ERROR", f"监控异常: {e}")

        tick_count += 1
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="分时采集监控器")
    parser.add_argument("--interval", type=int, default=60, help="巡检间隔（秒）")
    parser.add_argument("--watch-limit", type=int, default=30, help="重点监控股票数")
    args = parser.parse_args()

    monitor_loop(interval=args.interval, watch_limit=args.watch_limit)


if __name__ == "__main__":
    main()
