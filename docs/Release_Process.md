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

The release zip contains the scripts, docs, HTML help pages, and whichever Power BI report artifacts are selected for the release: PBIP source, PBIT template, or both. It does not include generated exports, local settings, `.git`, Power BI cache folders, or internal development notes.

## PBIT distribution model

Keep PBIP as the source-controlled development format. Use PBIT as the customer distribution format because it opens as a clean template, prompts for parameters, and avoids shipping cached local data.

Recommended pattern:

| Format | Purpose |
| --- | --- |
| `powerbi\Cost-Management.pbip` | Source-controlled development project. |
| `template\Cost-Management.pbit` | Customer-facing Power BI template exported before release. |
| `AzureFinOpsMaccRetailSolution-v<version>.zip` | GitHub release bundle containing scripts, docs, and the selected Power BI artifacts. |

Power BI Desktop does not provide a reliable command-line export path for PBIT from PBIP. Export the PBIT manually during release validation:

1. Open `powerbi\Cost-Management.pbip` in Power BI Desktop.
2. Confirm parameters are generic or point to a safe sample/current run location.
3. Use **File > Export > Power BI template (.pbit)**.
4. Save it as:

```text
template\Cost-Management.pbit
```

5. Close Power BI Desktop before running the release build.
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
there were uncommitted changes at build time. It also records whether PBIT files were included.

For customer releases where the PBIT is required, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -RequirePbit
```

`-RequirePbit` fails the build if no `.pbit` file exists under `template\` or `powerbi\`.

To build a customer-only release that includes the PBIT but omits the PBIP source project, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -RequirePbit -ExcludePbip
```

`-ExcludePbip` removes `powerbi\*.pbip`, `powerbi\*.Report\`, and `powerbi\*.SemanticModel\` from the package. It fails unless a `.pbit` is present, so the release still contains a usable Power BI report artifact.

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
- Generated export folders
- Temporary and log files

## Validate the zip

Before tagging, extract the zip into a clean folder and run:

```powershell
cd <extracted-folder>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

Also open the PBIT if it is included:

```text
template\Cost-Management.pbit
```

Confirm the template opens and prompts for parameters. Before refreshing the template, run `scripts\Start-FinOpsDataPull.ps1` to generate the CSV/JSON data files. Use the generated `powerbi-storage-settings.json` from the run folder to fill the PBIT parameters, including `StorageLocation`, `LocalDataRoot`, `HistoryDataRoot`, and any selected cloud storage root. If no PBIT is included, open the PBIP source project:

```text
powerbi\Cost-Management.pbip
```

Confirm the PBIP opens and that parameters can be set to a valid export folder.

When validating a release after semantic model changes, also confirm:

- Main cost totals match the generated Cost Management CSVs.
- The PBIT refreshes after parameters are filled from `powerbi-storage-settings.json`.
- Model Technical Tables visuals render named role-playing date dimensions.
- Standalone audit/template pages render without requiring relationships to the core cost model.

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
3. Export `template\Cost-Management.pbit` from Power BI Desktop when customer template distribution is needed.
4. Run `build-release.ps1` with a new version. Use `-RequirePbit` when a PBIT must be included, and add `-ExcludePbip` when the PBIP source should not be included.
5. Extract and smoke-test the zip.
6. Commit the final changes.
7. Create and push an annotated tag for the same version.
8. Attach the zip and `.sha256` file to the GitHub release, if using GitHub
   Releases.

Recommended version tag format:

```text
v<major>.<minor>.<patch>
```

Example:

```text
v1.1.0
```

