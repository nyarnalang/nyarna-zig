const std = @import("std");

const errors = @import("../errors.zig");
const nyarna = @import("../nyarna.zig");
const model  = @import("../model.zig");
const types  = @import("../types.zig");

const LiteralNumber = @import("../parse.zig").LiteralNumber;

const totalOrderLess = @import("helpers.zig").totalOrderLess;

pub const EnumBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.Enum,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const inst = try ctx.global().create(model.Type.Instantiated);
    inst.* = .{
      .at = pos,
      .name = null,
      .data = .{.tenum = .{.values = .{}}},
    };
    return Self{.ctx = ctx, .ret = &inst.data.tenum};
  }

  pub inline fn add(self: *Self, value: []const u8, pos: model.Position) !void {
    try self.ret.values.put(self.ctx.global(), value, pos);
  }

  pub fn finish(self: *Self) *model.Type.Enum {
    return self.ret;
  }
};

/// Offers facilities to generate Intersection types. Assumes all given types
/// are either Record or Scalar types, and at most one Scalar type is given.
///
/// Types are to be given as list of `[]const model.Type`, where the types in
/// each slices are ordered according to the artificial type order. This API is
/// designed so that Record and Scalar types can be put in as single-value
/// slice, while referred Intersections will get the scalar part figured out
/// externally while the non-scalar part is a slice that fulfills our
/// precondition and can therefore be put in directly.
pub const IntersectionBuilder = struct {
  const Self = @This();

  fn Static(comptime size: usize) type {
    return struct {
      sources: [size][]const model.Type,
      indexes: [size]usize,

      pub fn init(sources: anytype) @This() {
        var ret: @This() = undefined;
        inline for (std.meta.fields(@TypeOf(sources))) |field, index| {
          const value = @field(sources, field.name);
          switch (@typeInfo(@TypeOf(value)).Pointer.size) {
            .One =>
              ret.sources[index] = @ptrCast([*]const model.Type, value)[0..1],
            .Slice => ret.sources[index] = value,
            else => unreachable,
          }
          ret.indexes[index] = 0;
        }
        return ret;
      }
    };
  }

  pub inline fn staticSources(sources: anytype) Static(sources.len) {
    return Static(sources.len).init(sources);
  }

  sources: [][]const model.Type,
  indexes: []usize,
  filled: usize,
  allocator: ?std.mem.Allocator,

  pub fn init(
    max_sources: usize,
    allocator: std.mem.Allocator,
  ) !Self {
    return Self{
      .sources = try allocator.alloc([]const model.Type, max_sources),
      .indexes = try allocator.alloc(usize, max_sources),
      .filled = 0,
      .allocator = allocator,
    };
  }

  pub fn calcFrom(lattice: *types.Lattice, input: anytype) !model.Type {
    var static = Static(input.len).init(input);
    var self = Self.initStatic(&static);
    return self.finish(lattice);
  }

  fn initStatic(static: anytype) Self {
    return Self{
      .sources = &static.sources,
      .indexes = &static.indexes,
      .filled = static.sources.len,
      .allocator = null,
    };
  }

  pub fn push(self: *Self, item: []const model.Type) void {
    for (item) |t| std.debug.assert(t.isScalar() or t.isInst(.record));
    self.sources[self.filled] = item;
    self.indexes[self.filled] = 0;
    self.filled += 1;
  }

  pub fn finish(self: *Self, lattice: *types.Lattice) !model.Type {
    var iter = types.Lattice.TreeNode(void).Iter{
      .cur = &lattice.prefix_trees.intersection, .lattice = lattice,
    };
    var tcount = @as(usize, 0);
    var scalar: ?model.Type = null;
    var input = self.sources[0..self.filled];
    while (true) {
      var cur_type: ?model.Type = null;
      for (input) |list, index| {
        if (list.len > self.indexes[index]) {
          const next = list[self.indexes[index]];
          if (cur_type) |previous| {
            if (totalOrderLess(undefined, next, previous)) cur_type = next;
          } else cur_type = next;
        }
      }
      if (cur_type) |next_type| {
        for (input) |list, index| {
          const list_index = self.indexes[index];
          if (list_index < list.len and list[list_index].eql(next_type)) {
            self.indexes[index] += 1;
          }
        }
        try iter.descend(next_type, {});
        if (next_type.isScalar()) {
          std.debug.assert(scalar == null);
          scalar = next_type;
        } else tcount += 1;
      } else break;
    }

    defer if (self.allocator) |allocator| {
      allocator.free(self.sources);
      allocator.free(self.indexes);
    };

    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try lattice.allocator.create(model.Type.Structural);
      new.* = .{.intersection = undefined};
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = scalar,
        .types = try lattice.allocator.alloc(model.Type, tcount),
      };
      var target_index = @as(usize, 0);
      for (input) |_, index| self.indexes[index] = 0;
      while (true) {
        var cur_type: ?model.Type = null;
        for (input) |vals, index| {
          if (self.indexes[index] < vals.len) {
            const next_in_list = vals[self.indexes[index]];
            if (cur_type) |previous| {
              if (totalOrderLess(undefined, next_in_list, previous))
                cur_type = next_in_list;
            } else cur_type = next_in_list;
          }
        }
        if (cur_type) |next_type| {
          for (self.sources) |vals, index| {
            const list_index = self.indexes[index];
            if (list_index < vals.len and vals[list_index].eql(next_type)) {
              self.indexes[index] += 1;
            }
          }
          if (next_type.isScalar()) {
            new_in.scalar = next_type;
          } else {
            new_in.types[target_index] = next_type;
            target_index += 1;
          }
        } else break;
      }
      iter.cur.value = new;
      break :blk new;
    }};
  }
};

pub const NumericBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.Numeric,
  pos: model.Position,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const inst = try ctx.global().create(model.Type.Instantiated);
    inst.* = .{
      .at = pos,
      .name = null,
      .data = .{.numeric = .{
        .min = std.math.minInt(i64),
        .max = std.math.maxInt(i64),
        // can be maximal 32. set to 33 to indicate errors during construction.
        .decimals = 0,
      }},
    };
    return Self{.ctx = ctx, .ret = &inst.data.numeric, .pos = pos};
  }

  pub fn min(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.decimals > self.ret.decimals) {
      self.ctx.logger.TooManyDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (
      @mulWithOverflow(i64, num.value,
      std.math.pow(i64, 10, @intCast(i64, self.ret.decimals - num.decimals)),
        &self.ret.min)
    ) {
      self.ctx.logger.NumberTooLarge(pos, num.repr);
      self.ret.decimals = 33;
    }
  }

  pub fn max(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.decimals > self.ret.decimals) {
      self.ctx.logger.TooManyDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (
      @mulWithOverflow(i64, num.value,
        std.math.pow(i64, 10, @intCast(i64, self.ret.decimals - num.decimals)),
        &self.ret.max)
    ) {
      self.ctx.logger.NumberTooLarge(pos, num.repr);
      self.ret.decimals = 33;
    }
  }

  pub fn decimals(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.value > 32 or num.value < 0 or num.decimals > 0) {
      self.ctx.logger.InvalidDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (self.ret.decimals != 33) {
      self.ret.decimals = @intCast(u8, num.value);
    }
  }

  pub fn finish(self: *Self) ?*model.Type.Numeric {
    if (self.ret.min > self.ret.max) {
      self.ctx.logger.IllegalNumericInterval(self.pos);
      self.ret.decimals = 33;
    }
    if (self.ret.decimals > 32) {
      self.abort();
      return null;
    }
    return self.ret;
  }

  pub fn abort(self: *Self) void {
    self.ctx.global().destroy(self.ret.instantiated());
  }
};

pub const ParagraphsBuilder = struct {
  const Self = @This();

  pub const Result = struct {
    scalar_type_sup: model.Type,
    resulting_type: model.Type,
  };

  pub const TypeAt = struct {
    t: model.Type,
    pos: model.Position,
  };

  ctx: nyarna.Context,
  list: std.ArrayListUnmanaged(model.Type) = .{},
  positions: std.ArrayListUnmanaged(model.Position) = .{},
  cur_scalar: model.Type,
  scalar_at: ?model.Position = null,
  non_voids: u21 = 0,
  /// if true, a \Paragraphs type will always be created. Also errors will be
  /// logged if pushed types are merged into previously given types.
  force: bool,
  poison: bool = false,

  pub fn init(ctx: nyarna.Context, force_paragraphs: bool) Self {
    return .{
      .ctx = ctx,
      .cur_scalar = ctx.types().every(),
      .force = force_paragraphs,
      .poison = false,
    };
  }

  pub fn push(self: *Self, spec: model.SpecType) !void {
    switch (spec.t) {
      .instantiated => |inst| switch (inst.data) {
        .void, .space => return,
        .poison => {
          self.poison = true;
          return;
        },
        else => {},
      },
      .structural => {},
    }
    self.non_voids += 1;
    for (self.list.items) |existing, i| {
      if (self.ctx.types().lesserEqual(spec.t, existing)) {
        if (self.force) {
          self.ctx.logger.TypesNotDisjoint(&[_]model.SpecType{
            spec, existing.at(self.positions.items[i]),
          });
        }
        return;
      }
    }
    if (types.containedScalar(spec.t)) |scalar_type| {
      if (self.force) {
        if (self.scalar_at) |prev_pos| {
          self.ctx.logger.MultipleScalarTypes(&[_]model.SpecType{
            scalar_type.at(spec.pos), self.cur_scalar.at(prev_pos),
          });
        } else {
          self.cur_scalar = scalar_type;
          self.scalar_at = spec.pos;
        }
      } else {
        self.cur_scalar =
          try self.ctx.types().sup(self.cur_scalar, scalar_type);
      }
    }
    try self.list.append(self.ctx.global(), spec.t);
    if (self.force) try self.positions.append(self.ctx.local(), spec.pos);
  }

  pub fn finish(self: *Self) !Result {
    if (self.force) {
      self.non_voids += 2;
      self.positions.deinit(self.ctx.local());
    }
    return if (self.poison) Result{
      .scalar_type_sup = self.cur_scalar,
      .resulting_type = self.ctx.types().poison(),
    } else switch (self.non_voids) {
      0 => Result{
        .scalar_type_sup = self.cur_scalar,
        .resulting_type = self.ctx.types().void(),
      },
      1 => Result{
        .scalar_type_sup = self.cur_scalar,
        .resulting_type = self.list.items[0],
      },
      else => blk: {
        for (self.list.items) |*inner_type| {
          if (types.containedScalar(inner_type.*) != null) {
            inner_type.* =
              try self.ctx.types().sup(self.cur_scalar, inner_type.*);
          }
        }
        break :blk Result{
          .scalar_type_sup = self.cur_scalar,
          .resulting_type =
            try self.ctx.types().calcParagraphs(self.list.items),
        };
      },
    };
  }
};