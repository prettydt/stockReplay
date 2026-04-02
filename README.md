# stockReplay

## 目标

完整采集交易日分时数据（含自动巡检与收盘完整性检查）。

## 启动

```bash
docker compose up -d --build
```

默认会启动 4 个服务：

- `mysql`: 数据库
- `web`: 页面与 API
- `collector`: 分时采集
- `monitor`: 采集监控（每分钟巡检）

## 监控输出

监控容器会把状态和告警写到 `data/` 目录：

- `data/monitor_status.json`: 最新巡检状态（全局写入、重点股票新鲜度）
- `data/monitor_alerts.log`: 告警日志（断流、写入过低、异常）
- `data/monitor_summary.json`: 收盘后完整性检查结果

查看监控日志：

```bash
docker logs stock_replay_monitor --tail 100
```
