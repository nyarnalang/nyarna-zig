const std = @import("std");
const ids = @import("ids").ids;

const Writer = struct {
  file  : std.Io.File,
  io    : std.Io,
  impl  : std.Io.File.Writer,
  output: *std.Io.Writer,

  fn init(self: *Writer, io: std.Io, path: []const u8, buffer: []u8) !void {
    self.file   = try std.Io.Dir.cwd().createFile(io, path, .{});
    self.io     = io;
    self.impl   = self.file.writer(io, buffer);
    self.output = &self.impl.interface;
  }

  fn writeHandlerFns(
    self: *Writer,
    comptime error_type: type,
    comptime params: anytype,
    comptime backend: []const u8,
  ) !void {
    inline for (@typeInfo(error_type).@"enum".field_names) |name| {
      try self.output.writeAll("pub fn ");
      try self.output.writeAll(name);
      try self.output.writeAll("(self: *@This()");
      inline for (params) |param| {
        try self.output.writeAll(", " ++ param[0] ++ ": " ++ param[1]);
      }
      try self.output.writeAll(\\) void {
        \\  self.count += 1;
        \\  self.reporter.
        ++ backend ++ "(self.reporter, ." ++ name);
      inline for (params) |param| try self.output.writeAll(", " ++ param[0]);
      try self.output.writeAll(\\);
        \\}
        \\
      );
    }
  }

  fn header(self: *Writer, content: []const u8) !void {
    try self.output.writeAll(content);
  }

  fn close(self: *Writer) !void {
    try self.output.flush();
    self.file.close(self.io);
  }
};

pub fn main(init: std.process.Init) !void {
  const args = try init.minimal.args.toSlice(init.arena.allocator());
  if (args.len != 2) {
    std.debug.print("usage: {s} <path to Handler.zig>\n", .{args[0]});
    std.process.exit(1);
  }
  var buffer: [4096]u8 = undefined;
  var handler: Writer = undefined;
  try handler.init(init.io, args[1], &buffer);
  try handler.header(
    \\const std = @import("std");
    \\
    \\const model  = @import("../model.zig");
    \\const errors = @import("../errors.zig");
    \\
    \\const WrongItemError = errors.WrongItemError;
    \\
    \\count: usize = 0,
    \\reporter: *errors.Reporter,
    \\
    \\
  );
  try handler.writeHandlerFns(
    ids.LexerError, .{.{"pos", "model.Position"}}, "lexerErrorFn");
  try handler.writeHandlerFns(
    ids.GenericParserError, .{.{"pos", "model.Position"}}, "parserErrorFn");
  try handler.writeHandlerFns(
    ids.WrongItemError, .{
      .{"pos", "model.Position"},
      .{"expected", "[]const WrongItemError.ItemDescr"},
      .{"got", "WrongItemError.ItemDescr"},
    }, "wrongItemErrorFn");
  try handler.writeHandlerFns(
    ids.ScalarError, .{.{"pos", "model.Position"}, .{"name", "[]const u8"}},
    "scalarErrorFn");
  try handler.writeHandlerFns(
    ids.PreviousOccurenceError, .{
      .{"repr", "[]const u8"},
      .{"pos", "model.Position"},
      .{"previous", "model.Position"},
    }, "previousOccurenceFn");
  try handler.writeHandlerFns(
    ids.PositionChainError, .{
      .{"pos", "model.Position"}, .{"referenced", "[]model.Position"},
    }, "posChainFn");
  try handler.writeHandlerFns(
    ids.WrongIdError, .{
      .{"pos", "model.Position"},
      .{"expected", "[]const u8"},
      .{"got", "[]const u8"},
      .{"defined_at", "model.Position"},
    }, "wrongIdErrorFn");
  try handler.writeHandlerFns(
    ids.TypeError,
    .{.{"types", "[]const model.SpecType"}},
    "typeErrorFn");
  try handler.writeHandlerFns(
    ids.ConstructionError, .{
      .{"pos", "model.Position"},
      .{"t", "model.Type"},
      .{"repr", "[]const u8"},
    }, "constructionErrorFn");
  try handler.writeHandlerFns(
    ids.RuntimeError, .{
      .{"pos", "model.Position"},
      .{"msg", "[]const u8"},
    }, "runtimeErrorFn");
  try handler.writeHandlerFns(
    ids.SystemNyError, .{.{"pos", "model.Position"}, .{"msg", "[]const u8"}},
    "systemNyErrorFn");
  try handler.writeHandlerFns(
    ids.FileError, .{
      .{"pos", "model.Position"},
      .{"path", "[]const u8"},
      .{"message", "[]const u8"},
    }, "fileErrorFn");
  try handler.close();
}
