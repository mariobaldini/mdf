# Markdown FAST

Markdown FAST is a Markdown viewer for Linux x86_64 desktops with Wayland.
It requires glibc 2.38 or later.
The interface uses FLTK, Cairo, and Pango.

The viewer supports tables, tasks, images, and Mermaid diagrams.
It includes a table of contents, a minimap, themes, and automatic reload.

![Markdown FAST with the Classic light theme, text styles, table of contents, and minimap](docs/screenshots/classic-light.png)

![Markdown FAST with the Catppuccin dark theme and GitHub alerts](docs/screenshots/catppuccin-dark.png)

## Install

On Fedora 44 x86_64, add the signed DNF repository and install MDF:

```sh
sudo dnf install dnf5-plugins
sudo dnf config-manager addrepo --from-repofile=https://mariobaldini.github.io/mdf/mdf.repo
sudo dnf install mdf
```

DNF asks you to accept the MDF public key during the first installation.
Its fingerprint is `E15EE399BB0AB032893010F2935CF40D93837A42`.
Package signatures and repository metadata signatures use this key.

Normal system updates include new MDF releases:

```sh
sudo dnf update
```

For an immediate MDF update, run `sudo dnf --refresh update mdf`.
This repository supports Fedora 44 on x86_64.

You can also download the RPM or DEB package from the [Releases page](https://github.com/mariobaldini/mdf/releases/latest).
From the download folder, run the command for your system:

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

Use the folder button in the toolbar or **Ctrl+O** to open a file.
The Open dialog uses your desktop's system file picker through XDG Desktop Portal.
MDF connects to the portal only when you select Open.
The desktop service loads the dialog's toolkit libraries outside MDF.
Use **Ctrl+C** to copy selected text.
Use **View Source** to read the original Markdown.
Use **View Formatted** to return to the reader.
Source view uses a system monospace font when one is available.
The preview follows the current view and its scroll position.
The viewer starts with wrapped text. **View > Line wrap** can disable wrapping for the current session.
The vertical scrollbar appears only when the document is taller than the reading area.
Settings are saved across sessions by default.
To disable saving, clear **Settings > Save settings across sessions**.

The **Theme** menu offers 10 reading themes, each with light and dark modes.
Ink is the default for first use and Reset Settings. Saved theme choices remain in use.
Options range from warm paper and cool blue tones to Ink's strong monochrome contrast.
See the [theme guide](docs/architecture.md#themes) for the complete list.

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

## Version changes

[`VERSION`](VERSION) stores the application version as `MAJOR.MINOR`, such as `0.3`.
Increase the second integer once for every completed change, including documentation changes:

```sh
make version-bump
make version-check
```

The next version after `0.9` is `0.10`. Build and test runs do not increase the version.
The helper also updates `build.zig.zon`. The executable and package tools use the compatible form `MAJOR.MINOR.0`.
The CLI, About dialog, and profiler read this version through the build.

## Tests and packages

| Command | Purpose |
| --- | --- |
| `make tests` | Run the tests without a graphical session. |
| `make test-gui OPTIMIZE=ReleaseFast` | Run GUI tests in a private Wayland compositor. |
| `make release` | Build the optimized executable, RPM, and DEB packages. |
| `make test-dnf-repo` | Test RPM signatures and DNF installation and upgrades on Fedora 44. |

GitHub Actions runs independent builds and tests on Fedora and Ubuntu.
Successful `main` builds publish RPM and DEB packages.
The release job signs the Fedora RPM before upload.
GitHub Pages serves signed repository metadata that links to the RPM in GitHub Releases.
The repository selects the greatest package version and revision, regardless of build completion order.
The `dev` branch produces no release artifacts.

See the [release process](docs/release-process.md) for signing keys, GitHub configuration, and recovery commands.

## Documentation

- [Tests](tests/README.md)
- [Architecture](docs/architecture.md)
- [Release process](docs/release-process.md)
- [Sample documents](assets/samples/)

## Licenses

Run `mdf --licenses` to read the bundled license notices.

Pozeiden uses the PolyForm Noncommercial 1.0.0 license.
Commercial use requires separate permission from its author.
The [Pozeiden licensing guide](modules/pozeiden/LICENSING.md) gives the terms.
