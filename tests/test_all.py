import sys, json, datetime, os, time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from server.jobs.collector import get_all_codes, fetch_batch, save_batch, init_db

init_db()

# 尝试获取列表（东方财富可能 502）
stocks = get_all_codes()
print(f'获取到股票数: {len(stocks)}')

# 直接用已知代码测新浪批量
test_codes = ['sz000001','sh600000','sz300502','sh601318','sz000858',
              'sh600519','sz002415','sh688981','sz002594','sh601899']
print('\n直接批量测试新浪接口:')
t0 = time.time()
bd = fetch_batch(test_codes)
print(f'耗时: {time.time()-t0:.2f}s，有效: {len(bd)} 只')
for code, d in bd.items():
    print(f'  {code}  {d["name"]:8s}  价格={d["price"]}  涨跌={round(d["price"]-d["pre_close"],2)}')
n = save_batch(bd)
print(f'\n写入数据库: {n} 条')

import sqlite3
conn = sqlite3.connect('/Users/prettydt/IdeaProjects/stock_replay/data/stock.db')
print('DB 总行数:', conn.execute('SELECT COUNT(*) FROM tick').fetchone()[0])
print('股票名称表:', conn.execute('SELECT COUNT(*) FROM stock_name').fetchone()[0], '条')
conn.close()
