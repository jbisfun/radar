//! `radar mcp`: an MCP server (stdio) over the store, for agents.
//!
//! One long-running process holds the PoloDB database for the session instead of a new
//! `radar` invocation opening (and locking) it per call; don't also run `radar` CLI
//! commands against the same workspace while this is attached.

use std::fmt::Write as _;
use std::path::PathBuf;
use std::sync::Arc;

use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
};
use serde::Deserialize;

use crate::store::{self, NewReport, Status, Store};

type ToolResult = Result<String, String>;

fn err(e: impl std::fmt::Display) -> String {
    format!("{e:#}")
}

#[derive(Deserialize, schemars::JsonSchema)]
struct AddArgs {
    repo: String,
    /// Path relative to the repo.
    file: String,
    line: u32,
    note: Option<String>,
    /// The selected text, if narrower than the line.
    quote: Option<String>,
    /// Where the report came from (default "mcp").
    source: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListArgs {
    /// Include closed reports.
    #[serde(default)]
    all: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct NumberArgs {
    number: u64,
}

#[derive(Clone)]
pub struct RadarMcp {
    store: Arc<Store>,
    tool_router: ToolRouter<Self>,
}

impl RadarMcp {
    fn new(store: Arc<Store>) -> Self {
        Self {
            store,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl RadarMcp {
    #[tool(description = "File a report; the line text is read from the workspace.")]
    fn add(&self, Parameters(a): Parameters<AddArgs>) -> ToolResult {
        let report = self
            .store
            .add(NewReport {
                repo: a.repo,
                file: a.file,
                line: a.line,
                line_text: None,
                quote: a.quote,
                note: a.note,
                source: Some(a.source.unwrap_or_else(|| "mcp".into())),
            })
            .map_err(err)?;
        Ok(format!(
            "#{} {}/{}:{}",
            report.number, report.repo, report.file, report.line
        ))
    }

    #[tool(description = "List reports (all: true also includes closed ones).")]
    fn list(&self, Parameters(a): Parameters<ListArgs>) -> ToolResult {
        let reports = self.store.list(a.all).map_err(err)?;
        let mut out = String::new();
        for report in &reports {
            let closed = if report.status == Status::Closed {
                " (closed)"
            } else {
                ""
            };
            let _ = writeln!(
                out,
                "#{} {}/{}:{}{closed}  {}\n    {}",
                report.number,
                report.repo,
                report.file,
                report.line,
                store::filed_at(report),
                report.line_text.trim()
            );
            if let Some(note) = &report.note {
                let _ = writeln!(out, "    {note}");
            }
        }
        if out.is_empty() {
            out = "no reports".into();
        }
        Ok(out)
    }

    #[tool(description = "Close a report.")]
    fn close(&self, Parameters(a): Parameters<NumberArgs>) -> ToolResult {
        self.store.set_status(a.number, Status::Closed).map_err(err)?;
        Ok(format!("#{} closed", a.number))
    }

    #[tool(description = "Reopen a closed report.")]
    fn reopen(&self, Parameters(a): Parameters<NumberArgs>) -> ToolResult {
        self.store.set_status(a.number, Status::Open).map_err(err)?;
        Ok(format!("#{} reopened", a.number))
    }

    #[tool(description = "Delete a report.")]
    fn rm(&self, Parameters(a): Parameters<NumberArgs>) -> ToolResult {
        self.store.remove(a.number).map_err(err)?;
        Ok(format!("#{} removed", a.number))
    }

    #[tool(
        description = "Write issues/docs/NNNN.md and issues/docs/index.md for open reports; returns the docs directory."
    )]
    fn export(&self) -> ToolResult {
        let docs = self.store.export().map_err(err)?;
        Ok(docs.display().to_string())
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for RadarMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "radar: reports for agents, a line of code plus a note. `add` to file one, \
             `list` (optionally `all`) to see open/closed reports, `close`/`reopen`/`rm` by \
             number, `export` to refresh the published markdown. Only one radar process may \
             hold the database open at a time, so don't run the `radar` CLI against the same \
             workspace while this server is attached.",
        )
    }
}

/// Serve MCP on stdin/stdout until the client disconnects.
pub fn serve(root: PathBuf) -> anyhow::Result<()> {
    let store = Arc::new(Store::open(&root)?);
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move {
        let service = RadarMcp::new(store)
            .serve(rmcp::transport::stdio())
            .await?;
        service.waiting().await?;
        Ok(())
    })
}
