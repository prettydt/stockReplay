# StockReplay Apple 全端版 MVP

这是一个基于 `SwiftUI` 的 Apple 全端骨架，面向 `iPhone + iPad + Mac`，直接复用当前腾讯云/Flask 后端接口：

- `GET /api/codes`
- `GET /api/dates`
- `GET /api/ticks`
- `GET /api/summary`
- `GET /api/verify`
- `GET /api/health`
- `POST /api/subscription/apple/sync`

## 当前能力

- 股票搜索与列表页
- `NavigationSplitView` 适配的大屏结构，适合 iPad / Mac 边看列表边回放
- Mac 端支持 `2屏 / 4屏` 多股票对比工作台
- Mac 多屏之间支持十字线/时间同步对比
- 自选股 / 最近浏览工作台侧边栏
- 更接近网页风格的分时回放详情页（摘要卡片、价格图、成交量图、回放控制、盘口）
- 可切换 `默认 / 同花顺 / 大智慧` 三套主题
- 会员状态页
- `StoreKit 2` 订阅骨架（产品加载 / 购买 / 恢复购买 UI）
- 爱发电绑定入口（作为当前支付过渡方案）
- 为后续 `Sign in with Apple + Apple 订阅校验后端` 预留结构

## 本地启动

### 1. 确保完整 Xcode 已安装
你当前终端环境显示 `xcodebuild` 指向的是 Command Line Tools，需要切到完整 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### 2. 生成项目（推荐）
本目录提供了 `project.yml`，推荐使用 `XcodeGen`：

```bash
brew install xcodegen
cd ios/StockReplayApp
xcodegen generate
open StockReplayApp.xcodeproj
```

生成后，你会看到两个可运行目标：

- `StockReplayApp-iOS`：用于 `iPhone / iPad`
- `StockReplayApp-macOS`：用于 `Mac`

### 3. 运行后端

```bash
cd /Users/prettydt/IdeaProjects/stock_replay
source .venv/bin/activate
python app.py
```

默认 API 地址为：`http://118.25.176.60:5001`

> 当前默认直接连腾讯云服务，不再优先走本地 `localhost`。
>
> 如果在 Mac 上运行，直接选择 `StockReplayApp-macOS` target 即可；这会更适合你平时盯盘和回放使用。

## App Store Connect 预置 Product ID

当前 iOS 骨架里默认使用这两个订阅 Product ID：

- `com.prettydt.stockreplay.monthly`
- `com.prettydt.stockreplay.yearly`

你只要在 App Store Connect 里用相同的 Product ID 创建自动续期订阅，`会员与订阅` 页面里的 StoreKit 2 骨架就能开始测试沙盒购买。

## 可上手测试流程

1. 启动 Flask 后端：`python app.py`
2. 在 iPhone App 的 `会员与订阅` 页填入你的账号，并把 `Base URL` 改成电脑或腾讯云可访问地址
3. 点击 `测试后端连接`，确认看到“连接正常”
4. 点击 `加载 App Store 产品`，再进行沙盒购买
5. 购买成功后，App 会自动调用 `/api/subscription/apple/sync`，把当前账号切到会员状态

> 当前 `/api/subscription/apple/sync` 是 **MVP 沙盒联调接口**，用于先把 iPhone 端跑起来；后续再接正式的 Apple Server API 校验。

## 下一步

1. 在 App Store Connect 创建月度/年度自动续期订阅
2. 在后端新增 Apple 订阅校验接口
3. 把 `member_db.json` 迁移到 MySQL
4. 继续增强回放页（分时均价、盘口深度、自选股）
