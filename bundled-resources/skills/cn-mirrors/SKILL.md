---
name: cn-mirrors
description: "中国大陆镜像加速 / Mainland China mirrors. Use when generating or fixing commands for GitHub, npm, Python/pip/conda, WinGet, package downloads, install scripts, or dependency setup that may fail in China. Trigger on: GitHub 加速、npm 镜像、pip 镜像、国内源、winget、下载慢、clone 失败, China mirror. Prefer safe mirror substitution; do not change unrelated business logic."
user-invocable: true
disable-model-invocation: false
---

# Mainland China Mirror Preference

Use this skill whenever the user asks you to run, generate, explain, or modify commands that fetch code, packages, installers, release assets, raw files, or archives from GitHub, npm, Python package indexes, or WinGet sources.

## Core rule

Prefer mirrors reachable from mainland China for read-only downloads, but never reduce security or leak credentials. Preserve the user's original package names, repository names, versions, tags, commit SHAs, extras, command flags, and install intent.

If the user explicitly asks not to use mirrors, use the official source.

## Safety and trust rules

- Do not route credentials, tokens, private repository URLs, SSH keys, cookies, or authenticated requests through public mirrors or GitHub proxy sites.
- Do not use public mirrors for mutating commands such as `git push`, `gh auth`, `gh api` write calls, `npm publish`, `npm login`, `npm token`, `twine upload`, or package ownership/access changes.
- Prefer HTTPS mirrors. Never disable TLS verification unless the user explicitly requests it and the risk is explained.
- For production or CI, keep versions pinned and preserve hashes/checksums when present.
- For private registries or internal package indexes, do not replace the user's configured registry unless they explicitly ask.
- If a mirror fails, retry another mirror before falling back to the official source. Mention the fallback in the response.

## GitHub commands

For public GitHub read-only operations, prefer these proxy prefixes in order:

1. `https://ghfast.top/`
2. `https://gh-proxy.com/`

Rewrite direct public GitHub URLs by prefixing the full original HTTPS URL.

Examples:

```bash
git clone https://ghfast.top/https://github.com/OWNER/REPO.git
curl -L -o asset.zip https://ghfast.top/https://github.com/OWNER/REPO/releases/download/TAG/asset.zip
curl -L -o file.txt https://ghfast.top/https://raw.githubusercontent.com/OWNER/REPO/REF/path/file.txt
curl -L -o source.tar.gz https://ghfast.top/https://github.com/OWNER/REPO/archive/refs/tags/TAG.tar.gz
```

Apply this to `git clone`, `curl`, `wget`, release asset downloads, raw file downloads, archive downloads, and public bootstrap scripts that fetch from `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, or GitHub release URLs.

Do not rewrite GitHub commands when:

- The URL contains credentials, tokens, or private repository information.
- The command uses SSH, such as `git@github.com:OWNER/REPO.git`.
- The command is a write/auth operation, such as `git push`, `gh auth login`, `gh release upload`, or issue/PR mutation.
- The proxy would change semantics, break authentication, or hide a security-sensitive endpoint.

Avoid global Git rewrite configuration like `git config --global url.<mirror>.insteadOf ...` unless the user explicitly asks for persistent global configuration, because it can break private repositories and push operations.

## npm / Node.js commands

For read-only npm package operations, prefer:

- Registry: `https://registry.npmmirror.com`
- Node binary/header mirror when needed: `https://npmmirror.com/mirrors/node`

Prefer one-off command flags instead of changing global configuration unless the user asks for persistent setup.

Examples:

```bash
npm install PACKAGE --registry=https://registry.npmmirror.com
npm ci --registry=https://registry.npmmirror.com
npm view PACKAGE --registry=https://registry.npmmirror.com
npm exec --registry=https://registry.npmmirror.com -- PACKAGE_OR_BIN
npx --yes --registry=https://registry.npmmirror.com PACKAGE_OR_BIN
pnpm install --registry=https://registry.npmmirror.com
pnpm add PACKAGE --registry=https://registry.npmmirror.com
YARN_REGISTRY=https://registry.npmmirror.com yarn add PACKAGE
```

Do not use the mirror for publishing, logging in, token management, owner/access changes, or any npm command that writes to the registry. Use `https://registry.npmjs.org/` for those.

If the user asks to set a persistent npm mirror, use:

```bash
npm config set registry https://registry.npmmirror.com
npm config set disturl https://npmmirror.com/mirrors/node
```

If the user asks to restore official npm settings, use:

```bash
npm config set registry https://registry.npmjs.org/
npm config delete disturl
```

## Python package commands

For read-only Python package installs, prefer Tsinghua TUNA PyPI mirror:

- `https://pypi.tuna.tsinghua.edu.cn/simple`

Fallback mirrors, if needed:

- `https://mirrors.aliyun.com/pypi/simple/`
- `https://mirrors.ustc.edu.cn/pypi/simple/`

Examples:

```bash
python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple PACKAGE
python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt
uv pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple PACKAGE
uv add --default-index https://pypi.tuna.tsinghua.edu.cn/simple PACKAGE
poetry source add --priority=primary tuna https://pypi.tuna.tsinghua.edu.cn/simple/
```

If the user asks for persistent pip setup, use:

```bash
python -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

If the user asks to restore official pip settings, use:

```bash
python -m pip config unset global.index-url
```

Do not replace specialized indexes the user intentionally provided, such as CUDA/PyTorch wheels, private indexes, or corporate artifact repositories. If a command already has `--index-url`, `--extra-index-url`, `--find-links`, `--no-index`, or hash-locked requirements, preserve those semantics and only add a mirror when it is safe.

Do not use mirrors for uploads such as `twine upload` or package publishing workflows.

## WinGet commands

For Windows Package Manager read-only search/install/upgrade operations, prefer the USTC WinGet community source when a mainland China mirror is needed:

- `https://mirrors.ustc.edu.cn/winget-source`

Changing WinGet sources is persistent and usually requires an elevated terminal. Prefer to inspect the current source first; only change the source when the user asks for mirror setup, direct source access is failing, or the task explicitly needs mainland mirror preference.

For WinGet >= 1.8:

```powershell
winget source list
winget source remove winget
winget source add winget https://mirrors.ustc.edu.cn/winget-source --trust-level trusted
winget source update
winget install --source winget PACKAGE_ID
```

For WinGet <= 1.7, omit `--trust-level trusted`:

```powershell
winget source remove winget
winget source add winget https://mirrors.ustc.edu.cn/winget-source
winget source update
```

To restore the official WinGet sources when requested:

```powershell
winget source reset --force
winget source update
```

Do not remove or modify `msstore` unless the user explicitly asks.

## Response behavior

When producing commands, show the mirror-optimized command first. If useful, also show the official-source equivalent as a fallback.

When executing commands, run the mirror-optimized command directly unless it violates a safety rule above. If a public mirror fails, retry the next mirror and explain the fallback briefly.

When the user provides a command and asks to run it, rewrite only the network-fetching parts that match this skill. Do not otherwise change shell logic, paths, environment variables, package names, versions, or arguments.
