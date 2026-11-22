//! Public facade for the multi-source registry (`src/registry/*`).

pub const types = @import("registry/types.zig");
pub const store = @import("registry/store.zig");
pub const preview = @import("registry/preview.zig");
pub const suggest = @import("registry/suggest.zig");

pub const PluginsOverrideDto = types.PluginsOverrideDto;
pub const SourceConfigDto = types.SourceConfigDto;
pub const SourceKindMetaDto = types.SourceKindMetaDto;
pub const builtin_source_kinds = types.builtin_source_kinds;
pub const SourceInfoDto = types.SourceInfoDto;
pub const SourcesResponse = types.SourcesResponse;
pub const SearchableSource = types.SearchableSource;
pub const UpsertSourceRequest = types.UpsertSourceRequest;
pub const ToggleSourceRequest = types.ToggleSourceRequest;
pub const DeleteSourceRequest = types.DeleteSourceRequest;
pub const DirSuggestEntry = types.DirSuggestEntry;
pub const DirSuggestResponse = types.DirSuggestResponse;
pub const RegistryError = types.RegistryError;
pub const generateUuidV4Alloc = types.generateUuidV4Alloc;
pub const isValidUuid = types.isValidUuid;
pub const sanitizeNameAlloc = types.sanitizeNameAlloc;
pub const SourceRegistry = store.SourceRegistry;

test {
    _ = @import("registry/tests.zig");
}
