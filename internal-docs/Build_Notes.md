# Build Notes

These notes are for internal development and release preparation. They are not distributed.

## Release builder

`build-release.ps1` creates a versioned release folder under `releases/` and, unless `-NoZip` is supplied, a zip file plus SHA256 hash.

## Excluded release content

The release builder excludes:

| Pattern | Reason |
| --- | --- |
| `.git` | Source control metadata must not ship. |
| `internal-docs/*` | Development progress, tracing, and build notes must not ship. |
| `releases/*` | Avoid nesting previous release artifacts. |
| `scripts/exports/*` | Generated run outputs and local settings must not ship. |
| `powerbi/*.Report/.pbi/*` | Local Power BI cache/settings must not ship. |
| `powerbi/*.SemanticModel/.pbi/*` | Local Power BI cache/settings must not ship. |
| `*.zip` | Avoid packaging prior zip artifacts. |
| `*.tmp` | Temporary files must not ship. |
| `*.log` | Local logs must not ship. |

## Smoke build

```powershell
Set-Location 'C:\Projects\Fabric\AzureFinOpsMaccRetailSolution'
.\build-release.ps1 -Version dev-smoke -Force -NoZip
```

Confirm internal docs are excluded:

```powershell
Get-ChildItem '.\releases\AzureFinOpsMaccRetailSolution-vdev-smoke' -Recurse -Force |
    Where-Object { $_.FullName -like '*internal-docs*' }
```

Expected result: no output.

## Release readiness checklist

- PowerShell scripts parse cleanly.
- Launcher runs from the release folder.
- Generated output goes under a run folder and not into the release payload.
- PBIP opens in Power BI Desktop from the release folder.
- README instructions match current launcher behavior.
- `_release-manifest.json` is created.
- Release zip excludes `internal-docs`, generated exports, logs, temp files, and local Power BI cache folders.
