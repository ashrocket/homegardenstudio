//! The engine: one project, its history and a revision counter.

use crate::commands;
use crate::error::{ApiError, ErrorCode, Result};
use crate::history::History;
use crate::model::{Project, MAX_COMMAND_BYTES, MAX_DOCUMENT_BYTES, MAX_NAME};
use crate::persist;
use crate::query;
use crate::validate::check_project;
use serde::Serialize;
use serde_json::Value;

#[derive(Serialize)]
struct HistoryInfo {
    can_undo: bool,
    can_redo: bool,
    undo_label: Option<String>,
    redo_label: Option<String>,
}

#[derive(Serialize)]
struct CommandResponse {
    ok: bool,
    revision: u64,
    created: Vec<String>,
    changed: Vec<String>,
    removed: Vec<String>,
    history: HistoryInfo,
}

pub struct Engine {
    pub(crate) project: Project,
    pub(crate) history: History,
    pub(crate) revision: u64,
}

impl Engine {
    /// An empty project.
    pub fn new(name: &str) -> Engine {
        let name = name.trim();
        let safe_name: String = name.chars().filter(|c| *c != '\0').take(MAX_NAME).collect();
        let name = safe_name.as_str();
        Engine::from_project(Project::new(if name.is_empty() {
            "Untitled plan"
        } else {
            name
        }))
    }

    fn from_project(project: Project) -> Engine {
        Engine {
            project,
            history: History::new(),
            revision: 0,
        }
    }

    /// Opens a saved project. Fails with the error that explains why it can't be opened.
    pub fn open(json: &str) -> Result<Engine> {
        Ok(Engine::from_project(persist::load(json)?))
    }

    pub fn project(&self) -> &Project {
        &self.project
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The canonical file text for the current project.
    pub fn save(&self) -> String {
        persist::save(&self.project)
    }

    /// Runs one command and returns the response JSON. Never panics on bad input.
    pub fn command(&mut self, json: &str) -> String {
        match self.run_command(json) {
            Ok(s) => s,
            Err(e) => e.to_json(),
        }
    }

    /// Runs one query and returns the response JSON. Never mutates.
    pub fn query(&self, json: &str) -> String {
        query::run(self, json)
    }

    pub(crate) fn history_info(&self) -> (bool, bool, Option<String>, Option<String>) {
        (
            self.history.can_undo(),
            self.history.can_redo(),
            self.history.undo_label().map(str::to_string),
            self.history.redo_label().map(str::to_string),
        )
    }

    fn response(&self, outcome: commands::Outcome) -> String {
        let (can_undo, can_redo, undo_label, redo_label) = self.history_info();
        let body = CommandResponse {
            ok: true,
            revision: self.revision,
            created: outcome.created,
            changed: outcome.changed,
            removed: outcome.removed,
            history: HistoryInfo {
                can_undo,
                can_redo,
                undo_label,
                redo_label,
            },
        };
        serde_json::to_string(&body).unwrap_or_else(|_| {
            ApiError::new(ErrorCode::Internal, "could not serialise the response").to_json()
        })
    }

    fn run_command(&mut self, json: &str) -> Result<String> {
        persist::check_bytes(json, MAX_COMMAND_BYTES)?;
        let value: Value = serde_json::from_str(json)
            .map_err(|e| ApiError::new(ErrorCode::InvalidJson, e.to_string()))?;
        let Value::Object(map) = value else {
            return Err(ApiError::invalid("a command must be a JSON object"));
        };
        let op = match map.get("op") {
            Some(Value::String(s)) => s.clone(),
            _ => return Err(ApiError::invalid("a command needs an 'op' string")),
        };
        match op.as_str() {
            "undo" | "redo" => {
                if map.len() != 1 {
                    return Err(ApiError::invalid(format!("{op} takes no fields")));
                }
                self.step_history(op == "undo")
            }
            _ => {
                let mut work = self.project.clone();
                let outcome = commands::apply(&mut work, &op, map)?;
                check_project(&work)?;
                persist::check_bytes(&persist::save(&work), MAX_DOCUMENT_BYTES)?;
                let before = std::mem::replace(&mut self.project, work);
                self.history.record(outcome.label.clone(), before);
                self.revision += 1;
                Ok(self.response(outcome))
            }
        }
    }

    fn step_history(&mut self, undo: bool) -> Result<String> {
        let current = self.project.clone();
        let previous = if undo {
            if !self.history.can_undo() {
                return Err(ApiError::new(ErrorCode::NothingToUndo, "Nothing to undo"));
            }
            self.history.undo(current)
        } else {
            if !self.history.can_redo() {
                return Err(ApiError::new(ErrorCode::NothingToRedo, "Nothing to redo"));
            }
            self.history.redo(current)
        };
        let Some(previous) = previous else {
            return Err(ApiError::new(ErrorCode::Internal, "history is out of step"));
        };
        self.project = previous;
        self.revision += 1;
        Ok(self.response(commands::Outcome::default()))
    }
}
