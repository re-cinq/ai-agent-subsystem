//! Types and a small client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
//! Custom Resources. The types in [`types`] are generated from the D structs that define the CRDs, so
//! they cannot drift; [`AgentContractsClient`] creates runs, waits for them and applies recipes.

mod client;
#[rustfmt::skip]
pub mod types;

pub use client::{AgentContractsClient, DEFAULT_NAMESPACE, Error, is_terminal};
pub use types::*;
