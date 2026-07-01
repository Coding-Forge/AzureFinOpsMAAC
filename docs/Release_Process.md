# Release process

This document explains how to build a distributable zip for
`AzureFinOpsMaccRetailSolution` and tag the matching Git commit.


## Customer install from latest tagged release

Customers do not need to clone the repository if a tagged release is available. They can:

1. Open the repository's **Releases** page.
2. Download the latest `AzureFinOpsMaccRetailSolution-v<version>.zip` asset.
3. Extract the zip to a local folder.
4. Run the launcher from the extracted folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

The release zip contains the scripts, PBIP report, docs, and HTML help pages. It does not include generated exports, local settings, `.git`, Power BI cache folders, or internal development notes.
## Prerequisites

- PowerShell 5.1 or later.
- Git installed and available on `PATH`.
- A clean working tree before creating the final release tag.
- Power BI Desktop is not required to build the zip, but the PBIP should be opened
  and refreshed as part of release validation when model changes are included.

## Build a release zip

From the solution root:

```powershell
cd C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0
```

The script creates:

```text
releases\AzureFinOpsMaccRetailSolution-v1.0.0\
releases\AzureFinOpsMaccRetailSolution-v1.0.0.zip
releases\AzureFinOpsMaccRetailSolution-v1.0.0.zip.sha256
```

The release folder includes `_release-manifest.json` with build metadata,
including version, source path, Git branch, Git commit, file count, and whether
there were uncommitted changes at build time.

## Replace an existing release build

Use `-Force` to rebuild a version that already exists locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -Force
```

Use this for local rebuilds before publishing. Do not reuse a version number
after a zip has already been shared publicly; increment the version instead.

## Build folder only

Use `-NoZip` if you only want the staged release folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -NoZip
```

## What is excluded

The release package excludes generated or local-only content:

- `.git`
- `releases`
- `scripts\exports`
- Power BI `.pbi` cache/local settings folders
- Existing `.zip` files
- Temporary and log files

## Validate the zip

Before tagging, extract the zip into a clean folder and run:

```powershell
cd <extracted-folder>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

Also open:

```text
powerbi\Cost-Management.pbip
```

Confirm the PBIP opens and that parameters can be set to a valid export folder.

## Commit release changes

Review the working tree:

```powershell
git status --short
git diff --stat
```

Commit the release tooling or release-related changes:

```powershell
git add build-release.ps1 docs\Release_Process.md README.md
git commit -m "Add release packaging workflow"
```

If there are other intentional solution changes, include them in the same commit
or a prior commit as appropriate.

## Tag a release

Use annotated tags for releases:

```powershell
git tag -a v1.0.0 -m "Release v1.0.0"
```

Verify the tag:

```powershell
git tag --list "v*"
git show v1.0.0
```

Push the commit and tag:

```powershell
git push origin main
git push origin v1.0.0
```

If your default branch is not `main`, replace `main` with the correct branch
name.

## Updating future releases

For each new release:

1. Make and validate the solution changes.
2. Update documentation if user-facing behavior changed.
3. Run `build-release.ps1` with a new version.
4. Extract and smoke-test the zip.
5. Commit the final changes.
6. Create and push an annotated tag for the same version.
7. Attach the zip and `.sha256` file to the GitHub release, if using GitHub
   Releases.

Recommended version tag format:

```text
v<major>.<minor>.<patch>
```

Example:

```text
v1.1.0
```

