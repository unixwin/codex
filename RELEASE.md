# NiuBash Codex Release

This file is the manual release checklist for the `niu-first-class-shell`
branch. It intentionally does not add GitHub Actions or local build automation;
use existing release assets from the NiuBash project when publishing this fork.

## Scope

- Codex detects `niu` and `niu.exe` as `ShellType::Niu`.
- Windows default shell selection prefers NiuBash when available.
- NiuBash command execution uses `niu -C` for profile-aware shell sessions
  and `niu -c` for plain shell sessions.
- Bash-like command parsing, safe-command checks, dangerous-command checks,
  approval prefix handling, and `apply_patch` interception include NiuBash.
- Shell snapshots stay disabled for NiuBash until replay behavior is explicitly
  supported.

## Local build prerequisites

Building this fork locally on Windows hits three separate walls, all of them
environmental:

1. The `v8` crate's build script creates a directory symlink under
   `codex-rs/target/release/gn_root`. Windows grants that only with **Developer
   Mode** enabled or from an **elevated** shell; otherwise the build fails with
   `symlink_dir failed ... 客户端没有所需的特权 (os error 1314)`.
2. Without pre-generated bindings it also runs a binding generator that needs
   **libclang** on `LIBCLANG_PATH`.
3. Building v8 from source is slow, and fetching large artifacts from GitHub is
   slow on a proxied network.

Upstream avoids 1 and 2 by shipping prebuilt v8 libraries and pre-generated
bindings, wired up by the in-repo action `.github/actions/setup-rusty-v8`, which
exports `RUSTY_V8_ARCHIVE` and `RUSTY_V8_SRC_BINDING_PATH`. The release workflow
runs it; a local run can copy those exports (download the artifacts for
`rusty-v8-v$(python .github/scripts/rusty_v8_bazel.py resolved-v8-crate-version)`
and set both variables) and skip the symlink and libclang requirements entirely.

**Practical answer: build in the workflow, not locally.** Local is still fine for
packaging and verification (`scripts/niu/verify-npm-package.sh`), which is
exercised against prebuilt binaries.

## Manual Asset Checklist

- Build the Windows x64 zip either locally or with the
  `niu-codex-windows-build` workflow (manual dispatch).
- Name the release and tag `niu-codex-preview-<YYYYMMDD>` and the asset
  `niu-codex-preview-<YYYYMMDD>-windows-x86_64.zip`.
- The zip is the canonical package directory, which
  `scripts/build_codex_package.py` produces and validates
  (`scripts/codex_package/layout.py` refuses to validate a package that is
  missing any of these):

  ```text
  codex-package.json
  bin/codex.exe
  bin/codex-code-mode-host.exe
  codex-resources/codex-command-runner.exe
  codex-resources/codex-windows-sandbox-setup.exe
  codex-path/rg.exe
  ```

  An earlier revision of this checklist listed only three executables in a flat
  directory. That layout is incomplete: `codex-code-mode-host.exe` and
  `codex-path/rg.exe` are required, and the sandbox helpers are looked up under
  `codex-resources/`, not beside the entrypoint.
- Include this repository commit SHA in the release description.
- Smoke test on Windows with:

```shell
niu -c 'printf "niu ok\n"'
codex --version
```

## Version

`codex-rs/Cargo.toml` `[workspace.package].version` is the single source. 139
crates inherit it, `scripts/codex_package/version.py` writes it into
`codex-package.json`, and it is compiled into the binary, so `codex --version`
only agrees with the npm metadata when the binaries and the version bump come
from the same revision.

Upstream keeps `0.0.0` in-tree as a dev sentinel (`windows-sandbox-rs` uses it
to pick a mtime-based helper suffix instead of the release version). Bump it in
the release commit; the npm workflow refuses to run while it is still `0.0.0`.

Upstream's own release workflow accepts only `X.Y.Z` (published without a tag,
i.e. `latest`) or `X.Y.Z-alpha.N` (published under `alpha`), and fails the build
when the git tag disagrees with `Cargo.toml`. Arbitrary prerelease suffixes such
as `X.Y.Z-niu.1` would not pass that check, and semver ranges skip prereleases,
so fork identity belongs in the dist-tag rather than the version.

## npm release (preferred)

The npm path is automated and produces both the zip and the tarballs from one
build, so the binaries, `codex-package.json`, and the npm version cannot drift
apart:

1. Bump `codex-rs/Cargo.toml` and commit.
2. Run the `niu-codex-npm-release` workflow with `publish=false` and check the
   artifacts. It builds the three binary sets, assembles the canonical package
   directory, produces the zip, stages the two npm packages, and runs
   `scripts/niu/verify-npm-package.sh`.
3. Re-run it with `publish=true` (needs the `NPM_TOKEN` secret) to publish.

Publish order is enforced by the workflow and matters: the meta package
`@unixwin/codex` ships only `bin/codex.js`, and its binaries arrive through
`optionalDependencies` as `npm:@unixwin/codex@<version>-win32-x64`, which npm
installs under `node_modules/@unixwin/codex-win32-x64/`. Publishing the meta
package first installs into a "missing optional dependency" error for everyone
until the platform package lands.

By hand, the same steps are:

```shell
python scripts/build_codex_package.py --target x86_64-pc-windows-msvc \
  --variant codex --cargo-profile release \
  --package-dir "$VENDOR/win32-x64" --force
python codex-cli/scripts/build_npm_package.py --package codex-win32-x64 \
  --vendor-src "$VENDOR" --release-version "$VERSION" --staging-dir "$STAGE/platform"
python codex-cli/scripts/build_npm_package.py --package codex \
  --release-version "$VERSION" --staging-dir "$STAGE/meta"
(cd "$STAGE/platform" && npm publish *.tgz --tag win32-x64 --access public)
(cd "$STAGE/meta" && npm publish *.tgz --tag latest --access public)
```

`--rg-bin` may be passed to the package builder to reuse a local ripgrep;
without it the builder fetches its pinned one.

The platform tarball is large (about 300 MB unpacked, 110 MB compressed) because
`codex.exe` embeds the code-mode runtime. Upstream's equivalent is larger still
(465 MB unpacked).

## Suggested Release Body

```markdown
## Codex CLI with first-class NiuBash support

This fork updates Codex on Windows to treat NiuBash as a native shell target
instead of routing command execution through PowerShell by default.

### Changes

- Detect `niu` and `niu.exe` as a stable shell type.
- Prefer NiuBash on Windows when it is installed.
- Execute NiuBash commands with `niu -C` or `niu -c` depending on shell
  profile requirements.
- Apply bash-like parsing, command safety checks, approval handling, and
  `apply_patch` interception to NiuBash commands.

### Assets

- `niu-codex-preview-<YYYYMMDD>-windows-x86_64.zip` — Codex CLI plus the
  Windows sandbox helpers (`codex-command-runner.exe`,
  `codex-windows-sandbox-setup.exe`), built from this branch.
- The NiuBash shell runtime itself is installed separately from the
  [NiuBash releases page](https://github.com/caomengxuan666/dsh-niu/releases).

### Notes

Install NiuBash first, ensure `niu.exe` is available on `PATH`, then run
Codex normally on Windows.
```
