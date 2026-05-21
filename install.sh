#!/usr/bin/env bash
set -Eeuo pipefail

NVM_VERSION="${NVM_VERSION:-v0.40.3}"
NODE_VERSION="${NODE_VERSION:-16}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-high}"
CODEX_BASE_URL="${CODEX_BASE_URL:-https://api.antithor.asia}"
PROVIDER_NAME="${PROVIDER_NAME:-antithor}"
API_KEY_ENV_NAME="${API_KEY_ENV_NAME:-ANTITHOR_API_KEY}"

log() {
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
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

ensure_line() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
  fi
}

shell_quote_export() {
  local name="$1"
  local value="$2"
  printf 'export %s=' "$name"
  printf '%q' "$value"
  printf '\n'
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
    die "缺少命令: ${missing[*]}；并且未找到 apt-get，请先手动安装这些依赖。"
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

log "安装 Codex CLI: ${CODEX_PACKAGE}"
npm install -g "$CODEX_PACKAGE"

mkdir -p "$HOME/.codex"

if [ -z "${!API_KEY_ENV_NAME:-}" ]; then
  printf '\n请输入 %s，然后回车。输入时不会显示，这是正常的：\n> ' "$API_KEY_ENV_NAME"
  IFS= read -r -s API_KEY_VALUE
  printf '\n'
else
  API_KEY_VALUE="${!API_KEY_ENV_NAME}"
fi

if [ -z "${API_KEY_VALUE:-}" ]; then
  die "${API_KEY_ENV_NAME} 不能为空。"
fi

log "写入 API Key 环境变量文件"
umask 077
shell_quote_export "$API_KEY_ENV_NAME" "$API_KEY_VALUE" > "$HOME/.codex/env"
chmod 600 "$HOME/.codex/env"
export "${API_KEY_ENV_NAME}=${API_KEY_VALUE}"

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
base_url = "${CODEX_BASE_URL}"
env_key = "${API_KEY_ENV_NAME}"
wire_api = "responses"
EOF

log "配置 Codex 命令，让登录 shell 和非交互 SSH 都能找到"
ensure_line "$HOME/.profile" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.profile" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
ensure_line "$HOME/.profile" '[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"'
ensure_line "$HOME/.profile" 'export PATH="$HOME/.local/bin:$PATH"'

ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
ensure_line "$HOME/.bashrc" '[ -f "$HOME/.codex/env" ] && . "$HOME/.codex/env"'
ensure_line "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'

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

install_codex_wrapper() {
  local target="$1"
  local wrapper="$2"

  mkdir -p "$(dirname "$target")"

  # npm normally creates bin/codex as a symlink to the package's JS entrypoint.
  # Remove the symlink first; otherwise cp would follow it and overwrite
  # @openai/codex/bin/codex.js with this bash wrapper.
  if [ -L "$target" ]; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    mv "$target" "$target.real-$(date +'%Y%m%d-%H%M%S')"
  fi

  cp "$wrapper" "$target"
  chmod +x "$target"
}

NVM_DEFAULT_VERSION="$(nvm version default)"
NVM_DEFAULT_BIN="$NVM_DIR/versions/node/$NVM_DEFAULT_VERSION/bin"
if [ -d "$NVM_DEFAULT_BIN" ]; then
  install_codex_wrapper "$NVM_DEFAULT_BIN/codex" "$HOME/.local/bin/codex"
  log "已修复 nvm Codex 入口: $NVM_DEFAULT_BIN/codex"
fi

if [ -n "${NVM_BIN:-}" ] && [ -d "$NVM_BIN" ] && [ "$NVM_BIN" != "$NVM_DEFAULT_BIN" ]; then
  install_codex_wrapper "$NVM_BIN/codex" "$HOME/.local/bin/codex"
  log "已修复当前 nvm Codex 入口: $NVM_BIN/codex"
fi

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
codex --version
printf '配置文件: %s\n' "$HOME/.codex/config.toml"
printf 'API Key 环境变量: %s，保存位置: %s\n' "$API_KEY_ENV_NAME" "$HOME/.codex/env"

cat <<'EOF'

安装完成。

建议继续测试：
  codex exec "hello"

如果要给 Codex Desktop 远程 SSH 使用：
  1. 先确认本地电脑可以 SSH 进入这台服务器。
  2. 回到 Codex Desktop 重新连接远程主机。
  3. 如果仍然提示“未安装 Codex”，退出服务器重新登录，
     或者重启 Codex Desktop 后再试。
EOF
