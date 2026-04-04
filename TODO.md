# 待办事项

## 爱发电接入（认证通过后）

### 前置条件
- [ ] 爱发电创作者认证通过（提交认证已完成，等待审核，约 5 个工作日）
  - 主页：https://ifdian.net/a/stockreplay
  - 方案：月度会员 ¥29/月

### 认证通过后要做的事

1. **获取 Webhook 配置**
   - 爱发电后台 → 开发者 → 复制 `user_id` 和 `token`
   - 设置 Webhook URL：`http://118.25.176.60:5001/webhook/afdian`

2. **将 Webhook 逻辑接入 `app.py`**
   - 参考 `demo/app_demo.py` 中的实现
   - 接收付款推送 → 生成 Token → 写入 MySQL
   - 用户凭爱发电 UID 换取 Token 的接口

3. **前端改造 `templates/index.html`**
   - 加入登录/验证入口
   - 用户输入爱发电 UID → 换取 Token → 存 localStorage
   - 请求实时数据时自动带上 Token

4. **接口鉴权**
   - 实时 tick 接口加 Token 验证
   - 免费版限制：延迟 15 分钟 / 部分股票

5. **部署上线**
   - 更新服务器代码
   - 重启 web 容器
   - 测试完整付费流程

### 参考
- Demo 代码：`demo/app_demo.py`
- 本地测试：`http://localhost:5100`
