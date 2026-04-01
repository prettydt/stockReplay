import requests, time

headers = {'Referer': 'https://finance.sina.com.cn', 'User-Agent': 'Mozilla/5.0'}

# 1. 测试批量500只速度
codes = ['sh6%05d' % i for i in range(600000, 600250)] + \
        ['sz0%05d' % i for i in range(0, 250)]
batch = ','.join(codes)

t0 = time.time()
resp = requests.get(f'http://hq.sinajs.cn/list={batch}', headers=headers, timeout=15)
resp.encoding = 'gbk'
elapsed = time.time() - t0
lines = [l for l in resp.text.strip().split('\n') if '"' in l]
valid = [l for l in lines if len(l.split(',')) > 10]
print(f'批量500只耗时: {elapsed:.2f}s，有效行: {len(valid)}')

# 2. 从东方财富获取全A股总数
resp2 = requests.get(
    'http://push2.eastmoney.com/api/qt/clist/get'
    '?pn=1&pz=1&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281'
    '&fltt=2&invt=2&fid=f3'
    '&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048'
    '&fields=f12,f14',
    headers={'User-Agent': 'Mozilla/5.0'}, timeout=10
)
data = resp2.json()
total = data.get('data', {}).get('total', '未知')
print(f'A股总数: {total} 只')

# 3. 估算全量采集耗时
if isinstance(total, int):
    batch_size = 200
    n_batches = (total + batch_size - 1) // batch_size
    per_req = elapsed / 1  # 500只约elapsed秒，200只按比例
    per_req_200 = elapsed * 200 / 500
    total_time = n_batches * per_req_200
    print(f'\n=== 全量采集估算 ===')
    print(f'股票总数: {total}，每批 {batch_size} 只，需 {n_batches} 批')
    print(f'每批耗时约 {per_req_200:.2f}s，全部查一轮约 {total_time:.1f}s')
    print(f'每3秒采集一轮：{"可行" if total_time < 3 else f"不可行，需{total_time:.0f}s > 3s"}')
    print(f'建议采集间隔: {max(10, int(total_time * 1.5))}s 以上')
