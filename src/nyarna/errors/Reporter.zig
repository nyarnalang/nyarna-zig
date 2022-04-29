const std = @import("std");

const errors = @import("../errors.zig");
const model  = @import("../model.zig");

lexerErrorFn: fn(
  reporter: *@This(),
  id      : errors.LexerError,
  pos     : model.Position,
) void,

parserErrorFn: fn(
  reporter: *@This(),
  id      : errors.GenericParserError,
  pos     : model.Position,
) void,

wrongItemErrorFn: fn(
  reporter: *@This(),
  id      : errors.WrongItemError,
  pos     : model.Position,
  expected: []const errors.WrongItemError.ItemDescr,
  got     : errors.WrongItemError.ItemDescr,
) void,

scalarErrorFn: fn(
  reporter: *@This(),
  id      : errors.ScalarError,
  pos     : model.Position,
  repr    : []const u8,
) void,

wrongIdErrorFn: fn(
  reporter  : *@This(),
  id        : errors.WrongIdError,
  pos       : model.Position,
  expected  : []const u8,
  got       : []const u8,
  defined_at: model.Position,
) void,

previousOccurenceFn: fn(
  reporter: *@This(),
  id      : errors.PreviousOccurenceError,
  repr    : []const u8,
  pos     : model.Position,
  previous: model.Position,
) void,

posChainFn: fn(
  reporter  : *@This(),
  id        : errors.PositionChainError,
  pos       : model.Position,
  references: []model.Position,
) void,

typeErrorFn: fn(
  reporter: *@This(),
  id      : errors.TypeError,
  types   : []const model.SpecType,
) void,

constructionErrorFn: fn(
  reporter: *@This(),
  id      : errors.ConstructionError,
  pos     : model.Position,
  t       : model.Type,
  repr    : []const u8,
) void,

runtimeErrorFn: fn(
  reporter: *@This(),
  id      : errors.RuntimeError,
  pos     : model.Position,
  msg     : []const u8,
) void,

systemNyErrorFn: fn (
  reporter: *@This(),
  id      : errors.SystemNyError,
  pos     : model.Position,
  msg     : []const u8,
) void,

fileErrorFn: fn(
  reporter: *@This(),
  id      : errors.FileError,
  pos     : model.Position,
  path    : []const u8,
  message : []const u8,
) void,