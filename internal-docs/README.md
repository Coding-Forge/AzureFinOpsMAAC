# Internal Development Notes

This folder is for development-only markdown used to remember solution progress, trace decisions, and coordinate build work.

These files are intentionally excluded from distribution releases by `build-release.ps1` through the `internal-docs/*` exclusion pattern. Keep customer-facing documentation in `README.md` or `docs/`.

## Files

| File | Purpose |
| --- | --- |
| `Solution_Progress.md` | Current implementation status, open work, and handoff notes. |
| `Tracing_Notes.md` | Decision log, assumptions, validation notes, and troubleshooting traces. |
| `Build_Notes.md` | Internal build, release, and packaging notes that should not ship. |
| `MACC_Insight_Gap_Assessment.md` | Gap assessment for customer MACC-vs-retail insights, reporting additions, and long-term audit controls. |

## Rules

- Do not put secrets, tokens, subscription IDs, tenant IDs, or customer data in these files.
- Do not use these files for release documentation.
- Update `Solution_Progress.md` when meaningful solution capabilities are added or changed.
- Update `Tracing_Notes.md` when a design choice or troubleshooting result should be remembered.
- Update `Build_Notes.md` when build or packaging behavior changes.

