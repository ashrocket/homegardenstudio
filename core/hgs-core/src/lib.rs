//! HomeGardenStudio engine core: project model, geometry, validation, history and persistence.
//!
//! The engine is deterministic and has no clock, randomness, file or network access. The Apple apps
//! drive it with JSON commands and queries through [`Engine`] (and, in `hgs-ffi`, a C ABI).

pub mod brief;
pub mod catalog;
pub mod commands;
pub mod engine;
pub mod error;
pub mod geometry;
pub mod history;
pub mod model;
pub mod persist;
pub mod projection;
pub mod query;
pub mod scene;
pub mod validate;

pub use engine::Engine;
pub use error::{ApiError, ErrorCode};

/// Engine version string, from the crate version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
