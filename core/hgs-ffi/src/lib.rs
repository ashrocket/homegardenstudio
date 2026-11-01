//! C ABI over `hgs-core`. See `include/hgs.h`.
//!
//! Every entry point catches panics and answers with an `INTERNAL` error JSON instead of
//! unwinding across the FFI boundary. Strings returned to the caller are heap allocated here and
//! must be released with [`hgs_string_free`].

use hgs_core::model::{MAX_COMMAND_BYTES, MAX_DOCUMENT_BYTES, MAX_NAME, MAX_QUERY_BYTES};
use hgs_core::{ApiError, Engine, ErrorCode};
#[cfg(test)]
use std::ffi::CStr;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::null_mut;

/// Opaque engine handle.
pub struct HgsEngine(Engine);

fn internal_error() -> String {
    ApiError::new(ErrorCode::Internal, "the engine hit an internal error").to_json()
}

fn into_c(s: String) -> *mut c_char {
    let bytes: Vec<u8> = s.into_bytes().into_iter().filter(|b| *b != 0).collect();
    match CString::new(bytes) {
        Ok(c) => c.into_raw(),
        Err(_) => c"{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"bad string\"}}"
            .to_owned()
            .into_raw(),
    }
}

/// Runs `f`, turning a panic into an `INTERNAL` error JSON. Never returns NULL.
fn guarded(f: impl FnOnce() -> String) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(s) => into_c(s),
        Err(_) => into_c(internal_error()),
    }
}

/// Copies a C string into an owned `String`.
///
/// # Safety
/// `p` must be NULL or point to a NUL-terminated string.
unsafe fn read_utf8(p: *const c_char, limit: usize) -> Result<String, ApiError> {
    if p.is_null() {
        return Err(ApiError::invalid("a required string argument is NULL"));
    }
    // The ABI requires a valid NUL-terminated allocation. Stop scanning at the limit before
    // making any owned copy; this cannot protect callers that supply dangling pointers.
    let mut length = 0;
    while length <= limit {
        if *p.add(length) == 0 {
            return std::str::from_utf8(std::slice::from_raw_parts(p.cast(), length))
                .map(str::to_owned)
                .map_err(|_| ApiError::invalid("input is not valid UTF-8"));
        }
        length += 1;
    }
    Err(ApiError::limit(format!(
        "input exceeds {limit} UTF-8 bytes"
    )))
}

/// Engine version, as a static NUL-terminated string. Do not free it.
#[no_mangle]
pub extern "C" fn hgs_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// Creates an empty project. A NULL name gives "Untitled plan". Free the result with
/// [`hgs_engine_free`].
///
/// # Safety
/// `name_utf8` must be NULL or point to a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn hgs_engine_new(name_utf8: *const c_char) -> *mut HgsEngine {
    catch_unwind(AssertUnwindSafe(|| {
        let name = if name_utf8.is_null() {
            "Untitled plan".to_owned()
        } else {
            match read_utf8(name_utf8, MAX_NAME * 4) {
                Ok(s) => s,
                Err(_) => return null_mut(),
            }
        };
        if name.chars().count() > MAX_NAME {
            return null_mut();
        }
        Box::into_raw(Box::new(HgsEngine(Engine::new(&name))))
    }))
    .unwrap_or(null_mut())
}

/// Opens a saved project. Returns NULL on failure and, if `error_out` isn't NULL, stores an error
/// JSON there (free it with [`hgs_string_free`]). On success `*error_out` is set to NULL.
///
/// # Safety
/// `project_json` must be NULL or point to a NUL-terminated string. `error_out` must be NULL or
/// point to a writable `char *`.
#[no_mangle]
pub unsafe extern "C" fn hgs_engine_open(
    project_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut HgsEngine {
    let opened = catch_unwind(AssertUnwindSafe(|| {
        match read_utf8(project_json, MAX_DOCUMENT_BYTES) {
            Ok(json) => Engine::open(&json),
            Err(e) => Err(e),
        }
    }));
    match opened {
        Ok(Ok(engine)) => {
            if !error_out.is_null() {
                *error_out = null_mut();
            }
            Box::into_raw(Box::new(HgsEngine(engine)))
        }
        Ok(Err(e)) => {
            if !error_out.is_null() {
                *error_out = into_c(e.to_json());
            }
            null_mut()
        }
        Err(_) => {
            if !error_out.is_null() {
                *error_out = into_c(internal_error());
            }
            null_mut()
        }
    }
}

/// Frees an engine. NULL is allowed. Freeing the same handle twice is undefined behaviour.
///
/// # Safety
/// `engine` must be NULL or a handle from [`hgs_engine_new`] or [`hgs_engine_open`] that hasn't
/// been freed.
#[no_mangle]
pub unsafe extern "C" fn hgs_engine_free(engine: *mut HgsEngine) {
    if engine.is_null() {
        return;
    }
    let boxed = Box::from_raw(engine);
    let _ = catch_unwind(AssertUnwindSafe(move || drop(boxed)));
}

/// Runs a command. Always returns a JSON string (never NULL); free it with [`hgs_string_free`].
///
/// # Safety
/// `engine` must be NULL or a live handle. `command_json` must be NULL or point to a
/// NUL-terminated string. Don't call this from two threads at once on the same engine.
#[no_mangle]
pub unsafe extern "C" fn hgs_engine_command(
    engine: *mut HgsEngine,
    command_json: *const c_char,
) -> *mut c_char {
    guarded(
        move || match (engine.as_mut(), read_utf8(command_json, MAX_COMMAND_BYTES)) {
            (None, _) => ApiError::invalid("engine is NULL").to_json(),
            (_, Err(e)) => e.to_json(),
            (Some(e), Ok(json)) => e.0.command(&json),
        },
    )
}

/// Runs a query. Always returns a JSON string (never NULL); free it with [`hgs_string_free`].
///
/// # Safety
/// `engine` must be NULL or a live handle. `query_json` must be NULL or point to a NUL-terminated
/// string. Don't call this from two threads at once on the same engine.
#[no_mangle]
pub unsafe extern "C" fn hgs_engine_query(
    engine: *mut HgsEngine,
    query_json: *const c_char,
) -> *mut c_char {
    guarded(
        move || match (engine.as_ref(), read_utf8(query_json, MAX_QUERY_BYTES)) {
            (None, _) => ApiError::invalid("engine is NULL").to_json(),
            (_, Err(e)) => e.to_json(),
            (Some(e), Ok(json)) => e.0.query(&json),
        },
    )
}

/// Frees a string returned by this library. NULL is allowed.
///
/// # Safety
/// `s` must be NULL or a string returned by this library that hasn't been freed.
#[no_mangle]
pub unsafe extern "C" fn hgs_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(p: *mut c_char) -> String {
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
        unsafe { hgs_string_free(p) };
        s
    }

    #[test]
    fn a_panic_becomes_an_internal_error() {
        let s = take(guarded(|| panic!("boom")));
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "INTERNAL");
    }

    #[test]
    fn interior_nul_bytes_are_dropped_not_fatal() {
        assert_eq!(take(into_c("a\0b".to_string())), "ab");
    }
    #[test]
    fn null_inputs_and_invalid_utf8_return_owned_errors() {
        unsafe {
            hgs_engine_free(null_mut());
            hgs_string_free(null_mut());
            let r = take(hgs_engine_query(null_mut(), std::ptr::null()));
            assert!(r.contains("INVALID_VALUE"));
            let invalid = [0xffu8, 0];
            assert!(hgs_engine_new(invalid.as_ptr().cast()).is_null());
            let mut err = null_mut();
            assert!(hgs_engine_open(invalid.as_ptr().cast(), &mut err).is_null());
            assert!(take(err).contains("UTF-8"));
        }
    }
    #[test]
    fn ffi_roundtrip_owned_strings_and_errors_preserve_state() {
        unsafe {
            let e = hgs_engine_new(std::ptr::null());
            assert!(!e.is_null());
            let add = c"{\"op\":\"add_item\",\"kind\":\"sauna\",\"x\":1,\"y\":2}";
            assert!(take(hgs_engine_command(e, add.as_ptr())).contains("\"ok\":true"));
            let snapshot = c"{\"q\":\"snapshot\",\"text\":true}";
            let before = take(hgs_engine_query(e, snapshot.as_ptr()));
            assert!(take(hgs_engine_command(e, c"{broken".as_ptr())).contains("INVALID_JSON"));
            assert_eq!(before, take(hgs_engine_query(e, snapshot.as_ptr())));
            let v: serde_json::Value = serde_json::from_str(&before).unwrap();
            let text = CString::new(v["result"].as_str().unwrap()).unwrap();
            let mut err = null_mut();
            let reopened = hgs_engine_open(text.as_ptr(), &mut err);
            assert!(!reopened.is_null());
            assert!(err.is_null());
            assert_eq!(before, take(hgs_engine_query(reopened, snapshot.as_ptr())));
            hgs_engine_free(e);
            hgs_engine_free(reopened);
        }
    }
    #[test]
    fn ffi_oversize_rejected_before_owned_copy() {
        unsafe {
            let e = hgs_engine_new(std::ptr::null());
            let input = CString::new(" ".repeat(MAX_COMMAND_BYTES + 1)).unwrap();
            assert!(take(hgs_engine_command(e, input.as_ptr())).contains("LIMIT_EXCEEDED"));
            let name = CString::new("n".repeat(MAX_NAME + 1)).unwrap();
            assert!(hgs_engine_new(name.as_ptr()).is_null());
            hgs_engine_free(e);
        }
    }
}
