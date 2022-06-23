const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;
const Types       = nyarna.Types;

const IntersectionChecker = @This();

const Result = struct {
  scalar: ?model.Type = null,
  append: ?[]const model.Type = null,
  failed: bool = false,
};

intpr  : *Interpreter,
scalar : ?model.SpecType = null,
unique : bool,

pub fn init(intpr  : *Interpreter, unique : bool) IntersectionChecker {
  return .{
    .intpr   = intpr,
    .unique  = unique,
  };
}

/// builder shall always be the same. The pointer is put in the struct fields
/// for simpler interfacing particularly with value copying in init() functions.
pub fn push(
  self   : *@This(),
  builder: *Types.IntersectionBuilder,
  t      : *const model.Type,
  pos    : model.Position,
) !bool {
  var result: Result = switch (t.*) {
    .structural => |strct| switch (strct.*) {
      .intersection => |*ci| Result{
        .scalar = ci.scalar, .append = ci.types,
      },
      else => Result{.failed = true},
    },
    .named => |named| switch (named.data) {
      .textual, .space, .literal => Result{.scalar = t.*},
      .int, .float, .@"enum" => if (self.unique) {
        self.intpr.ctx.logger.InvalidMatchType(&.{t.at(pos)});
        return false;
      } else Result{.scalar = self.intpr.ctx.types().text()},
      .record =>
        Result{.append = @ptrCast([*]const model.Type, t)[0..1]},
      else => Result{.failed = true},
    },
  };

  if (result.failed) {
    if (self.unique) {
      self.intpr.ctx.logger.InvalidMatchType(&.{t.at(pos)});
    } else {
      self.intpr.ctx.logger.InvalidInnerIntersectionType(&.{t.at(pos)});
    }
  }
  if (result.scalar) |s| {
    if (self.scalar) |prev| {
      if (!s.eql(prev.t)) {
        self.intpr.ctx.logger.MultipleScalarTypes(&.{s.at(pos), prev});
        result.failed = true;
      } else if (self.unique) {
        const t_fmt = s.formatter();
        const repr =
          try std.fmt.allocPrint(self.intpr.allocator(), "{}", .{t_fmt});
        defer self.intpr.allocator().free(repr);
        self.intpr.ctx.logger.DuplicateMatchType(repr, pos, prev.pos);
        result.failed = true;
      }
    } else {
      self.scalar = s.at(pos);
      return true;
    }
  }
  if (result.append) |append| {
    if (self.unique) {
      if (builder.pushUnique(&append[0], pos)) |prev| {
        const t_fmt = append[0].formatter();
        const repr =
          try std.fmt.allocPrint(self.intpr.allocator(), "{}", .{t_fmt});
        defer self.intpr.allocator().free(repr);
        self.intpr.ctx.logger.DuplicateMatchType(repr, pos, prev);
        result.failed = true;
      }
    } else {
      builder.push(append);
    }
  }
  return !result.failed;
}

pub fn finish(
  self   : *@This(),
  builder: *Types.IntersectionBuilder,
) !model.Type {
  if (self.scalar) |*found_scalar| {
    builder.push(@ptrCast([*]const model.Type, &found_scalar.t)[0..1]);
  }
  return try builder.finish(self.intpr.ctx.types());
}