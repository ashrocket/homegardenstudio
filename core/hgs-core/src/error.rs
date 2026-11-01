//! Error codes and the JSON error envelope shared by commands, queries and the C ABI.

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    InvalidJson,
    UnknownOp,
    NotFound,
    InvalidValue,
    Locked,
    UnregisteredSource,
    SchemaTooNew,
    LimitExceeded,
    NothingToUndo,
    NothingToRedo,
    Internal,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::InvalidJson => "INVALID_JSON",
            ErrorCode::UnknownOp => "UNKNOWN_OP",
            ErrorCode::NotFound => "NOT_FOUND",
            ErrorCode::InvalidValue => "INVALID_VALUE",
            ErrorCode::Locked => "LOCKED",
            ErrorCode::UnregisteredSource => "UNREGISTERED_SOURCE",
            ErrorCode::SchemaTooNew => "SCHEMA_TOO_NEW",
            ErrorCode::LimitExceeded => "LIMIT_EXCEEDED",
            ErrorCode::NothingToUndo => "NOTHING_TO_UNDO",
            ErrorCode::NothingToRedo => "NOTHING_TO_REDO",
            ErrorCode::Internal => "INTERNAL",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, ApiError>;

#[derive(Serialize)]
struct ErrorBody<'a> {
    code: &'a str,
    message: &'a str,
}

#[derive(Serialize)]
struct ErrorEnvelope<'a> {
    ok: bool,
    error: ErrorBody<'a>,
}

impl ApiError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> ApiError {
        ApiError {
            code,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> ApiError {
        ApiError::new(ErrorCode::InvalidValue, message)
    }

    pub fn limit(message: impl Into<String>) -> ApiError {
        ApiError::new(ErrorCode::LimitExceeded, message)
    }

    pub fn not_found(message: impl Into<String>) -> ApiError {
        ApiError::new(ErrorCode::NotFound, message)
    }

    pub fn locked(message: impl Into<String>) -> ApiError {
        ApiError::new(ErrorCode::Locked, message)
    }

    /// `{"ok":false,"error":{"code":...,"message":...}}`
    pub fn to_json(&self) -> String {
        let envelope = ErrorEnvelope {
            ok: false,
            error: ErrorBody {
                code: self.code.as_str(),
                message: &self.message,
            },
        };
        serde_json::to_string(&envelope).unwrap_or_else(|_| {
            "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"serialisation failed\"}}"
                .to_string()
        })
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for ApiError {}
