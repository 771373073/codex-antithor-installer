# Codex Antithor 一键安装脚本

这个仓库用于在 Ubuntu 服务器上一键安装 Codex CLI，并配置为使用 Antithor 中转站。

适合给多人批量配置服务器使用。用户只需要在服务器里运行安装命令，脚本会在需要时暂停，提示输入自己的 API Key。

## 一键安装

在服务器终端运行：

```bash
curl -fsSL https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install.sh -o install.sh
bash install.sh
```

安装过程中会提示：

```text
请输入 ANTITHOR_API_KEY，然后回车。输入时不会显示，这是正常的：
>
```

此时粘贴你的 API Key，然后回车即可。输入过程中不会显示，这是正常的。

## 脚本会做什么

- 安装 nvm。
- 安装 Node.js 16，兼容 Ubuntu 18.04。
- 安装 `@openai/codex`。
- 写入 Codex 配置文件：`~/.codex/config.toml`。
- 把 API Key 保存到：`~/.codex/env`。
- 设置 `~/.codex/env` 权限为 `600`。
- 创建 `codex` 启动包装脚本：`~/.local/bin/codex`。
- 尝试安装 `/usr/local/bin/codex`，方便 Codex Desktop 远程 SSH 检测。

## 默认配置

```text
Base URL: https://api.antithor.asia
Model: gpt-5.5
Wire API: responses
API key 环境变量: ANTITHOR_API_KEY
```

生成的 Codex 配置大致如下：

```toml
model_provider = "antithor"
model = "gpt-5.5"
model_reasoning_effort = "high"
disable_response_storage = true

[model_providers.antithor]
name = "antithor"
base_url = "https://api.antithor.asia"
env_key = "ANTITHOR_API_KEY"
wire_api = "responses"
```

## 安装后测试

```bash
codex --version
codex exec "hello"
```

如果 `codex --version` 能输出版本号，说明 Codex CLI 已经安装成功。

如果 `codex exec "hello"` 能正常返回，说明中转站和 API Key 配置可用。

如果看到下面的报错：

```text
Missing environment variable: `ANTITHOR_API_KEY`.
```

请重新拉取最新脚本再运行一次：

```bash
curl -fsSL https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install.sh -o install.sh
bash install.sh
```

新版脚本会同时修复 `~/.local/bin/codex`、`/usr/local/bin/codex` 和 nvm 里的 `codex` 入口，确保启动 Codex 时自动加载 `~/.codex/env`。

## 给 Codex Desktop 远程 SSH 使用

如果要在本地 Codex Desktop 连接这台服务器：

1. 先确保本地可以正常 SSH 进入服务器。
2. 在服务器上运行本脚本并完成 API Key 配置。
3. 回到 Codex Desktop 重新连接远程 SSH 主机。
4. 如果仍提示“未安装 Codex”，退出服务器重新登录，或者重启 Codex Desktop 后再试。

## 修改默认模型

可以在运行脚本前指定模型：

```bash
CODEX_MODEL=gpt-5.4 CODEX_REASONING_EFFORT=medium bash install.sh
```

也可以修改中转站地址：

```bash
CODEX_BASE_URL=https://你的中转站地址 bash install.sh
```

## 注意事项

- 不要把 API Key 写进 GitHub。
- 脚本会交互式读取 API Key，并保存到用户自己的 `~/.codex/env`。
- 如果之前已有 `~/.codex/config.toml`，脚本会先自动备份。
- Ubuntu 18.04 推荐使用 Node.js 16，因此脚本默认安装 Node 16。
