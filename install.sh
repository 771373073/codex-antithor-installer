#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
NODE_VERSION="${NODE_VERSION:-16}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-high}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia}"
PROVIDER_NAME="${PROVIDER_NAME:-custom}"
API_KEY_ENV_NAME="${API_KEY_ENV_NAME:-ANTITHOR_API_KEY}"

log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf '\n错误: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

upsert_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local block_file="$4"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  local tmp_file
  tmp_file="$(mktemp)"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp_file"

  {
    cat "$tmp_file"
    printf '\n%s\n' "$start_marker"
    cat "$block_file"
    printf '%s\n' "$end_marker"
  } > "$file"

  rm -f "$tmp_file"
}

shell_quote_export() {
  local name="$1"
  local value="$2"
  printf 'export %s=' "$name"
  printf '%q' "$value"
  printf '\n'
}

read_auth_json_key() {
  local auth_file="$HOME/.codex/auth.json"
  if [ ! -f "$auth_file" ] || ! has_cmd node; then
    return 0
  fi

  node -e '
const fs = require("fs");
const file = process.argv[1];
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8")).OPENAI_API_KEY || "";
  if (value) process.stdout.write(value);
} catch (_) {}
' "$auth_file" 2>/dev/null || true
}

write_auth_json_key() {
  AUTH_JSON_KEY="$1" node <<'NODE'
const fs = require("fs");
const path = require("path");

const home = process.env.HOME;
const key = process.env.AUTH_JSON_KEY;
if (!home || !key) {
  process.exit(1);
}

const codexDir = path.join(home, ".codex");
const authFile = path.join(codexDir, "auth.json");
fs.mkdirSync(codexDir, { recursive: true });
fs.writeFileSync(
  authFile,
  JSON.stringify({ OPENAI_API_KEY: key }, null, 2) + "\n",
  { mode: 0o600 }
);
fs.chmodSync(authFile, 0o600);
NODE
}

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

log "检查系统信息"
uname -a
if [ -f /etc/os-release ]; then
  . /etc/os-release
  printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
fi

case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) die "不支持的系统架构: $(uname -m)" ;;
esac

missing=()
for cmd in curl git tar xz; do
  if ! has_cmd "$cmd"; then
    missing+=("$cmd")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  if ! has_cmd apt-get; then
    die "缺少命令: ${missing[*]}，并且没有找到 apt-get。请先手动安装这些依赖。"
  fi
  log "安装基础依赖: ${missing[*]}"
  sudo_if_needed apt-get update
  sudo_if_needed apt-get install -y curl git ca-certificates tar xz-utils
fi

log "安装/加载 nvm ${NVM_VERSION}"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

log "安装/使用 Node.js ${NODE_VERSION}"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use "$NODE_VERSION"

GLOBAL_NODE_ROOT="$(npm root -g)"
CODEX_PACKAGE_DIR="$GLOBAL_NODE_ROOT/@openai/codex"
CODEX_ENTRY_FILE="$CODEX_PACKAGE_DIR/bin/codex.js"

if [ -f "${NVM_BIN:-}/codex" ] && [ ! -L "$NVM_BIN/codex" ] && head -n 8 "$NVM_BIN/codex" | grep -q 'export NVM_DIR'; then
  log "检测到 nvm 的 codex 命令被旧脚本替换，正在清理"
  rm -f "$NVM_BIN/codex"
fi

if [ -f "$CODEX_ENTRY_FILE" ] && head -n 8 "$CODEX_ENTRY_FILE" | grep -q 'export NVM_DIR'; then
  log "检测到 Codex 入口文件被旧脚本覆盖，正在清理并重装"
  npm uninstall -g @openai/codex >/dev/null 2>&1 || true
  rm -rf "$CODEX_PACKAGE_DIR"
  rm -f "${NVM_BIN:-}/codex"
fi

log "安装 Codex CLI: ${CODEX_PACKAGE}"
npm install -g --force "$CODEX_PACKAGE"

GLOBAL_NODE_ROOT="$(npm root -g)"
CODEX_PACKAGE_DIR="$GLOBAL_NODE_ROOT/@openai/codex"
CODEX_ENTRY_FILE="$CODEX_PACKAGE_DIR/bin/codex.js"

if [ ! -f "$CODEX_ENTRY_FILE" ]; then
  die "Codex CLI 安装失败，未找到入口文件: $CODEX_ENTRY_FILE"
fi

if head -n 8 "$CODEX_ENTRY_FILE" | grep -q 'export NVM_DIR'; then
  die "Codex CLI 入口文件仍然异常: $CODEX_ENTRY_FILE。请执行 npm uninstall -g @openai/codex 后重试。"
fi

mkdir -p "$HOME/.codex"

if [ -f "$HOME/.codex/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.codex/env" || true
fi

EXISTING_API_KEY="${!API_KEY_ENV_NAME-}"
if [ -z "$EXISTING_API_KEY" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
  EXISTING_API_KEY="$OPENAI_API_KEY"
fi
if [ -z "$EXISTING_API_KEY" ]; then
  EXISTING_API_KEY="$(read_auth_json_key)"
fi

if [ -n "$EXISTING_API_KEY" ]; then
  printf '\n检测到已有 API Key。\n直接回车保留旧 Key；输入新 Key 则覆盖。输入时不会显示：\n> '
  IFS= read -r -s API_KEY_INPUT
  printf '\n'
  if [ -n "$API_KEY_INPUT" ]; then
    API_KEY_VALUE="$API_KEY_INPUT"
  else
    API_KEY_VALUE="$EXISTING_API_KEY"
  fi
else
  printf '\n请输入 API Key，然后回车。输入时不会显示，这是正常的：\n> '
  IFS= read -r -s API_KEY_VALUE
  printf '\n'
fi

if [ -z "${API_KEY_VALUE:-}" ]; then
  die "API Key 不能为空。"
fi

log "写入 API Key 环境变量文件"
umask 077
{
  shell_quote_export "$API_KEY_ENV_NAME" "$API_KEY_VALUE"
  shell_quote_export "OPENAI_API_KEY" "$API_KEY_VALUE"
} > "$HOME/.codex/env"
chmod 600 "$HOME/.codex/env"
export "${API_KEY_ENV_NAME}=${API_KEY_VALUE}"
export OPENAI_API_KEY="$API_KEY_VALUE"

log "写入 Codex 明文认证文件 ~/.codex/auth.json"
write_auth_json_key "$API_KEY_VALUE"

log "写入 Codex 配置"
if [ -f "$HOME/.codex/config.toml" ]; then
  cp "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak-$(date +'%Y%m%d-%H%M%S')"
fi

cat > "$HOME/.codex/config.toml" <<EOF
model_provider = "${PROVIDER_NAME}"
model = "${CODEX_MODEL}"
model_reasoning_effort = "${CODEX_REASONING_EFFORT}"
disable_response_storage = true

[model_providers.${PROVIDER_NAME}]
name = "${PROVIDER_NAME}"
wire_api = "responses"
requires_openai_auth = true
base_url = "${CODEX_BASE_URL}"
EOF

log "配置 Codex 命令，让登录 shell 和非交互 SSH 都能找到"
SHELL_BLOCK="$(mktemp)"
cat > "$SHELL_BLOCK" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
EOF

upsert_managed_block "$HOME/.profile" '# >>> codex-antithor-installer >>>' '# <<< codex-antithor-installer <<<' "$SHELL_BLOCK"
upsert_managed_block "$HOME/.bashrc" '# >>> codex-antithor-installer >>>' '# <<< codex-antithor-installer <<<' "$SHELL_BLOCK"
rm -f "$SHELL_BLOCK"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -e
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "未找到 nvm: $NVM_DIR/nvm.sh" >&2
  exit 127
fi
. "$NVM_DIR/nvm.sh"
nvm use --silent default >/dev/null 2>&1 || true
CODEX_JS="$(npm root -g 2>/dev/null)/@openai/codex/bin/codex.js"
if [ ! -f "$CODEX_JS" ]; then
  echo "未找到 Codex CLI 文件: $CODEX_JS" >&2
  exit 127
fi
exec node "$CODEX_JS" "$@"
EOF
chmod +x "$HOME/.local/bin/codex"

log "保留 npm 原始 codex 命令，仅创建自动加载 API Key 的包装脚本"

if has_cmd sudo; then
  log "安装 /usr/local/bin/codex 包装脚本"
  sudo_if_needed install -m 0755 "$HOME/.local/bin/codex" /usr/local/bin/codex
else
  log "未找到 sudo；仅安装包装脚本到 $HOME/.local/bin/codex"
fi

log "安装结果检查"
printf 'node: '
node -v
printf 'npm: '
npm -v
printf 'codex: '
"$HOME/.local/bin/codex" --version
printf '配置文件: %s\n' "$HOME/.codex/config.toml"
printf '环境变量文件: %s\n' "$HOME/.codex/env"
printf 'Codex 明文认证文件: %s\n' "$HOME/.codex/auth.json"

cat <<'EOF'

安装完成。

建议继续测试：
  hash -r
  /usr/local/bin/codex --version
  /usr/local/bin/codex exec --skip-git-repo-check "hello"

如果要给 Codex Desktop 远程 SSH 使用：
  1. 先确认本地电脑可以 SSH 进入这台服务器。
  2. 回到 Codex Desktop 重新连接远程主机。
  3. 如果仍然提示“未安装 Codex”，退出服务器重新登录，
     或者重启 Codex Desktop 后再试。

提示：bubblewrap 警告不影响 API Key；想消除警告可以执行：
  sudo apt update && sudo apt install -y bubblewrap
EOF
