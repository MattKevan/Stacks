# Stacks

Stacks is an open source Mac-native ebook manager with a Mac/Linux headless server, all in
the same Swift codebase. Features include:

- Store and search EPUB/PDF/DJVU/MOBI books and audiobooks (MP3/M4B/M4A/AAC) by keyword author, series, tag and format.
- Fetch missing metadata and covers.
- Share libraries over a local network, with automatic Bonjour/avahi discovery.
- Import existing Calibre libraries.
- Manage books on connected e-readers.
- Headless server and CLI for library sharing.

## E-reader support

So far this has only been tested with a Kindle Paperwhite 2024+.

## Requirements

- macOS 26+ with Xcode (Swift 6 toolchain) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app
- Swift 6.x from [swift.org](https://www.swift.org/install/linux/) for the
  Linux server (see [LINUX_SERVER.md](LINUX_SERVER.md))

## Build and run - macOS app

```bash
xcodegen generate          # regenerates Stacks.xcodeproj from project.yml
open Stacks.xcodeproj      # or build from the command line:
xcodebuild -project Stacks.xcodeproj -scheme Stacks -destination 'platform=macOS' build
```

## Build and run - headless server on Linux

### Build

```bash
git clone git@github.com:MattKevan/Stacks.git stacks
cd stacks
swift build -c release
```

You'll need to install the Swift toolchain if not already present.

### Install

Copy the binary onto your PATH so `stacks` works from any directory:

```bash
mkdir -p ~/.local/bin
install -m 755 .build/release/stacks ~/.local/bin/stacks
```

`~/.local/bin` is usually on PATH already (Ubuntu adds it when the directory
exists); otherwise add it once to your shell profile and reload. Re-run the
`install` line after every rebuild.

### Create a library

```bash
stacks create /path/to/stacks/library

```
### Import a Calibre library

```bash
stacks import-calibre '/path/to/Calibre Library' '/path/to/stacks/library'
```

### Run

```bash
stacks serve /path/to/stacks/library
```

Options (see `stacks serve --help`):

| Flag | Default | Meaning |
|---|---|---|
| `--port <port>` | `8080` | Listen port |
| `--user <user>` | — | Require this username (with `--password`) |
| `--password <pass>` | — | Password for `--user` |
| `--name <name>` | folder name | Display name (advertisement/diagnostics) |
| `--indexes <dir>` | see below | Catalog indexes directory |
| `--no-bonjour` | off | Do not advertise the library |

By default stacks uses port 8080, so if something is already using that you can pick any other free port.

### systemd (optional)

systemd **does not use your shell PATH**, so `ExecStart` needs the absolute
binary path (wherever you installed it) and the absolute library path —
`$HOME`/`~` are not expanded. 

```
# /etc/systemd/system/stacks-server.service
[Unit]
Description=Stacks library server
After=network.target

[Service]
User=matt
ExecStart=/path/to/bin/stacks serve "/path/to/stacks/library"
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now stacks-server
sudo ufw allow 8080 (or other selected port)
```

After re-installing a rebuilt binary (`install … ~/.local/bin/stacks`),
restart the service to pick it up: `sudo systemctl restart stacks-server`.
