# radar

Line-anchored reports for a pull workspace. A report is a note about one line of code: the repo, the file, the line, that line's text, the narrower text selected (the quote) and where it was filed from. radar stores each report as a [cpull](https://github.com/jbisfun/cpull) issue in the repo it points at, labelled `report` and carrying an `anchor`. It files them through cpull's HTTP API, so they sync, merge and show in the forge like any other issue. radar reads the line's text when filing and finds the line again after the code moves.

It is one Zig program with a CLI, a small web UI with a JSON API, and an MCP server. The workspace's tool contract is [theme docs/workspace-tools.md](https://github.com/jbisfun/theme/blob/main/docs/workspace-tools.md) §7.

```sh
radar pull src/main.zig 42 -q "unwrap()" -n "panics on an empty pullfile"   # = radar add ...
radar list [--all] [--json]       # open reports, and where each line is now
radar show ID [--json]            # one report and the code around it
radar close ID / radar reopen ID  # ID: a report (issue) id, or a unique prefix
radar migrate radar.json          # the old Rust radar's `radar list --all --json`
radar serve [--listen 127.0.0.1:8746]
radar mcp
```

* REPO is a pullfile repo, or `.` for the workspace's events repo (pullfile `cpull.events`). FILE is relative to the repo. `-n`/`--note` becomes the issue description, and its first line becomes the title unless `--title` gives one. `--labels` adds labels to `report`. `--source` defaults to `cli`; ycode, the wiki and MCP set their own. `--ref REV` reads the line at a commit, branch or tag instead of the work tree.
* The anchor records `commit` = HEAD when HEAD has the same text on that line. A line filed against uncommitted work has no commit.
* Every command talks to cpull directly and needs the cpull job running. The address comes from `--addr`, else `$CPULL_ADDR`, else `.pull/cpull/serve.addr`, else `127.0.0.1:8080`. The workspace is `--root`, else `$PULL_ROOT`, else the nearest parent holding `pullfile.plist`.
* `radar list --json` prints cpull's report objects plus `current_line` (the line in the work tree holding the filed text nearest the filed line, or null), `moved` and `changed`.
* `radar migrate` files the reports of the old radar.db (the Rust radar's `radar list --all --json`; `-` reads stdin) with the `radar` label, keeping each one's status, note, quote and source. It finds the commit by walking the repo's history back to the filing time. A report that is already filed (same repo, file, line, text and note) is skipped, so the migration can run again. cpull stamps the issues with the time of the migration.

## Web UI and API

`radar serve` lists reports by status and repo, shows each report with its code (read at the commit it was filed against, highlighted), and has a form for filing one. The server writes `.pull/radar/serve.addr` while it runs, so the workspace's tool bar (Forge · CI · Wiki · Radar) links to it.

```
GET  /api/health
GET  /api/reports?status=open|closed|all&repo=R&file=F   -> [RadarReport]
GET  /api/reports/<id>                                   -> RadarReport + "excerpt"
POST /api/reports        {repo, file, line, quote?, note?, title?, labels?, source?, ref?} -> 201 RadarReport
POST /api/reports/<id>/close | /reopen                   -> RadarReport
POST /api/relocate       {repo, file, line, line_text}   -> {line, changed}
```

A write whose `Origin` names another site is refused with 403. When cpull isn't running, the API answers 503 and the pages say so.

## MCP

`radar mcp` serves `radar_report`, `radar_reports`, `radar_report_show`, `radar_report_close` and `radar_report_reopen` on stdio. Register it in the pullfile's `mcp_servers` as `radar` with args `["mcp"]`.

## Build

Zig 0.17.1, with the workspace's [theme](https://github.com/jbisfun/theme) checkout beside this repo (`../theme`):

```sh
zig build test
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

radar reads git through the `git` CLI.
