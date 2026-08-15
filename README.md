# Devable Companion — releases

Download channel for the `devable` companion CLI: a single native binary
containing the command-line tool and the local daemon that runs Devable
course environments in Docker on your own machine.

This repo holds **releases only**. There is no source here — it lives in
Devable's main repository, which is private. Publishing the built artifacts
publicly is what lets you install without a GitHub token.

## Install

```
curl -fsSL https://raw.githubusercontent.com/devable-dev/devable-companion/main/install-devable.sh | bash
```

The script picks the right build for your OS and architecture, verifies its
sha256 against the release's `checksums.txt`, and installs to
`/usr/local/bin/devable` (falling back to `~/.local/bin/devable` when that
isn't writable).

Options:

```
./install-devable.sh --dry-run             # resolve + print, install nothing
./install-devable.sh --version v1.2.3      # pin a specific version
INSTALL_DIR=~/bin ./install-devable.sh     # choose the install directory
```

Or download an archive directly from [Releases](https://github.com/devable-dev/devable-companion/releases)
and put `devable` on your `PATH` yourself.

## Verify the install

```
devable version
devable doctor      # checks Docker, backend reachability, ports, disk, login
```

`doctor` is the fastest way to find out why something isn't working — it
checks each prerequisite separately and prints a remedy for whichever one
fails.

## Getting started

```
devable login       # opens a browser to link the CLI to your Devable account
devable daemon      # run the local daemon (keep this running)
```

Then open a project lesson on Devable — the workbench connects to the daemon
automatically and starts the lesson's container on your machine.

## Supported platforms

macOS (Intel and Apple Silicon), Linux (x86_64 and arm64), and Windows
(x86_64 and arm64). Docker must be installed and running.

## Releases

Tags are `companion/vX.Y.Z`, and each release attaches six archives plus a
`checksums.txt`:

| Asset | Platform |
|---|---|
| `devable_X.Y.Z_darwin_arm64.tar.gz` | macOS Apple Silicon |
| `devable_X.Y.Z_darwin_amd64.tar.gz` | macOS Intel |
| `devable_X.Y.Z_linux_arm64.tar.gz` | Linux arm64 |
| `devable_X.Y.Z_linux_amd64.tar.gz` | Linux x86_64 |
| `devable_X.Y.Z_windows_arm64.zip` | Windows arm64 |
| `devable_X.Y.Z_windows_amd64.zip` | Windows x86_64 |

## Issues

Please report problems at https://github.com/devable-dev/devable-companion/issues.
