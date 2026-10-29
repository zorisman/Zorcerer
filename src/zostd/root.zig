//! Zorcerer standard library (`zostd`) type declarations.
//!
//! This module is the Zig-facing entry point for the strongly typed values
//! that plugins exchange with the host. It re-exports every type under
//! `src/zostd/types` so consumers (including the ZLua bridge) do not need
//! file-path imports that escape their own module root.
//!
//! The declarations are value types or opaque borrowed pointers. None of them
//! own engine resources; see each type's documentation for its invariants,
//! lifetime, and validity rules.

pub const types = struct {
    /// Source damage flag mask (`DMG_*`).
    pub const DamageMask = @import("types/DamageMask.zig").DamageMask;

    /// Opaque engine entity (`edict_t`) and its borrowed pointer aliases.
    pub const Edict = @import("types/Edict.zig").Edict;
    pub const EdictPtr = @import("types/Edict.zig").EdictPtr;
    pub const ConstEdictPtr = @import("types/Edict.zig").ConstEdictPtr;

    /// A networkable edict slot index.
    pub const EdictIndex = @import("types/EdictIndex.zig").EdictIndex;

    /// Stable 32-bit identity of a Source engine entity.
    pub const EntityHandle = @import("types/EntityHandle.zig").EntityHandle;

    /// A full entity-list slot index.
    pub const EntityIndex = @import("types/EntityIndex.zig").EntityIndex;

    /// Opaque Source filesystem file handle (`FileHandle_t`).
    pub const FileHandle = @import("types/FileHandle.zig").FileHandle;

    /// Opaque engine `model_t` and its borrowed pointer alias.
    pub const Model = @import("types/Model.zig").Model;
    pub const ModelPtr = @import("types/Model.zig").ModelPtr;

    /// Source model index with the encoded precached/dynamic split.
    pub const ModelIndex = @import("types/ModelIndex.zig").ModelIndex;

    /// Asynchronous client-cvar query cookie (`QueryCvarCookie_t`).
    pub const QueryCvarCookie = @import("types/QueryCvarCookie.zig").QueryCvarCookie;

    /// Opaque `string_t` token.
    pub const StringToken = @import("types/StringToken.zig").StringToken;

    /// TF2 player class value (`ETFClass`).
    pub const TfClass = @import("types/TfClass.zig").TfClass;

    /// TF2 condition ID (`ETFCond`).
    pub const TfCondition = @import("types/TfCondition.zig").TfCondition;

    /// TF2 buildable object type (`ObjectType_t`).
    pub const TfObjectType = @import("types/TfObjectType.zig").TfObjectType;

    /// TF2 team value.
    pub const TfTeam = @import("types/TfTeam.zig").TfTeam;

    /// TF2 weapon archetype ID (`ETFWeaponType`).
    pub const TfWeaponId = @import("types/TfWeaponId.zig").TfWeaponId;
};

/// Source damage flag mask (`DMG_*`).
pub const DamageMask = types.DamageMask;
/// Opaque engine entity (`edict_t`).
pub const Edict = types.Edict;
/// Borrowed `edict_t*`.
pub const EdictPtr = types.EdictPtr;
/// Borrowed `const edict_t*`.
pub const ConstEdictPtr = types.ConstEdictPtr;
/// A networkable edict slot index.
pub const EdictIndex = types.EdictIndex;
/// Stable 32-bit identity of a Source engine entity.
pub const EntityHandle = types.EntityHandle;
/// A full entity-list slot index.
pub const EntityIndex = types.EntityIndex;
/// Opaque Source filesystem file handle (`FileHandle_t`).
pub const FileHandle = types.FileHandle;
/// Opaque engine `model_t`.
pub const Model = types.Model;
/// Borrowed `const model_t*`.
pub const ModelPtr = types.ModelPtr;
/// Source model index with the encoded precached/dynamic split.
pub const ModelIndex = types.ModelIndex;
/// Asynchronous client-cvar query cookie (`QueryCvarCookie_t`).
pub const QueryCvarCookie = types.QueryCvarCookie;
/// Opaque `string_t` token.
pub const StringToken = types.StringToken;
/// TF2 player class value (`ETFClass`).
pub const TfClass = types.TfClass;
/// TF2 condition ID (`ETFCond`).
pub const TfCondition = types.TfCondition;
/// TF2 buildable object type (`ObjectType_t`).
pub const TfObjectType = types.TfObjectType;
/// TF2 team value.
pub const TfTeam = types.TfTeam;
/// TF2 weapon archetype ID (`ETFWeaponType`).
pub const TfWeaponId = types.TfWeaponId;
