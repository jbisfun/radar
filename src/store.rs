//! The report store: a PoloDB database in `<workspace>/issues/radar.db`, and the
//! markdown it publishes to `<workspace>/issues/docs/`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use polodb_core::bson::doc;
use polodb_core::{Collection, CollectionT, Database};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Open,
    Closed,
}

/// One report: where it points (repo, file, line, the line's text) and what was said.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Report {
    pub number: u64,
    pub repo: String,
    /// Path relative to the repo root.
    pub file: String,
    /// 1-based.
    pub line: u32,
    pub line_text: String,
    /// The text the user selected, when it isn't just the line.
    #[serde(default)]
    pub quote: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    pub status: Status,
    /// Where it was filed from: cli, wiki, ycode.
    pub source: String,
    pub created: chrono::DateTime<chrono::Utc>,
}

/// What a client sends. The line text is read from the workspace when omitted.
#[derive(Deserialize, Debug)]
pub struct NewReport {
    pub repo: String,
    pub file: String,
    pub line: u32,
    #[serde(default)]
    pub line_text: Option<String>,
    #[serde(default)]
    pub quote: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

pub struct Store {
    root: PathBuf,
    reports: Collection<Report>,
    // Keeps the database open for the collection handle.
    _db: Database,
}

pub fn issues_dir(root: &Path) -> PathBuf {
    root.join("issues")
}

impl Store {
    pub fn open(root: &Path) -> anyhow::Result<Self> {
        let path = issues_dir(root).join("radar.db");
        let db = Database::open_path(&path).with_context(|| {
            format!(
                "opening {} (another radar process holds it)",
                path.display()
            )
        })?;
        Ok(Self {
            root: root.to_path_buf(),
            reports: db.collection("reports"),
            _db: db,
        })
    }

    pub fn list(&self, all: bool) -> anyhow::Result<Vec<Report>> {
        let filter = if all {
            doc! {}
        } else {
            doc! { "status": "open" }
        };
        let mut reports = self
            .reports
            .find(filter)
            .run()?
            .collect::<Result<Vec<_>, _>>()?;
        reports.sort_by_key(|report| report.number);
        Ok(reports)
    }

    pub fn add(&self, new: NewReport) -> anyhow::Result<Report> {
        let path = self.source_path(&new.repo, &new.file)?;
        let line_text = match new.line_text {
            Some(text) => text,
            None => read_line(&path, new.line)?,
        };
        let number = self.list(true)?.last().map_or(1, |last| last.number + 1);
        let report = Report {
            number,
            repo: new.repo,
            file: new.file,
            line: new.line,
            quote: new
                .quote
                .map(|quote| quote.trim().to_string())
                .filter(|quote| !quote.is_empty() && quote != line_text.trim()),
            line_text,
            note: new.note.filter(|note| !note.trim().is_empty()),
            status: Status::Open,
            source: new.source.unwrap_or_else(|| "cli".into()),
            created: chrono::Utc::now(),
        };
        self.reports.insert_one(&report)?;
        Ok(report)
    }

    pub fn set_status(&self, number: u64, status: Status) -> anyhow::Result<()> {
        let status = serde_json::to_value(status)?;
        let result = self.reports.update_one(
            doc! { "number": number as i64 },
            doc! { "$set": { "status": status.as_str().unwrap_or_default() } },
        )?;
        if result.matched_count == 0 {
            bail!("no report #{number}");
        }
        Ok(())
    }

    pub fn remove(&self, number: u64) -> anyhow::Result<()> {
        if self
            .reports
            .delete_one(doc! { "number": number as i64 })?
            .deleted_count
            == 0
        {
            bail!("no report #{number}");
        }
        Ok(())
    }

    /// `<repo>/<file>` inside the workspace; rejects paths that escape the repo.
    fn source_path(&self, repo: &str, file: &str) -> anyhow::Result<PathBuf> {
        let repo_dir = self
            .root
            .join(repo)
            .canonicalize()
            .with_context(|| format!("no repo {repo} in {}", self.root.display()))?;
        if repo_dir.parent() != Some(self.root.canonicalize()?.as_path()) {
            bail!("{repo} is not a workspace repo");
        }
        let path = repo_dir
            .join(file)
            .canonicalize()
            .with_context(|| format!("no file {file} in {repo}"))?;
        if !path.starts_with(&repo_dir) {
            bail!("{file} is outside {repo}");
        }
        Ok(path)
    }

    /// Writes `docs/NNNN.md` per report and `docs/index.md`, removing pages of deleted reports.
    pub fn export(&self) -> anyhow::Result<PathBuf> {
        let docs = issues_dir(&self.root).join("docs");
        std::fs::create_dir_all(&docs)?;
        let reports = self.list(true)?;
        let mut written = BTreeSet::new();
        for report in &reports {
            let name = format!("{:04}.md", report.number);
            write_if_changed(&docs.join(&name), &report_page(report)?)?;
            written.insert(name);
        }
        write_if_changed(&docs.join("index.md"), &index_page(&reports))?;
        for entry in std::fs::read_dir(&docs)? {
            let name = entry?.file_name().to_string_lossy().into_owned();
            let generated = name.len() > 3
                && name.ends_with(".md")
                && name[..name.len() - 3]
                    .bytes()
                    .all(|byte| byte.is_ascii_digit());
            if generated && !written.contains(&name) {
                std::fs::remove_file(docs.join(&name))?;
            }
        }
        Ok(docs)
    }
}

fn read_line(path: &Path, line: u32) -> anyhow::Result<String> {
    let text = std::fs::read_to_string(path)?;
    let index = usize::try_from(line)?
        .checked_sub(1)
        .context("lines start at 1")?;
    text.lines()
        .nth(index)
        .map(str::to_owned)
        .with_context(|| format!("{} has no line {line}", path.display()))
}

fn write_if_changed(path: &Path, content: &str) -> std::io::Result<()> {
    if std::fs::read_to_string(path).is_ok_and(|current| current == content) {
        return Ok(());
    }
    std::fs::write(path, content)
}

/// Local date and time, e.g. "2026-11-17 18:20 -05:00".
pub fn filed_at(report: &Report) -> String {
    report
        .created
        .with_timezone(&chrono::Local)
        .format("%Y-%m-%d %H:%M %:z")
        .to_string()
}

fn location(report: &Report) -> String {
    format!("{}/{}:{}", report.repo, report.file, report.line)
}

fn report_page(report: &Report) -> anyhow::Result<String> {
    // JSON strings are valid YAML scalars, so the front matter stays parseable.
    let quote = |value: &str| serde_json::to_string(value);
    let status = serde_json::to_value(report.status)?;
    let mut page = format!(
        "---\ntitle: {}\nnumber: {}\nstatus: {}\nrepo: {}\nfile: {}\nline: {}\ncreated: {}\nsource: {}\n---\n\n",
        quote(&format!("#{} {}", report.number, location(report)))?,
        report.number,
        status.as_str().unwrap_or_default(),
        quote(&report.repo)?,
        quote(&report.file)?,
        report.line,
        report.created.to_rfc3339(),
        quote(&report.source)?,
    );
    page += &format!("# #{} `{}`\n\n", report.number, location(report));
    page += &format!(
        "Filed {} from {} · {}\n\n",
        filed_at(report),
        report.source,
        status.as_str().unwrap_or_default()
    );
    if let Some(note) = &report.note {
        page += &format!("{}\n\n", note.trim());
    }
    let language = Path::new(&report.file)
        .extension()
        .map(|extension| extension.to_string_lossy().into_owned())
        .unwrap_or_default();
    let fence = if report.line_text.contains("```") {
        "````"
    } else {
        "```"
    };
    page += &format!("{fence}{language}\n{}\n{fence}\n", report.line_text);
    if let Some(selection) = &report.quote {
        let quoted = selection
            .lines()
            .map(|line| format!("> {line}"))
            .collect::<Vec<_>>()
            .join("\n");
        page += &format!("\nSelected:\n\n{quoted}\n");
    }
    Ok(page)
}

fn index_page(reports: &[Report]) -> String {
    let mut page = String::from("---\ntitle: \"Radar\"\n---\n\n# Radar\n\n");
    for (heading, status) in [("Open", Status::Open), ("Closed", Status::Closed)] {
        let matching: Vec<_> = reports
            .iter()
            .filter(|report| report.status == status)
            .collect();
        page += &format!("## {heading}\n\n");
        if matching.is_empty() {
            page += "None.\n\n";
            continue;
        }
        page += "| # | Filed | Location | Note |\n| - | - | - | - |\n";
        for report in matching {
            let note = report
                .note
                .as_deref()
                .and_then(|note| note.lines().next())
                .unwrap_or("")
                .replace('|', "\\|");
            page += &format!(
                "| [{}]({:04}.md) | {} | `{}` | {note} |\n",
                report.number,
                report.number,
                filed_at(report),
                location(report)
            );
        }
        page += "\n";
    }
    page
}
