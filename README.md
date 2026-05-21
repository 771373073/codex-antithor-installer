# Codex Antithor Installer

One-command installer for Ubuntu servers. It installs Codex CLI with Node.js 16 through nvm, then configures Codex to use the Antithor API gateway.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/771373073/codex-antithor-installer/main/install.sh -o install.sh
bash install.sh
```

The script will pause and ask for:

```text
ANTITHOR_API_KEY
```

Input is hidden. Press Enter to continue.

## What It Does

- Installs nvm.
- Installs Node.js 16.
- Installs `@openai/codex`.
- Writes `~/.codex/config.toml`.
- Stores the API key in `~/.codex/env` with `600` permissions.
- Creates a `codex` wrapper in `~/.local/bin/codex`.
- Tries to install the wrapper at `/usr/local/bin/codex` for non-interactive SSH and Codex Desktop remote detection.

## Test

```bash
codex --version
codex exec "hello"
```

## Defaults

```text
Base URL: https://api.antithor.asia
Model: gpt-5.5
Wire API: responses
API key env: ANTITHOR_API_KEY
```

You can override defaults before running:

```bash
CODEX_MODEL=gpt-5.4 CODEX_REASONING_EFFORT=medium bash install.sh
```
