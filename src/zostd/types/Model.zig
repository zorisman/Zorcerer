//! Opaque engine `model_t`.
//!
//! `IVModelInfo::GetModel()` returns a borrowed pointer
//! (`src/public/engine/ivmodelinfo.h:106-108`). The plugin must not free it or
//! assume it survives a level/model-cache change. Use `ModelIndex` when a value
//! is needed; use this pointer only for the duration of the engine call that
//! supplied it.

pub const Model = opaque {};

/// A borrowed `const model_t*`.
pub const ModelPtr = *const Model;
