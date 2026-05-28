//! Regression test for the resurrection race that `sandbox_set_state` was
//! rewritten as a Lua script to close.
//!
//! Setup: a real Redis is required (uses DRAGONFLY_URL from .env.development
//! or the env). Test keys are namespaced under a per-run id so we don't
//! collide with a running dev manager.
//!
//! Two assertions:
//!   1. set_state(Error) on an existing key transitions state + removes from
//!      sandbox:active (the normal path mark_vm_dead relies on).
//!   2. set_state(Error) AFTER a concurrent sandbox_delete is a no-op:
//!      the key MUST NOT be resurrected. This is the bug the Lua rewrite
//!      fixes; before it, the read-modify-write would recreate the record.

use std::path::PathBuf;
use redis::AsyncCommands;

// Mirror crate::vm::{sandbox,size} so redis.rs's `use crate::vm::sandbox`
// resolves under the test binary. Lives in tests/vm/mod.rs to keep the
// `#[path]` reachability rules happy.
mod vm;
#[path = "../src/redis.rs"]
mod redis_mod;

use redis_mod::RedisClient;
use vm::sandbox::{Sandbox, SandboxKind, SandboxState};
use vm::size::VmSize;

fn dragonfly_url() -> String {
    if let Ok(u) = std::env::var("DRAGONFLY_URL") { return u; }
    // Fall back to .env.development so `cargo test` works locally.
    let env_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".env.development");
    dotenvy::from_path(&env_path).ok();
    std::env::var("DRAGONFLY_URL").expect("DRAGONFLY_URL not set and .env.development missing")
}

async fn make_client() -> RedisClient {
    RedisClient::connect(&dragonfly_url()).await.expect("connect redis")
}

fn unique_id(tag: &str) -> String {
    format!("test-{tag}-{}-{}", std::process::id(), uuid_like())
}

fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    format!("{n:x}")
}

async fn raw_conn() -> redis::aio::MultiplexedConnection {
    let url = dragonfly_url();
    redis::Client::open(url).unwrap()
        .get_multiplexed_async_connection().await.unwrap()
}

#[tokio::test]
async fn set_state_error_transitions_normally() {
    let r = make_client().await;
    let id = unique_id("normal");
    let user = unique_id("user");

    let mut sb = Sandbox::new_with_id(id.clone(), user.clone(), "tpl".into(), VmSize::default(), SandboxKind::Vm);
    sb.state = SandboxState::Running;
    r.sandbox_put(&sb).await.expect("put");

    // Precondition: in sandbox:active.
    let mut c = raw_conn().await;
    let active: bool = c.sismember("sandbox:active", &id).await.unwrap();
    assert!(active, "Running sandbox should be in sandbox:active");

    r.sandbox_set_state(&id, SandboxState::Error, Some("test")).await.expect("set_state");

    let got = r.sandbox_get(&id).await.unwrap().expect("still exists");
    assert_eq!(got.state, SandboxState::Error);
    assert_eq!(got.error.as_deref(), Some("test"));
    let active_after: bool = c.sismember("sandbox:active", &id).await.unwrap();
    assert!(!active_after, "Error state should be removed from sandbox:active");

    // cleanup
    r.sandbox_delete(&id).await.ok();
}

#[tokio::test]
async fn set_state_does_not_resurrect_deleted_record() {
    let r = make_client().await;
    let id = unique_id("racedelete");
    let user = unique_id("user");

    let mut sb = Sandbox::new_with_id(id.clone(), user.clone(), "tpl".into(), VmSize::default(), SandboxKind::Vm);
    sb.state = SandboxState::Running;
    r.sandbox_put(&sb).await.expect("put");

    // Simulate the race: delete the record, then try to mark Error as the
    // background reconciler would. Pre-Lua: this resurrects sandbox:<id>
    // (and leaves it orphaned from sandbox:user:<uid>). Post-Lua: no-op.
    r.sandbox_delete(&id).await.expect("delete");
    r.sandbox_set_state(&id, SandboxState::Error, Some("late mark")).await.expect("set_state late");

    let got = r.sandbox_get(&id).await.unwrap();
    assert!(got.is_none(), "sandbox_set_state after delete must NOT resurrect the key");

    let mut c = raw_conn().await;
    let active: bool = c.sismember("sandbox:active", &id).await.unwrap();
    assert!(!active, "deleted id must not reappear in sandbox:active");
}
