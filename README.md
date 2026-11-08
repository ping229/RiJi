# RiJi 日记平台

本地优先、多节点同步、媒体原位混排的个人日记平台。
需求来源：[需求与实现.md](需求与实现.md)（v1.4）

## 交付状态（2026-11-04）

**这是一个可以现在就用起来的个人日记平台。**

- **能用的**：Windows 客户端、服务端、管理后台、多节点副本、端到端加密、四种导出、恢复短语 —— 全部实测通过
- **怎么确认**：`pwsh -File tools/health-check.ps1` 跑 12 项端到端检查，最近一次 **12/12 通过**
- **代码质量**：服务端 22 项 + 客户端 83 项自动化测试，静态分析 0 错误
- **还没验的**：安卓 APK 已构建但**没在真机上跑过**；Docker/Linux 部署文件齐全但**没在真实主机构建过** —— 这两项需要设备和服务器，文档里写清了怎么验

启动：解压 `dist/RiJi-Windows-x64.zip` → 双击 `riji_client.exe`；或双击根目录的 `安装.bat` 从头装一遍。

## 从这里读起

| 你是…… | 先读这份 |
|---|---|
| 想立刻用起来 | [交付说明](docs/交付说明.md)：怎么装、怎么用、验证过什么、没验证什么 |
| 想知道每个按钮干什么 | [界面导览](docs/界面导览.md)：逐屏截图 + 逐项说明 |
| 要在手机上验一遍 | [安卓验收清单](docs/安卓验收清单.md)：六项检查，5 分钟 |
| 部署到 Linux 服务器 | [Linux 部署教程](docs/Linux部署教程.md)：含**端口自定义**与防火墙处理 |
| 部署到 Windows 电脑 | [部署文档](docs/部署文档.md) |
| 用 Docker 部署 | [deploy/README.md](deploy/README.md) |
| 要开第二台服务器做副本 | [多节点说明](docs/multi-node.md) |
| 关心加密到底保护什么 | [端到端加密说明](docs/e2ee.md) |
| 要确认"现在是否一切正常" | 跑 `pwsh -File tools/health-check.ps1`，12 项检查；最近一次结果见 [验收体检结果](docs/验收体检结果.md) |
| 要改代码 / 交给别的 AI 接手 | [项目说明（交接文档）](docs/项目说明.md)：架构、数据模型、关键机制、红线、已知坑 |

## 当前进度

| 能力 | 状态 |
|---|---|
| 服务端：登录、日记、块序列、冲突仲裁、增量同步、媒体上传下载、存储配额 | ✅ 23 项测试 |
| Windows 客户端：登录、主页、搜索、编辑器（富文本 + 图片 + 语音波形 + 视频）、自动保存 | ✅ 98 项测试 |
| 本地优先：断网可写，内容先落本地，恢复后自动同步 | ✅ |
| 富文本（粗体/斜体/下划线/删除线/标题/列表/引用/代码/链接） | ✅ 标记 + 预览，HTML 导出保留排版 |
| 语音：麦克风录制（AAC/M4A）+ 内联播放 | ✅ 播放自检通过 |
| 视频：选择文件 + 内联播放（H.264/AAC） | ✅ 播放自检通过 |
| 管理员 Web 后台：用户/节点/审计/一致性校验 | ✅ 访问 `/admin` |
| 多节点全量副本：基线同步、增量复制、媒体回源、故障后副本可读 | ✅ 双节点实测 |
| 节点间 mTLS | ✅ 证书工具 + 9443 双向校验，实测通过 |
| 搜索 | ✅ 本地全文搜索，关键词不出本机 |
| 日历浏览 | ✅ 按月网格，有日记的日子带标记，点一天直接进入 |
| AI 总结 | ✅ 选时间段 + 写指令，把日记发给兼容 OpenAI 的大模型；密钥只存本机；可附带图片（不支持时自动降级） |
| 存储配额 | ✅ 每用户默认 5GB，管理员可在后台调整；超限时给明确数字与建议 |
| VPS 部署 | ✅ 已部署到 <你的服务器IP>，见 [VPS 部署记录](docs/VPS部署记录.md) |
| 拍照 / 录像 | ✅ 安卓调用系统相机；Windows 用内置摄像头预览页（camera_windows） |
| 端到端加密（正文 + 媒体） | ✅ 服务端只有密文，数据库实测不可读 |
| 恢复短语 / 修改密码 | ✅ 忘记密码可找回，改密码不丢历史 |
| 冲突可视化 | ✅ 版本历史面板 + 一键恢复 |
| 媒体归一化队列 | ✅ 异步转码，加密媒体自动跳过 |
| 客户端自检 | ✅ 六项检查，失败给可操作建议 |
| Android 客户端 | ⚠️ 可构建安装包，**未在真机验证** |
| 分发包 | ✅ `dist/` 下有 Windows 包与两种架构 APK |

## 分发包

| 产物 | 说明 |
|---|---|
| `dist/RiJi-Windows-x64.zip` | Windows 客户端，解压即用，13.1MB |
| `dist/RiJi-Android/RiJi-日记-arm64.apk` | 主流安卓手机（2018 年后），20.4MB |
| `dist/RiJi-Android/RiJi-日记-armv7.apk` | 老款 32 位机型，18.7MB |

Android 安装与局域网访问说明见 `dist/RiJi-Android/安装说明.txt`。

### 重新构建分发包

```powershell
$env:JAVA_HOME='C:\Program Files\Java\jdk-17'
$env:ANDROID_HOME='C:\Android\Sdk'
cd client
flutter build windows --release
flutter build apk --release --split-per-abi
```

构建机要求：Android SDK Platform 36、Build-Tools 36、JDK 17。
国内网络下 Gradle 本体与 Maven 依赖需要镜像，已在 `android/gradle/wrapper/gradle-wrapper.properties`
与 `android/settings.gradle.kts` 里配置好（腾讯 Gradle 镜像 + 阿里云 Maven 镜像）。


## 端到端加密

密钥由你的密码在**你自己的设备上**派生，从不上传。服务端数据库里只有密文——
实测把 `payload` 当文本读会直接报 `invalid byte sequence for UTF8`。

- 忘记密码可以用**恢复短语**（16 个英文单词）找回
- 改密码只更换"解锁钥匙的外壳"，历史日记不会失效
- 管理员、节点运维方、数据库备份都读不到内容

细节与限制见 [docs/e2ee.md](docs/e2ee.md)。

## 数据存在哪

| 情况 | 位置 |
|---|---|
| 正常 | `%APPDATA%\RiJi` |
| 系统拒绝写 AppData | 程序同目录的 `data\`（自动回退） |

两个位置都会在**客户端「自检」页顶部**显示实际路径，旁边有「打开数据目录」按钮。
首次启动新位置时会自动从旧位置迁移会话与本地日记。

## 媒体归一化

服务端有异步转码队列，把 `.mov` / `.webm` / `.wav` 转成 H.264/AAC。
未安装 ffmpeg 时文件按原样保存，队列标记为跳过——**不会阻塞上传，也不会损坏文件**。
已端到端加密的媒体一律跳过转码（磁盘上是密文，转码会毁数据）。
## 多节点

见 [docs/multi-node.md](docs/multi-node.md)。核心环境变量：

| 变量 | 主节点 | 副本节点 |
|---|---|---|
| `RJJ_NODE_ID` | `node-primary` | `node-replica` |
| `RJJ_NODE_ROLE` | `primary` | `replica` |
| `RJJ_PRIMARY_URL` | 空 | 主节点地址 |
| `RJJ_DATABASE_URL` | 自己的库 | **另一套独立的库** |

副本首次启动会自动做全量基线同步（用户 → 日记 → 块 → 媒体），之后每秒追增量。

## 管理员后台
服务端启动后浏览器打开 <http://127.0.0.1:8080/admin>，用管理员账号登录。

能力：集群概览、用户增删禁用、节点增/禁用/提升主/退役、审计日志、一致性校验。

**后台看不到任何日记内容**：接口只返回数量、状态和时间；访问用户日记的接口会直接返回 403。

## 诊断与快捷方式

```powershell
riji_client.exe --selftest=2026-11-02   # 用真实播放引擎自检媒体
riji_client.exe --diary=2026-11-02      # 直接打开某一天的日记
```

### 构建注意（受限网络环境）

`video_player_win` 的 CMake 默认会调用 nuget.exe 下载 WIL 包。若 nuget 不可用，
可先把包解压到 `build\windows\x64\packages\Microsoft.Windows.ImplementationLibrary`，
插件会自动跳过下载（已在本仓库打过补丁）。

## 目录结构

```
RiJi/
├── server/            服务端（TypeScript + Fastify + PostgreSQL）
│   ├── migrations/    数据库迁移脚本，按版本号顺序执行
│   ├── src/
│   │   ├── domain/    纯逻辑：日期归属、版本向量、HLC
│   │   ├── crypto/    AES-GCM 密文外壳（客户端负责加解密，服务端只见密文）
│   │   ├── services/  业务逻辑：日记与块序列的冲突仲裁
│   │   └── routes/    HTTP 接口
│   └── test/          单元测试 + 端到端接口测试
├── client/            客户端（Flutter，Windows + Android）
├── admin/             管理员 Web 后台
├── tools/             开发与运维脚本
└── docs/adr/          设计决策记录
```

## 本地运行

### 最简单的方式（推荐）

双击项目根目录的 **`安装.bat`**。它会自动检查环境、准备数据库、装依赖、建表、启动服务端、创建桌面快捷方式。

详细步骤与故障处理见 [docs/部署文档.md](docs/部署文档.md)。

### 手动方式

#### 1. 启动开发数据库

```powershell
pwsh -File tools/dev-db.ps1 -Action start
```

独立实例，监听 `127.0.0.1:5544`，不会影响系统里已有的 5432 实例。

### 2. 启动服务端

```powershell
cd server
npm install
npm run migrate
npm start
```

首次启动会自动创建管理员账号，并把初始密码写入 `server/var/admin-initial-password.txt`。

### 3. 验证

```powershell
curl http://127.0.0.1:8080/healthz
```

### 4. 测试

```powershell
cd server
npm test
```

需要先创建测试库：

```sql
CREATE DATABASE riji_test;
```

## 关键约束

- **一天一篇日记**：`UNIQUE(user_id, diary_date)`。
- **业务日**：以本地时间凌晨 4:00 为日切点，写入时计算一次并冻结，跨时区不漂移。
- **可写窗口**：`[今天-7, 今天]`，共 8 天；未来日期一律拒绝。
- **冲突不静默丢失**：落败版本写入 `block_versions` 保留 30 天，用户可在版本历史里找回。
- **数据隔离在接口层强制**：所有查询都带 `user_id` 过滤。

## 配置项

全部通过环境变量注入，见 `server/src/config.ts`。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `RJJ_PORT` | 8080 | HTTP 端口 |
| `RJJ_DATABASE_URL` | `postgres://diary@127.0.0.1:5544/riji` | 数据库连接串 |
| `RJJ_MEDIA_DIR` | `./var/media` | 媒体密文存放目录 |
| `RJJ_JWT_SECRET` | 开发默认值 | **生产必须覆盖** |
| `RJJ_DAY_CUT_HOUR` | 4 | 日切点 |
| `RJJ_WRITE_WINDOW_DAYS` | 7 | 补写窗口天数 |
| `RJJ_MAX_UPLOAD` | 512MB | 单文件上传上限 |
| `RJJ_NODE_ID` | node-local | 本节点标识 |
