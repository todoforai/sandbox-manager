//! Shim so integration tests can `#[path = "../src/redis.rs"] mod redis;`
//! and have it resolve `crate::vm::sandbox` / `crate::vm::size` correctly.
#[path = "../../src/vm/size.rs"]
pub mod size;
#[path = "../../src/vm/sandbox.rs"]
pub mod sandbox;
