//! Shared tokio runtime for FFI boundary functions.
//!
//! All FFI functions block the caller. Internally, async Rust code runs
//! on a shared `tokio::runtime::Runtime` managed via `OnceLock`. This
//! avoids the overhead of constructing a new runtime per FFI call.
//!
//! **Constraint:** FFI callers must NOT call from a tokio thread, or
//! `block_on` will panic. Platform callers (Swift main thread, C# .NET
//! thread) are always safe.

use std::future::Future;
use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

/// Stack size for the runtime's worker threads and the `block_on` driver
/// thread.
///
/// tokio's default worker stack is 2 MiB. The aws-smithy S3 endpoint-resolution
/// and orchestrator chain is extremely deep and monomorphizes into large stack
/// frames — in debug builds it overflows a 2 MiB stack and faults
/// (`EXC_BAD_ACCESS` inside `resolve_endpoint`). 8 MiB matches the platform
/// main-thread default and gives ample headroom; harmless in release.
const WORKER_STACK_SIZE: usize = 8 * 1024 * 1024;

/// Returns a reference to the shared tokio runtime.
///
/// The runtime is lazily initialized on first use and lives for the
/// duration of the process. All FFI functions use this runtime to
/// execute async Rust code.
pub fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(WORKER_STACK_SIZE)
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// Drives `future` to completion, blocking the caller, and returns its output.
///
/// FFI callers reach us from Apple's GCD / Swift-concurrency cooperative thread
/// pool (`com.apple.root.*.cooperative`), whose threads have small (~512 KiB)
/// stacks. `Runtime::block_on` polls the root future on the *calling* thread,
/// and the aws-smithy S3 endpoint-resolution chain is deep enough (especially
/// in debug builds) to overflow that stack — faulting with `EXC_BAD_ACCESS`
/// inside `resolve_endpoint`. We drive the future on an owned thread with a
/// large stack instead. `std::thread::scope` lets the future borrow caller
/// locals (the S3 client, session, …) without requiring `'static`, and the
/// owned thread is never a tokio worker, so `block_on` cannot panic on it.
///
/// ponytail: one short-lived OS thread per FFI call. These calls are network
/// round-trips (ms+), so the ~µs spawn cost is noise. If call volume ever makes
/// it matter, replace with a single long-lived big-stack driver thread fed via
/// a channel.
pub fn block_on<F>(future: F) -> F::Output
where
    F: Future + Send,
    F::Output: Send,
{
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("ds3-block-on".into())
            .stack_size(WORKER_STACK_SIZE)
            .spawn_scoped(scope, move || runtime().block_on(future))
            .expect("failed to spawn block_on driver thread")
            .join()
            .expect("block_on driver thread panicked")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runtime_returns_same_instance() {
        let rt1 = runtime() as *const Runtime;
        let rt2 = runtime() as *const Runtime;
        assert_eq!(rt1, rt2, "runtime() should return the same instance");
    }

    #[test]
    fn test_runtime_can_block_on() {
        let result = runtime().block_on(async { 42 });
        assert_eq!(result, 42);
    }

    #[test]
    fn test_block_on_drives_to_completion_and_borrows_locals() {
        // The future borrows a local (`&name`) — proving `block_on` works
        // without a `'static` bound, which is why FFI call sites can pass
        // futures that borrow the S3 client / session.
        let name = String::from("ds3");
        let out = block_on(async { format!("{}-{}", name, 40 + 2) });
        assert_eq!(out, "ds3-42");
    }
}
