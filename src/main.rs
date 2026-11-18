#[cfg(feature = "mcp")]
mod mcp;
mod store;

use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::{Parser, Subcommand};

use store::{NewReport, Status, Store};

/// Reports for agents: a line of code (repo, file, line, line text) plus a note,
/// stored in PoloDB at <workspace>/issues/radar.db and published to issues/docs/.
#[derive(Parser)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// File a report; the line text is read from the workspace.
    Add {
        repo: String,
        /// Path relative to the repo.
        file: String,
        line: u32,
        #[arg(short, long)]
        note: Option<String>,
        /// The selected text, if narrower than the line.
        #[arg(short, long)]
        quote: Option<String>,
        /// Where the report came from (cli, wiki, ycode).
        #[arg(long, default_value = "cli")]
        source: String,
    },
    /// List open reports (`--all` includes closed ones).
    List {
        #[arg(long)]
        all: bool,
        #[arg(long)]
        json: bool,
    },
    Close {
        number: u64,
    },
    Reopen {
        number: u64,
    },
    Rm {
        number: u64,
    },
    /// Write issues/docs/NNNN.md and issues/docs/index.md.
    Export,
    #[cfg(feature = "mcp")]
    /// MCP server on stdio for agents: add/list/close/reopen/rm/export.
    Mcp {
        /// Workspace root (default: found from the current directory).
        #[arg(long)]
        root: Option<PathBuf>,
    },
}

/// `$PULL_ROOT`, else the nearest directory with a pullfile.plist.
fn workspace_root() -> anyhow::Result<PathBuf> {
    if let Some(root) = std::env::var_os("PULL_ROOT") {
        return Ok(PathBuf::from(root));
    }
    let cwd = std::env::current_dir()?;
    cwd.ancestors()
        .find(|dir| dir.join("pullfile.plist").is_file())
        .map(Path::to_path_buf)
        .context("not in a pull workspace (no pullfile.plist above here and no $PULL_ROOT)")
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    #[cfg(feature = "mcp")]
    if let Command::Mcp { root } = &cli.command {
        let root = match root {
            Some(root) => root.clone(),
            None => workspace_root()?,
        };
        return mcp::serve(root);
    }
    let store = Store::open(&workspace_root()?)?;
    match cli.command {
        Command::Add {
            repo,
            file,
            line,
            note,
            quote,
            source,
        } => {
            let report = store.add(NewReport {
                repo,
                file,
                line,
                line_text: None,
                quote,
                note,
                source: Some(source),
            })?;
            println!(
                "#{} {}/{}:{}",
                report.number, report.repo, report.file, report.line
            );
        }
        Command::List { all, json } => {
            let reports = store.list(all)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&reports)?);
            }
            for report in reports.iter().filter(|_| !json) {
                let closed = if report.status == Status::Closed {
                    " (closed)"
                } else {
                    ""
                };
                println!(
                    "#{} {}/{}:{}{closed}  {}\n    {}",
                    report.number,
                    report.repo,
                    report.file,
                    report.line,
                    store::filed_at(report),
                    report.line_text.trim()
                );
                if let Some(note) = &report.note {
                    println!("    {note}");
                }
            }
        }
        Command::Close { number } => store.set_status(number, Status::Closed)?,
        Command::Reopen { number } => store.set_status(number, Status::Open)?,
        Command::Rm { number } => store.remove(number)?,
        Command::Export => println!("{}", store.export()?.display()),
        #[cfg(feature = "mcp")]
        Command::Mcp { .. } => unreachable!(),
    }
    Ok(())
}
