# 安全策略（SECURITY）

这份文档写给**所有人**：真人开发者、以及在这个仓库上工作的 AI。
目标只有一句话：**真实凭据永远不进仓库。**

---

## 1. 绝对不能提交的内容

| 类别 | 例子 | 为什么 |
|---|---|---|
| 账号密码 | 管理员密码、数据库密码、服务器 root 密码 | 仓库可能是公开的，历史不可撤销 |
| 访问令牌 | GitHub Token、云厂商 AK/SK、模型 API Key | 等同于账号权限 |
| 私钥与证书 | `*.pem`、`*.key`、`certs/`、`*.p12` | 可用于冒充服务端/解密 |
| 环境文件 | `deploy/.env`、任何 `*.env` | 里面通常就是上面这些东西 |
| 运行时数据 | `session.json`、`ai-settings.json`、数据库导出、媒体文件 | 含用户隐私与密钥 |
| 真实服务器信息 | 公网 IP、端口（可选）、域名（可选） | 降低被扫描、被攻击的面 |

`.gitignore` 已经排除了大部分，但**不要依赖它**——`git add -f` 能绕过，改扩展名也能绕过。

---

## 2. 真实凭据应该放哪

| 凭据 | 存放位置 |
|---|---|
| 服务器上的一切 | `/etc/riji.env`（权限 600），**只在服务器上** |
| 本机开发用 | 本地文件（如 `C:\dev\xxx.txt`），**不在仓库目录里** |
| 管理员初始密码 | 服务端启动时生成，写入 `server/var/`（已被 gitignore） |
| 模型 API Key | 客户端本机 `ai-settings.json`（已被 gitignore） |

文档里一律用占位符：

```
<你的服务器IP>   <你的端口>   <你的管理员密码>   <你的开发环境密码>
```

---

## 3. 提交前自检（30 秒）

```powershell
# 1) 扫工作区
git grep -n -I -E "password|passwd|secret|token|api[_-]?key|BEGIN .*PRIVATE KEY" -- ':!*.md'

# 2) 扫本次要提交的内容（用通用模式，别把真实口令片段写进文档）
git diff --cached -U0 | Select-String -Pattern "password|secret|token|github_pat_|BEGIN .*PRIVATE KEY"

# 3) 确认没把不该传的文件加进来
git diff --cached --name-only | Select-String -Pattern "\.env$|\.pem$|\.key$|session\.json|node_modules|dist/"

# 4) 扫全历史（可选，慢）
git log --all -S "你的某个密码" --oneline
```

任何一条有输出，就停下来先处理。

---

## 4. 一旦发现泄露，按这个顺序处理

**第 1 步：先轮换凭据，再清理仓库。**
凭据一旦公开，就等于已泄露；清理历史不会让它重新变安全。

- 改密码（客户端：主页 ⋮ → 修改密码；注意启用了端到端加密的账号**不能用命令行重置**，否则历史日记永久解不开）
- 撤销暴露的 Token / Key
- 检查是否有异常登录

**第 2 步：从当前文件里删掉。**

**第 3 步：重写 git 历史，让旧提交不可达。**

```powershell
git checkout --orphan clean-history
git add -A
git commit -m "RiJi 日记平台"
git branch -D main
git branch -m main
git push -f origin main
```

**第 4 步：确认远端干净。**

```powershell
curl -s https://raw.githubusercontent.com/<owner>/<repo>/main/<被改过的文件> | Select-String "泄露的字符串"
```

> 注意：GitHub 会保留一段时间不可达对象，草稿 PR、fork、缓存可能仍能看到旧内容。
> **所以第 1 步（轮换）才是根本，重写历史只是止损。**

---

## 5. 代码层面的安全红线

来自 `docs/项目说明.md` 第 11 章，这里再强调三条最容易破的：

1. **管理员不可见日记内容**——任何管理接口都不得返回 `payload` 或媒体内容。
2. **加密边界在客户端**——服务端不得增加"帮我解密"的能力；`sync_service` 是唯一加解密处。
3. **本地缓存必须按账号隔离**——`LocalStore.open(baseDir, account: ...)`，否则换账号会串数据。

另外两条与凭据相关：

4. **日志里不打印令牌/密钥**（包括异常对象整体 `JSON.stringify(err)`）。
5. **错误信息不回显用户输入以外的敏感字段**。

---

## 6. 已知的安全边界（设计取舍，不是漏洞）

| 项 | 现状 | 说明 |
|---|---|---|
| 传输层 | 默认 HTTP | 内容已端到端加密，传输是密文；**建议加 Caddy/Nginx 上 HTTPS** |
| 本地缓存 | 明文 | 为了离线与导出；服务端才是密文 |
| 节点间 | 支持 mTLS，也可用共享令牌 | 公网多节点务必启用 mTLS |
| 管理员接口 | 有 RBAC 与审计 | 普通用户访问返回 403 |
| 恢复短语 | 16 个词，128 bit | 泄漏即等于密钥泄漏，须纸质保管 |

---

## 7. 报告问题

如果你发现本仓库里有凭据泄露或安全缺陷：

1. **不要**开公开 issue 贴出细节
2. 走 GitHub 的 [Private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
3. 或直接联系仓库所有者

---

*最后更新：2026-11-08。发现策略与实际不符时，先改文档再改代码。*
