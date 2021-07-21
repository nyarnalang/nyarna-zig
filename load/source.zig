const std = @import("std");

/// A source provides content to be parsed. This is usually a source file.
pub const Source = struct {
  /// the content of the source that is to be parsed
  content: []const u8,
  /// offsets if the source is part of a larger file.
  /// these will be added to line/column reporting.
  offsets: struct {
    line: usize = 0,
    column: usize = 0
  },
  /// the name that is to be used for reporting errors.
  /// usually the path of the file.
  name: []const u8,
  /// the absolute locator that identifies this source.
  locator: []const u8,
  /// the locator minus its final element, used for resolving
  /// relative locators inside this source.
  locator_ctx: []const u8,
};