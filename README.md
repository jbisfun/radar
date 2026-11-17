# radar

Reports for agents. Each report points at a line of code in the pull workspace and records the repo, the file, the line number, the line's text, an optional note, and when it was filed. Radar is a stateless CLI: every run opens the PoloDB database at `<workspace>/issues/radar.db`, does its work and exits.

```sh
radar add pull src/main.rs 42 --note "panics on an empty pullfile"   # the line text is read from the file
radar list [--all] [--json]
radar close 3 / radar reopen 3 / radar rm 3
radar export        # issues/docs/NNNN.md per open report + issues/docs/index.md
```

The workspace root is `$PULL_ROOT`, or the nearest directory above the current one that contains `pullfile.plist`.

- **Pull:** the precommit hook runs `radar export` and stages `issues/radar.db`. `issues/docs` is gitignored, and the wiki publishes it under `issues`.
- **Wiki:** select text on a docs page and right-click. The "Add to Radar" menu copies the matching `radar add …` command, with the repo, file, source line and your selection already filled in.
