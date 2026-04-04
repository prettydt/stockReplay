"""
一次性脚本：采集当前全A股快照，写入数据库。
用于在首次部署后立即获得今日成交额数据，
以便明日 get_active_codes() 可以正常过滤。
用法：python scripts/snapshot_today.py
"""
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from server.jobs.collector import get_all_codes, fetch_batch, save_batch, init_db, BATCH_SIZE

init_db()
stocks = get_all_codes()
all_codes = [s['code'] for s in stocks]
print(f'股票总数: {len(all_codes)}')

total_valid = 0
total_saved = 0
for i in range(0, len(all_codes), BATCH_SIZE):
    batch = all_codes[i:i + BATCH_SIZE]
    bd = fetch_batch(batch)
    n = save_batch(bd) or 0
    total_valid += len(bd)
    total_saved += n
    print(f'  进度 {i+len(batch)}/{len(all_codes)}，本批有效 {len(bd)} 只')

print(f'\n完成：有效 {total_valid} 只，写入 {total_saved} 条')
