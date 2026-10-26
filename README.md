# Markdown FAST

Markdown FAST is a Markdown viewer for Linux x86_64 desktops with Wayland.
It requires glibc 2.38 or later.
The interface uses FLTK, Cairo, and Pango.

The viewer supports tables, tasks, images, and Mermaid diagrams.
It includes a table of contents, a minimap, themes, and automatic reload.

![Markdown FAST with the Classic light theme, text styles, table of contents, and minimap](docs/screenshots/classic-light.png)

![Markdown FAST with the Catppuccin dark theme and GitHub alerts](docs/screenshots/catppuccin-dark.png)

## Install

Download the RPM or DEB package from the [Releases page](https://github.com/mariobaldini/mdf/releases/latest).
From the download folder, run the command for your system.

| System | Install | Remove |
| --- | --- | --- |
| Fedora 44 | `sudo dnf install ./mdf-*.x86_64.rpm` | `sudo dnf remove mdf` |
| Ubuntu 26.04 | `sudo apt install ./mdf_*_amd64.deb` | `sudo apt remove mdf` |

The package adds Markdown FAST to **Open With** for Markdown files.
The package does not change your default application.

The optional [installer](tools/installer.sh) requires curl and Python 3.
It uses GitHub SHA-256 digests for package integrity checks.
For private releases, it accepts the `GH_TOKEN` environment variable.

## Use

Open a document:

```sh
mdf document.md
```

Use **Ctrl+O** to open a file.
Use **Ctrl+C** to copy selected text.
To keep settings, enable **Settings > Save settings across sessions**.

For unsupported Mermaid types, MDF shows the source text and an error message.
Bidirectional layout for Arabic and Hebrew is incomplete.

## Build from source

Install Git, Git LFS, and GNU Make.
Then run these commands:

```sh
git clone --recurse-submodules https://github.com/mariobaldini/mdf.git
cd mdf
git lfs pull
make setup
make build
make install
```

The setup script supports Fedora 44 and Ubuntu 26.04.
It installs dependencies and the compiler version in [.zig-version](.zig-version).
The default build mode is Debug.
The executable is in `build/bin/`.

A source installation places `mdf` in `~/.local/bin`.
This folder must be in your `PATH`.
For source installations, `make uninstall` removes the executable and saved settings.

## Tests and packages

| Command | Purpose |
| --- | --- |
| `make tests` | Run the tests without a graphical session. |
| `make test-gui OPTIMIZE=ReleaseFast` | Run GUI tests in a private Wayland compositor. |
| `make release` | Build the optimized executable, RPM, and DEB packages. |

GitHub Actions runs independent builds and tests on Fedora and Ubuntu.
Successful `main` builds publish RPM and DEB packages.
The `dev` branch produces no release artifacts.

## Documentation

- [Tests](tests/README.md)
- [Implementation](docs/mdf-todo.md)
- [Diagram support and limits](docs/compressed-diagrams.md)
- [Fonts and text](docs/text-stack.md)

## Licenses

Run `mdf --licenses` to read the bundled license notices.

Pozeiden uses the PolyForm Noncommercial 1.0.0 license.
Commercial use requires separate permission from its author.
The [Pozeiden licensing guide](modules/pozeiden/LICENSING.md) gives the terms.
