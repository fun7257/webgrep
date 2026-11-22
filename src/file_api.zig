//! Public facade for path sanitization, archive/encoding decoding,
//! metadata/tree listing, and O(window) positional file preview (`src/file_api/*`).

pub const paths = @import("file_api/paths.zig");
pub const meta_tree = @import("file_api/meta_tree.zig");
pub const archive_decode = @import("file_api/archive_decode.zig");
pub const window = @import("file_api/window.zig");

pub const PathError = paths.PathError;
pub const ARCHIVE_VIRTUAL_SEP = paths.ARCHIVE_VIRTUAL_SEP;
pub const ArchiveVirtualPath = paths.ArchiveVirtualPath;
pub const default_archive_options = paths.default_archive_options;
pub const builtin_types = paths.builtin_types;
pub const detectArchiveFormat = paths.detectArchiveFormat;
pub const isArchivePath = paths.isArchivePath;
pub const detectCompression = paths.detectCompression;
pub const splitArchiveVirtualPath = paths.splitArchiveVirtualPath;
pub const sanitizeArchiveEntryPath = paths.sanitizeArchiveEntryPath;
pub const formatArchiveVirtualPathAlloc = paths.formatArchiveVirtualPathAlloc;
pub const sanitizeRelPath = paths.sanitizeRelPath;
pub const decodeQueryParam = paths.decodeQueryParam;
pub const getQueryParamAlloc = paths.getQueryParamAlloc;
pub const isAlwaysSkippedDir = paths.isAlwaysSkippedDir;
pub const sanitizeUtf8Truncated = paths.sanitizeUtf8Truncated;
pub const stringifyAlloc = paths.stringifyAlloc;

pub const PluginMetaDto = meta_tree.PluginMetaDto;
pub const PresetMetaDto = meta_tree.PresetMetaDto;
pub const builtin_plugins = meta_tree.builtin_plugins;
pub const builtin_presets = meta_tree.builtin_presets;
pub const MetaResponse = meta_tree.MetaResponse;
pub const buildMetaJson = meta_tree.buildMetaJson;
pub const buildMetaWithScopesJson = meta_tree.buildMetaWithScopesJson;
pub const TreeEntry = meta_tree.TreeEntry;
pub const TreeResponse = meta_tree.TreeResponse;
pub const buildTreeJson = meta_tree.buildTreeJson;

pub const hasCompressedExtension = archive_decode.hasCompressedExtension;
pub const looksCompressedBytes = archive_decode.looksCompressedBytes;
pub const extractArchiveEntryFromSlice = archive_decode.extractArchiveEntryFromSlice;
pub const extractArchiveEntryFromDir = archive_decode.extractArchiveEntryFromDir;
pub const decodeTextSliceToUtf8 = archive_decode.decodeTextSliceToUtf8;

pub const FileLine = window.FileLine;
pub const FileResponse = window.FileResponse;
pub const FileWindowQuery = window.FileWindowQuery;
pub const buildPlainFileWindowJson = window.buildPlainFileWindowJson;
pub const buildSliceFileJson = window.buildSliceFileJson;
pub const buildFileJson = window.buildFileJson;
pub const buildFileJsonWithDisplayPath = window.buildFileJsonWithDisplayPath;
pub const buildFileWindowJsonWithDisplayPath = window.buildFileWindowJsonWithDisplayPath;

test {
    _ = @import("file_api/tests.zig");
}
