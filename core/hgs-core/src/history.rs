//! Snapshot history. Each step holds a whole project, capped at [`MAX_UNDO`] undo steps.

use crate::model::Project;

pub const MAX_UNDO: usize = 200;
/// Combined undo/redo serialized storage, excluding the current project.
pub const MAX_HISTORY_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Debug)]
struct Step {
    label: String,
    project: Box<str>,
}

#[derive(Clone, Debug, Default)]
pub struct History {
    undo: Vec<Step>,
    redo: Vec<Step>,
}

impl History {
    pub fn new() -> History {
        History::default()
    }

    /// Records a mutation: `before` is the project as it was, `label` names the change. Clears redo
    /// and drops the oldest step beyond the cap.
    pub fn record(&mut self, label: String, before: Project) {
        self.redo.clear();
        self.undo.push(Step {
            label,
            project: crate::persist::compact(&before).into_boxed_str(),
        });
        self.trim();
    }

    /// Steps back. `current` is kept so redo can return to it. `None` when there's nothing to undo.
    pub fn undo(&mut self, current: Project) -> Option<Project> {
        let project = serde_json::from_str(&self.undo.last()?.project).ok()?;
        let step = self.undo.pop()?;
        self.redo.push(Step {
            label: step.label,
            project: crate::persist::compact(&current).into_boxed_str(),
        });
        self.trim();
        Some(project)
    }

    /// Steps forward again. `None` when there's nothing to redo.
    pub fn redo(&mut self, current: Project) -> Option<Project> {
        let project = serde_json::from_str(&self.redo.last()?.project).ok()?;
        let step = self.redo.pop()?;
        self.undo.push(Step {
            label: step.label,
            project: crate::persist::compact(&current).into_boxed_str(),
        });
        self.trim();
        Some(project)
    }

    pub fn storage_bytes(&self) -> usize {
        self.undo
            .iter()
            .chain(&self.redo)
            .map(|s| s.project.len() + s.label.capacity())
            .sum::<usize>()
            + (self.undo.capacity() + self.redo.capacity()) * std::mem::size_of::<Step>()
    }

    fn trim(&mut self) {
        while self.undo.len() + self.redo.len() > MAX_UNDO
            || self.storage_bytes() > MAX_HISTORY_BYTES
        {
            if !self.undo.is_empty() {
                self.undo.remove(0);
            } else if !self.redo.is_empty() {
                self.redo.remove(0);
            } else {
                break;
            }
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn undo_label(&self) -> Option<&str> {
        self.undo.last().map(|s| s.label.as_str())
    }

    pub fn redo_label(&self) -> Option<&str> {
        self.redo.last().map(|s| s.label.as_str())
    }

    pub fn undo_len(&self) -> usize {
        self.undo.len()
    }

    pub fn redo_len(&self) -> usize {
        self.redo.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn named(n: &str) -> Project {
        Project::new(n)
    }

    #[test]
    fn undo_and_redo_swap_projects_and_labels() {
        let mut h = History::new();
        h.record("Add A".into(), named("p0"));
        h.record("Add B".into(), named("p1"));
        assert_eq!(h.undo_label(), Some("Add B"));
        let back = h.undo(named("p2")).unwrap();
        assert_eq!(back.name, "p1");
        assert_eq!(h.undo_label(), Some("Add A"));
        assert_eq!(h.redo_label(), Some("Add B"));
        let fwd = h.redo(named("p1")).unwrap();
        assert_eq!(fwd.name, "p2");
        assert_eq!(h.undo_label(), Some("Add B"));
        assert!(!h.can_redo());
    }

    #[test]
    fn new_record_clears_redo() {
        let mut h = History::new();
        h.record("Add A".into(), named("p0"));
        h.undo(named("p1")).unwrap();
        assert!(h.can_redo());
        h.record("Add C".into(), named("p0"));
        assert!(!h.can_redo());
        assert_eq!(h.redo_label(), None);
    }

    #[test]
    fn cap_drops_the_oldest_step() {
        let mut h = History::new();
        for i in 0..(MAX_UNDO + 25) {
            h.record(format!("Step {i}"), named(&format!("p{i}")));
        }
        assert_eq!(h.undo_len(), MAX_UNDO);
        assert_eq!(h.undo_label(), Some("Step 224"));
        let mut oldest = None;
        while let Some(p) = h.undo(named("now")) {
            oldest = Some(p.name);
        }
        assert_eq!(oldest.as_deref(), Some("p25"));
    }

    #[test]
    fn empty_history_has_nothing_to_do() {
        let mut h = History::new();
        assert!(h.undo(named("x")).is_none());
        assert!(h.redo(named("x")).is_none());
        assert!(!h.can_undo() && !h.can_redo());
    }
}
