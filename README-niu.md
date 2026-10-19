# Codex (niu build)

An **unofficial Windows build** of [OpenAI Codex](https://github.com/openai/codex),
packaged by [unixwin](https://github.com/unixwin) for the niu toolchain. It is
the same CLI, built natively for Windows x64 with the sandbox helpers and a
pinned ripgrep beside it.

The official README — features, usage, configuration, security model — is the
repository's [`README.md`](./README.md) and applies here unchanged. This page
only covers what is different about this build.

## Install

```bash
npm install -g @unixwin/codex
codex --version
```

Inside the niu stack, `wpm` can install it too (see below).

## What is different

- **Native Windows build.** No MSYS runtime; the package is `bin/codex.exe`
  with `codex-resources/` and `codex-path/` (a pinned `rg.exe`) beside it.
- **Not the official distribution.** Bugs and packaging questions belong to
  this fork, not to OpenAI. Upstream's licence (Apache-2.0) and notices are
  unchanged; nothing here is endorsed by OpenAI.
- **`wpm` channel.** On a machine with [WinuxCmd](https://github.com/unixwin/WinuxCmd),
  `wpm install codex` installs the same artifact under `opt/codex/` and links
  `codex` into the PATH entry directory. The platform builds are also published
  as versions of this package, the same way upstream does it.

## Versions

Upstream releases are tracked as they are; a niu build carries the upstream
version with no revision suffix unless the packaging itself changed. The
`codex-v<version>` GitHub releases hold the canonical zip that both channels
consume.
