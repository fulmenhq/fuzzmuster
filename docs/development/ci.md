# CI

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request, with `contents: read` only. CI holds no release, signing or
registry authority.

| Cell          | Runner                                               | Gate                  |
| ------------- | ---------------------------------------------------- | --------------------- |
| linux/amd64   | `ubuntu-latest`, goneat-tools-runner-glibc image     | `make check`          |
| linux/arm64   | `ubuntu-latest-arm64-s`, same image (same-repo only) | `make check`          |
| darwin/arm64  | `macos-15`                                           | `make check-platform` |
| windows/amd64 | `windows-latest`                                     | `make check-platform` |
| windows/arm64 | `windows-latest-arm64-s` (same-repo only)            | `make check-platform` |

The runner image is the Linux toolchain: Go, goneat, actionlint and Python
come from it, pinned by digest. The native cells install only the pinned Go
and Python (`.github/actions/make-check`). Every action is pinned by commit.

Run the Linux gate locally in the same image before pushing:

```sh
docker run --rm -v "$PWD":/src -w /src --entrypoint bash \
  ghcr.io/fulmenhq/goneat-tools-runner-glibc:v0.5.16 \
  -c 'git config --global --add safe.directory /src && make check'
```
