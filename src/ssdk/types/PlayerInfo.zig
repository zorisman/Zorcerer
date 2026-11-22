/// `MAX_PLAYER_NAME_LENGTH` (const.h:41 [checkout]).
pub const max_player_name_len: usize = 32;

/// `SIGNED_GUID_LEN + 1` (const.h:74 [checkout]): 32 hashed characters plus
/// the terminator.
pub const max_guid_len: usize = 33;

/// `MAX_CUSTOM_FILES` (const.h:99 [checkout]).
pub const max_custom_files: usize = 4;

/// The subset of `player_info_t` (cdll_int.h:71-96 [checkout]) this module
/// reads. The struct keeps the full layout, including `customFiles` and
/// `filesDownloaded`, because the engine writes the complete C++ object.
///
/// `REPLAY_ENABLED` adds `isreplay` after `ishltv`; the following fields stay
/// aligned either way, so this layout is valid for both configurations.
pub const PlayerInfo = extern struct {
    /// `name[MAX_PLAYER_NAME_LENGTH]`.
    name: [max_player_name_len]u8,
    /// `userID`.
    user_id: c_int,
    /// `guid[SIGNED_GUID_LEN + 1]`.
    guid: [max_guid_len]u8,
    /// Padding before the 4-byte-aligned `friendsID`.
    padding0: [3]u8,
    /// `friendsID`.
    friends_id: u32,
    /// `friendsName[MAX_PLAYER_NAME_LENGTH]`.
    friends_name: [max_player_name_len]u8,
    /// `fakeplayer`.
    fake_player: bool,
    /// `ishltv`.
    is_hltv: bool,
    /// `isreplay` when `REPLAY_ENABLED` is set; otherwise padding.
    is_replay: bool,
    /// Padding before the 4-byte-aligned `customFiles`.
    padding1: u8,
    /// `customFiles[MAX_CUSTOM_FILES]`.
    custom_files: [max_custom_files]u32,
    /// `filesDownloaded`.
    files_downloaded: u8,
    /// Trailing padding to the struct's 4-byte alignment.
    padding2: [3]u8,
};

comptime {
    // These offsets are the Itanium C++ ABI layout of the declarations in
    // cdll_int.h [checkout]. Keeping them explicit makes an accidental field
    // reorder a compile error rather than a silent misread.
    if (@offsetOf(PlayerInfo, "user_id") != 32) @compileError("player_info_t.userID moved");
    if (@offsetOf(PlayerInfo, "guid") != 36) @compileError("player_info_t.guid moved");
    if (@offsetOf(PlayerInfo, "friends_id") != 72) @compileError("player_info_t.friendsID moved");
    if (@offsetOf(PlayerInfo, "friends_name") != 76) @compileError("player_info_t.friendsName moved");
    if (@offsetOf(PlayerInfo, "fake_player") != 108) @compileError("player_info_t.fakeplayer moved");
    if (@offsetOf(PlayerInfo, "custom_files") != 112) @compileError("player_info_t.customFiles moved");
}
