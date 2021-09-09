const std = @import("std");
const data = @import("data.zig");
const unicode = @import("load/unicode.zig");

/// This is Nyarna's type lattice. It calculates type intersections, checks type
/// compatibility, and owns all data of structural types.
pub const Lattice = struct {
  const Self = @This();

  /// allocator used for data of structural types
  alloc: *std.mem.Allocator,
};