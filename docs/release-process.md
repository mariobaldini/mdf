# Changes and releases

## Version and validation

Read [README.md](../README.md) before changing the project.
`VERSION` stores `MAJOR.MINOR`. Builds and packages use `MAJOR.MINOR.0`.
For each completed change, run `make version-bump` once, then `make version-check` and the affected tests.
Related edits share one increase. The second integer increments without rollover: `0.9` becomes `0.10`.
Builds and tests alone do not need a version increase.

| Command | Purpose |
| --- | --- |
| `make setup` | Install Fedora 44/Ubuntu 26.04 requirements and fetch pinned compiler/dependency sources. |
| `make build` | Build offline in Debug mode. `OPTIMIZE=ReleaseFast` selects release optimization. |
| `make tests` | Run the non-GUI suite, including Debug, ReleaseSafe, and ReleaseFast core tests. |
| `make test-gui OPTIMIZE=ReleaseFast` | Run production GUI tests in isolated Weston. |
| `make release` | Build ReleaseFast executable, RPM/DEB packages, checksums, and build metadata. |
| `make install` / `make uninstall` | Install/remove the user-local executable. Uninstall also removes MDF settings. |
| `make clean` | Delete build output and caches. Preserve downloaded `zig-pkg/` sources and `.mdf-signing/`. |

Release builds use baseline x86_64, Zig ReleaseFast, GCC `-O3`, LTO within each toolchain, and unused-section removal.
C++ exception unwinding remains enabled.
Packages install the single executable at `/usr/bin/mdf` and add Markdown Open With registration without changing the default handler.

## GitHub publication

The workflow builds and tests Fedora 44 and Ubuntu 26.04 independently.
Fedora also runs signed-repository transaction tests with temporary keys.
PRs and `dev` do not publish artifacts. Successful pushes to `main` or version tags can publish after both builds pass.

1. Build optimized packages and verify metadata, installation, desktop registration, and native build bundles.
2. Select the Fedora RPM and Ubuntu DEB. Verify their checksums before assembly.
3. Sign the Fedora RPM with the committed MDF public key's matching private key, then update checksums.
4. Upload both packages to a draft GitHub Release before publishing it.
5. Promote the greatest numeric application version and revision to Latest.
6. Generate and sign DNF metadata from the newest published RPM, then deploy it through GitHub Pages.

Main builds use `GITHUB_RUN_NUMBER` as package revision and tag `vMAJOR.MINOR.PATCH-REVISION`.
Existing `vMAJOR.MINOR.PATCH` releases use RPM revision `1`.
Published releases are unchanged on retry. Draft uploads can resume.
The newest version wins regardless of build completion order.

## DNF repository and signing key

The repository supports Fedora 44 x86_64 at `https://mariobaldini.github.io/mdf/`.
Pages serves `mdf.repo`, `RPM-GPG-KEY-mdf`, and `rpm/fedora/44/x86_64/repodata/`.
RPM downloads use exact public GitHub Release URLs and require no GitHub authentication.
The generated configuration checks package and metadata signatures, uses `$releasever/$basearch`, and expires metadata after one hour.

The dedicated RSA 4096 signing key has no automatic expiration.
Its public key is [tools/RPM-GPG-KEY-mdf](../tools/RPM-GPG-KEY-mdf).
Its fingerprint is `E15EE399BB0AB032893010F2935CF40D93837A42`.
The ignored `.mdf-signing/` backup contains the encrypted `private-key.asc`, random `passphrase`, fingerprint, GPG keyring, and revocation certificate.
Copy that directory to secure backup storage. Keep private files out of Git, release assets, and workflow artifacts.
Keep the same key across releases. Replacement requires a separate client trust migration.

For a new repository without an existing key, run `python3 tools/scripts/rpm-repository.py create-key` once.
The command refuses to overwrite a public key or backup directory.
If generation fails, inspect the backup before another attempt.

Configure the two Actions secrets from the backup:

```sh
gh secret set MDF_RPM_GPG_PRIVATE_KEY --repo mariobaldini/mdf < .mdf-signing/private-key.asc
gh secret set MDF_RPM_GPG_PASSPHRASE --repo mariobaldini/mdf < .mdf-signing/passphrase
```

In **Settings > Pages**, select **GitHub Actions**.
Permit `main` branches and `v*` tags in the `github-pages` environment.
Only the repository job receives `pages: write` and `id-token: write`. Signing variables exist only in their signing steps.
The workflow uses the Pages URL reported by `actions/configure-pages` in generated files.
See GitHub's [custom Pages workflow instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages) for platform configuration.

Repository deployments run one at a time and select published releases after starting.
Generation verifies the downloaded digest, trusted signature, and package version before signing `repomd.xml`.
Missing credentials, incorrect passphrases, or mismatched keys stop publication.
Generation failures preserve the previous deployment. A post-deployment check installs through DNF without GitHub credentials.

## Validation

Run `make test-workflow test-install` for release gates, draft retries, version ordering, and installer integrity.
Run repository tests as root in a disposable Fedora 44 container:

```sh
podman run --rm --security-opt label=disable -v "$PWD:/workspace:ro" -w /workspace \
  registry.fedoraproject.org/fedora:44 bash -c \
  'dnf install -y make python3 rpm-build rpm-sign createrepo_c gnupg2 dnf5-plugins && make test-dnf-repo'
```

The tests use temporary keys, fixtures, HTTP downloads, and an isolated installation root.
They cover installation, upgrades, corrupt/unsigned packages, foreign signatures, invalid metadata, incorrect digests, and missing credentials.
They do not use the production private key. Other focused checks are listed in [tests/README.md](../tests/README.md).

## Recovery

If DNF publication fails, rerun the failed `dnf-repository` job.
It selects the newest complete release again and does not need the one-day build artifacts.
If release publication fails, rerun its job while build artifacts exist. Otherwise rerun the complete workflow.
For a released defect, increase `VERSION` and publish the correction through `main`.
DNF does not automatically downgrade installations when an older package becomes available.
Restore a previous complete executable for manual rollback. There are no installed engine sidecars or settings conversions.

To prepare a local repository snapshot without deploying it:

```sh
export MDF_RPM_GPG_PRIVATE_KEY="$(cat .mdf-signing/private-key.asc)"
export MDF_RPM_GPG_PASSPHRASE="$(cat .mdf-signing/passphrase)"
export GH_TOKEN="$(gh auth token)"
python3 tools/scripts/rpm-repository.py build --repository mariobaldini/mdf \
  --pages-url https://mariobaldini.github.io/mdf --output build/dnf-recovery
unset MDF_RPM_GPG_PRIVATE_KEY MDF_RPM_GPG_PASSPHRASE GH_TOKEN
```

Use a new output directory for each attempt. At least one published RPM must carry the MDF signature.

## Dependency updates

Update pinned gitlinks, manifest hashes, and matching adapter version checks together.
Review generated source replacements before accepting new dependencies. Unexpected source matches must stop the build.
For Pozeiden, review dark palettes, canonical arrow markers, italic attributes, supported families, mvzr dependencies, and license terms.
For Zignal, review both PNG transparency corrections and pixel/ownership tests.
Regenerate Mermaid notices with `python3 tools/scripts/mermaid-notices.py` after fetching dependencies.
Run affected parser, codec, ABI, GUI, and package checks. Inspect light/dark diagrams before publication.

## Source and relinking

Pango uses LGPL-2.1-or-later without FLTK's linking exception.
Cairo offers LGPL 2.1 or MPL 1.1. MDF includes its LGPL text.
Matching source, upstream licenses, and complete relinking inputs must remain available to recipients.
The pinned archives retain upstream `COPYING` and license files. `assets/NOTICE.txt` identifies the bundled components.

To modify bundled Pango or Cairo:

1. Keep the MDF revision and submodule revisions that produced the executable.
2. Run `make setup` to fetch pinned sources and build tools.
3. Modify `zig-pkg/pango/` or `zig-pkg/cairo/`.
4. Run `make build OPTIMIZE=ReleaseFast` to rebuild, relink, and repack the private UI engine.
5. Run affected text/Cairo tests, `make tests`, and `make test-gui OPTIMIZE=ReleaseFast`.

Normal builds preserve local source edits. Meson/Ninja tracks changes. Archives and link inputs remain under `build/`.
For a system-library comparison, run `MDF_BUNDLED_CAIRO=OFF make build OPTIMIZE=ReleaseFast`.
To restore both system libraries, also set `MDF_BUNDLED_PANGO=OFF`.
Bundled Cairo requires bundled Pango to avoid loading a second Cairo implementation.
