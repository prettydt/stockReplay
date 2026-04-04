# 工作日记

---

## 2026-04-04

### 今日目标
macOS App 订阅功能改造 + 交互体验优化

---

### 完成事项

#### 1. ⌨️ 回放速度键盘控制
- `ReplayView.swift` 的 `installKeyMonitor()` 里新增 ↑/↓ 方向键控制
- ↑ 加速（1→2→4→8x），↓ 减速（8→4→2→1x）
- 和已有的 Space/←/→ 快捷键共存

#### 2. 🎛 回放 UI 拆分为两张卡片
- 原先一张大卡太空旷，拆成左右两张：
  - **左卡**：紧凑的播放控制（日期选择、进度条、播放按钮组、速度显示）
  - **右卡**：当前 tick 的股票行情数据（价格、涨跌、开/收/高/低等）
- 新增 `tickSnapshotPanel` 和 `tickDataCell` helper

#### 3. 👑 订阅入口从 Tab 移到工具栏皇冠图标
- `StockReplayApp.swift`：删除底部 TabView 中的"会员"Tab
- `StockListView.swift`：右上角加 `crown.fill` 工具栏按钮，点击弹出 Popover
- Popover 挂在 `NavigationSplitView` 层级（macOS 兼容性更好，不挂在 ToolbarItem 上）

#### 4. 🔧 工具栏清理
- 删除左侧 sidebar 工具栏里那个禁用的"搜索 ⌘K"navigation item（视觉多余）

#### 5. 💳 订阅 UI 全面重构
- 移除爱发电入口（完全不出现在用户界面）
- 移除账号绑定、Token 输入框、后端调用
- 订阅流程纯 Apple StoreKit 2：点击卡片 → StoreKit 购买 → `currentEntitlements` 验权
- 布局改为**横排两卡**（月卡/年卡并列），弹窗宽度 680×540
- 价格更新：¥100/月，¥1000/年（StoreKit 实际加载 `displayPrice`）
- 整张卡片可点击，已订阅时卡片边框变绿、显示"✓ 当前方案"
- 底部显示 `storeMessage` 错误信息，方便调试（如"还没有从 App Store Connect 拉到产品"）

---

### 待处理（明天 / 下次）

- [ ] **App Store Connect 配置**（必须，否则购买无法触发）
  1. My Apps → New App，Bundle ID: `com.prettydt.StockReplayApp`，Platform: macOS
  2. Monetization → Subscriptions → 创建订阅组
  3. 添加两个产品：`com.prettydt.stockreplay.monthly`（1 Month）、`com.prettydt.stockreplay.yearly`（1 Year）
  4. 状态设为 **Ready to Submit**
- [ ] **创建沙盒测试账号**（App Store Connect → Users and Access → Sandbox → Testers）
- [ ] 用沙盒账号在 Xcode Debug build 里走完整购买流程验证

---

### 技术备注
- Project: `ios/StockReplayApp/StockReplayApp.xcodeproj`
- Scheme: `StockReplayApp-macOS`
- Bundle ID: `com.prettydt.StockReplayApp`，Team: `52XQ84HH45`
- StoreKit Product IDs: `com.prettydt.stockreplay.monthly` / `com.prettydt.stockreplay.yearly`
- 所有改动均 BUILD SUCCEEDED（macOS Debug）
