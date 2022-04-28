const std = @import("std");

const errors = @import("../errors.zig");
const nyarna = @import("../nyarna.zig");
const model  = @import("../model.zig");

const Lattice  = @import("../types.zig").Lattice;

const LiteralNumber = @import("../parse.zig").LiteralNumber;

const totalOrderLess = @import("helpers.zig").totalOrderLess;
const gcd            = @import("../helpers.zig").gcd;

pub const EnumBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.Enum,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const named = try ctx.global().create(model.Type.Named);
    named.* = .{
      .at = pos,
      .name = null,
      .data = .{.@"enum" = .{.values = .{}}},
    };
    return Self{.ctx = ctx, .ret = &named.data.@"enum"};
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

  pub fn calcFrom(lattice: *Lattice, input: anytype) !model.Type {
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
    for (item) |t| std.debug.assert(t.isScalar() or t.isNamed(.record));
    self.sources[self.filled] = item;
    self.indexes[self.filled] = 0;
    self.filled += 1;
  }

  pub fn finish(self: *Self, lattice: *Lattice) !model.Type {
    var iter = Lattice.TreeNode(void).Iter{
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

pub const IntNumBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.IntNum,
  pos: model.Position,
  failed: bool = false,
  positions: std.ArrayListUnmanaged(model.Position) = .{},
  units: std.ArrayListUnmanaged(model.Type.IntNum.Unit) = .{},
  /// factor with which each given unit's factor is multiplied so that the
  /// smallest unit has factor `1`.
  cur_factor: i64 = 1,
  /// this will be set as soon as units.len > 0
  smallest_factor: usize = undefined,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const named = try ctx.global().create(model.Type.Named);
    named.* = .{
      .at = pos,
      .name = null,
      .data = .{.int = .{
        .min = std.math.minInt(i64),
        .max = std.math.maxInt(i64),
        .suffixes = undefined,
      }},
    };
    return Self{.ctx = ctx, .ret = &named.data.int, .pos = pos};
  }

  pub fn unit(
    self: *Self,
    pos: model.Position,
    factor: LiteralNumber,
    suffix: []const u8,
  ) !void {
    if (factor.value < 0) {
      self.ctx.logger.FactorMustntBeNegative(pos, factor.repr);
      return;
    }
    for (self.units.items) |item, index| {
      if (std.mem.eql(u8, item.suffix, suffix)) {
        self.ctx.logger.DuplicateSuffix(
          suffix, pos, self.positions.items[index]);
        return;
      }
    }

    var coeff = self.cur_factor;
    var divisor = std.math.pow(i64, 10, factor.decimals);
    const g = gcd(coeff, divisor);
    coeff = @divExact(coeff, g);
    divisor = @divExact(divisor, g);

    var actual: i64 = undefined;
    if (divisor == 1) {
      if (@mulWithOverflow(i64, factor.value, coeff, &actual)) {
        self.ctx.logger.FactorsTooFarApart(
          factor.repr, pos, self.positions.items[self.smallest_factor]);
        return;
      }
    } else {
      const x = @mod(factor.value, divisor);
      const additional = @divExact(divisor, gcd(divisor, x));
      for (self.units.items) |*item, index| {
        if (@mulWithOverflow(i64, item.factor, additional, &item.factor)) {
          self.ctx.logger.FactorsTooFarApart(
            factor.repr, pos, self.positions.items[index]);
          return;
        }
      }
      self.cur_factor *= additional;
      actual = 1;
    }
    try self.units.append(
      self.ctx.global(), .{.suffix = suffix, .factor = actual});
    try self.positions.append(self.ctx.local(), pos);
  }

  fn setNum(
    self: *Self,
    input: LiteralNumber,
    pos: model.Position,
    target: *i64,
  ) bool {
    if (input.suffix.len > 0) {
      for (self.units.items) |item| {
        if (std.mem.eql(u8, item.suffix, input.suffix)) {
          return self.ctx.applyIntUnit(item, input, pos, target);
        }
      } else {
        self.ctx.logger.MustHaveDefinedSuffix(pos, input.repr);
        return false;
      }
    } else if (self.units.items.len > 0) {
      self.ctx.logger.MustHaveDefinedSuffix(pos, input.repr);
      return false;
    } else if (input.decimals > 0) {
      self.ctx.logger.InvalidDecimals(pos, input.repr);
      return false;
    } else {
      target.* = input.value;
      return true;
    }
  }

  pub fn min(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (!self.setNum(num, pos, &self.ret.min)) {
      self.ret.min = std.math.minInt(i64);
    }
  }

  pub fn max(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (!self.setNum(num, pos ,&self.ret.max)) {
      self.ret.max = std.math.maxInt(i64);
    }
  }

  pub fn finish(self: *Self) ?*model.Type.IntNum {
    if (self.ret.min > self.ret.max) {
      self.ctx.logger.IllegalNumericInterval(self.pos);
      self.failed = true;
    }
    if (self.failed) {
      self.abort();
      return null;
    }
    self.ret.suffixes = self.units.items;
    self.positions.deinit(self.ctx.local());
    return self.ret;
  }

  pub fn abort(self: *Self) void {
    self.ctx.global().destroy(self.ret.named());
  }
};

pub const FloatNumBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.FloatNum,
  pos: model.Position,
  failed: bool = false,
  positions: std.ArrayListUnmanaged(model.Position) = .{},
  units: std.ArrayListUnmanaged(model.Type.FloatNum.Unit) = .{},

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const named = try ctx.global().create(model.Type.Named);
    named.* = .{
      .at = pos,
      .name = null,
      .data = .{.float = .{
        .min = -std.math.inf_f64,
        .max = std.math.inf_f64,
        .suffixes = undefined,
      }},
    };
    return Self{.ctx = ctx, .ret = &named.data.float, .pos = pos};
  }

  pub fn unit(
    self: *Self,
    pos: model.Position,
    factor: LiteralNumber,
    suffix: []const u8,
  ) !void {
    if (factor.value < 0) {
      self.ctx.logger.FactorMustntBeNegative(pos, factor.repr);
      return;
    }
    for (self.units.items) |item, index| {
      if (std.mem.eql(u8, item.suffix, suffix)) {
        self.ctx.logger.DuplicateSuffix(
          suffix, pos, self.positions.items[index]);
        return;
      }
    }
    const divisor = std.math.pow(f64, 10, @intToFloat(f64, factor.decimals));
    try self.units.append(self.ctx.global(), .{
      .suffix = suffix,
      .factor = @intToFloat(f64, factor.value) / divisor,
    });
    try self.positions.append(self.ctx.local(), pos);
  }

  fn setNum(
    self: *Self,
    input: LiteralNumber,
    pos: model.Position,
    target: *f64,
  ) bool {
    if (input.suffix.len > 0) {
      for (self.units.items) |item| {
        if (std.mem.eql(u8, item.suffix, input.suffix)) {
          target.* = nyarna.Context.applyFloatUnit(item, input);
          return true;
        }
      } else {
        self.ctx.logger.MustHaveDefinedSuffix(pos, input.repr);
        return false;
      }
    } else if (self.units.items.len > 0) {
      self.ctx.logger.MustHaveDefinedSuffix(pos, input.repr);
      return false;
    } else {
      target.* = @intToFloat(f64, input.value) /
        std.math.pow(f64, 10, @intToFloat(f64, input.decimals));
      return true;
    }
  }

  pub fn min(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (!self.setNum(num, pos, &self.ret.min)) {
      self.ret.min = -std.math.inf_f64;
    }
  }

  pub fn max(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (!self.setNum(num, pos, &self.ret.max)) {
      self.ret.max = std.math.inf_f64;
    }
  }

  pub fn finish(self: *Self) ?*model.Type.FloatNum {
    if (self.ret.min > self.ret.max) {
      self.ctx.logger.IllegalNumericInterval(self.pos);
      self.failed = true;
    }
    if (self.failed) {
      self.abort();
      return null;
    }
    self.ret.suffixes = self.units.items;
    self.positions.deinit(self.ctx.local());
    return self.ret;
  }

  pub fn abort(self: *Self) void {
    self.ctx.global().destroy(self.ret.named());
  }
};

pub const SequenceBuilder = struct {
  const Self = @This();

  pub const TypeAt = struct {
    t: model.Type,
    pos: model.Position,
  };

  pub const PushResult = union(enum) {
    not_disjoint: model.SpecType,
    not_compatible: model.SpecType,
    invalid_non_void: model.SpecType,
    invalid_direct, invalid_inner, success,

    pub fn report(
      self: PushResult,
      cur: model.SpecType,
      logger: *errors.Handler,
    ) void {
      switch (self) {
        .not_disjoint => |t| logger.TypesNotDisjoint(&.{cur, t}),
        .not_compatible => |t| logger.IncompatibleTypes(&.{cur, t}),
        .invalid_non_void => |t|
          logger.NonEmptyAfterNonSequentiable(&.{cur, t}),
        .invalid_direct => logger.InvalidDirectSequenceType(&.{cur}),
        .invalid_inner => logger.InvalidInnerSequenceType(&.{cur}),
        .success => {},
      }
    }
  };

  pub const BuildResult = struct {
    t: model.Type,
    auto: union(enum) {
      not_disjoint: model.SpecType,
      success,invalid_inner,
    },

    pub fn report(
      self: BuildResult,
      auto_type: ?model.SpecType,
      logger: *errors.Handler,
    ) void {
      switch (self.auto) {
        .not_disjoint => |t| logger.TypesNotDisjoint(&.{auto_type.?, t}),
        .invalid_inner => logger.InvalidInnerSequenceType(&.{auto_type.?}),
        .success => {},
      }
    }
  };

  types: *Lattice,
  temp_alloc: std.mem.Allocator,
  direct: ?model.SpecType = null,
  single: ?model.SpecType = null,
  list: std.ArrayListUnmanaged(*model.Type.Record) = .{},
  positions: std.ArrayListUnmanaged(model.Position) = .{},
  non_voids: u21 = 0,
  /// if true, a \Sequence type will always be created. Also errors will be
  /// logged if pushed types are merged into previously given types.
  force: bool,
  poison: bool = false,

  pub fn init(
    types: *Lattice,
    temp_alloc: std.mem.Allocator,
    force: bool,
  ) Self {
    return .{
      .types = types,
      .temp_alloc = temp_alloc,
      .force = force,
      .poison = false,
    };
  }

  fn errorIfForced(self: *Self, force_direct: bool) PushResult {
    if (self.force) {
      return if (force_direct)
        PushResult.invalid_direct else PushResult.invalid_inner;
    } else return PushResult.success;
  }

  fn mergeType(
    self: *Self,
    spec: model.SpecType,
    force_direct: bool,
  ) std.mem.Allocator.Error!PushResult {
    const to_add = switch (spec.t) {
      .named => |named| switch (named.data) {
        .void, .space => return self.errorIfForced(force_direct),
        .poison => {
          self.poison = true;
          return PushResult.success;
        },
        .record => |*rec| {
          // OPPORTUNITY: sort this list here?
          for (self.list.items) |item, i| {
            if (item.typedef().eql(spec.t)) {
              return if (self.force) PushResult{
                .not_disjoint = item.typedef().at(self.positions.items[i])
              } else PushResult.success;
            }
          }
          try self.list.append(self.types.allocator, rec);
          try self.positions.append(self.temp_alloc, spec.pos);
          self.non_voids += 1;
          return PushResult.success;
        },
        .textual, .location, .definition, .literal, .every => spec,
        .@"enum" => blk: {
          const res = self.errorIfForced(force_direct);
          if (res != .success) return res;
          break :blk self.types.system.identifier.at(spec.pos);
        },
        .float, .int => blk: {
          const res = self.errorIfForced(force_direct);
          if (res != .success) return res;
          break :blk self.types.text().at(spec.pos);
        },
        else => {
          const res = self.errorIfForced(force_direct);
          if (res == .success) {
            self.non_voids += 1;
            if (self.direct) |direct| return PushResult{.not_disjoint = direct};
            if (self.list.items.len > 0) {
              return PushResult{.not_disjoint =
                self.list.items[0].typedef().at(self.positions.items[0])};
            }
            self.single = spec;
          }
          return res;
        },
      },
      .structural => |struc| switch (struc.*) {
        .optional => |*opt| {
          const res = self.errorIfForced(force_direct);
          if (res != .success) return res;
          return try self.mergeType(opt.inner.at(spec.pos), force_direct);
        },
        .callable, .list, .map => {
          const res = self.errorIfForced(force_direct);
          if (res == .success) {
            self.non_voids += 1;
            if (self.direct) |direct| return PushResult{.not_disjoint = direct};
            if (self.list.items.len > 0) {
              return PushResult{.not_disjoint =
                self.list.items[0].typedef().at(self.positions.items[0])};
            }
            self.single = spec;
          }
          return res;
        },
        .concat, .intersection => spec,
        .sequence => |*seq| {
          self.non_voids += 1;
          if (seq.direct) |other_direct| {
            const res = try self.push(other_direct.at(spec.pos), true);
            if (res != .success) return res;
          }
          for (seq.inner) |inner| {
            const res = try self.push(inner.typedef().at(spec.pos), false);
            if (res != .success) return res;
          }
          return PushResult.success;
        },
      },
    };
    self.non_voids += 1;
    if (self.direct) |direct| {
      const sup = try self.types.sup(direct.t, to_add.t);
      std.debug.assert(!sup.isNamed(.poison));
      self.direct = sup.at(direct.pos.span(to_add.pos));
    } else {
      self.direct = to_add;
    }
    return PushResult.success;
  }

  /// returns the previous type the pushed type is incompatible with, if any.
  pub fn push(
    self: *Self,
    spec: model.SpecType,
    force_direct: bool,
  ) std.mem.Allocator.Error!PushResult {
    if (self.single) |single| {
      switch (spec.t) {
        .named => |named| switch (named.data) {
          .void, .space => return PushResult.success,
          .poison => {
            self.poison = true;
            return PushResult.success;
          },
          else => {},
        },
        else => {},
      }
      return PushResult{.invalid_non_void = single};
    }
    if (self.direct) |*direct| {
      if (force_direct) {
        if (
          switch (spec.t) {
            .named => |named| switch (named.data) {
              .textual, .location, .definition, .literal, .every, .record =>
                false,
              .poison => {
                self.poison = true;
                return PushResult.success;
              },
              else => true,
            },
            .structural => |struc| switch (struc.*) {
              .concat, .intersection => false,
              else => true,
            },
          }
        ) {
          return self.errorIfForced(force_direct);
        }
        const new = try self.types.sup(direct.t, spec.t);
        if (new.isNamed(.poison)) return PushResult{.not_compatible = direct.*};
        direct.t = new;
        self.non_voids += 1;
        return PushResult.success;
      } else if (self.types.lesserEqual(spec.t, direct.t)) {
        self.non_voids += 1;
        return PushResult.success;
      } else if (
        !spec.t.isStruc(.sequence) and !spec.t.isNamed(.poison) and
        self.types.greater(spec.t, direct.t)
      ) {
        self.direct = spec;
        self.non_voids += 1;
        return PushResult.success;
      }
    }
    return try self.mergeType(spec, force_direct);
  }

  pub fn finish(
    self: *Self,
    auto: ?model.SpecType,
    generated: ?*model.Type.Sequence,
  ) !BuildResult {
    var res = BuildResult{.t = undefined, .auto = .success};
    const processed_auto = if (auto) |at| switch (at.t) {
      .structural => blk: {
        res.auto = .invalid_inner;
        break :blk null;
      },
      .named => |named| switch (named.data) {
        .record => |*rec| blk: {
          if (self.direct) |direct| {
            if (
              self.types.lesserEqual(at.t, direct.t) or
              self.types.greater(at.t, direct.t)
            ) {
              res.auto = .{.not_disjoint = direct};
              break :blk null;
            }
          }
          for (self.list.items) |item, i| {
            if (item == rec) {
              res.auto = .{
                .not_disjoint = item.typedef().at(self.positions.items[i]),
              };
              break :blk null;
            }
          }
          try self.list.append(self.types.allocator, rec);
          break :blk rec;
        },
        else => blk: {
          res.auto = .invalid_inner;
          break :blk null;
        }
      },
    } else null;

    if (self.force) self.non_voids += 2;
    self.positions.deinit(self.temp_alloc);
    if (self.poison) {
      res.t = self.types.poison();
      return res;
    } else if (self.single) |single| {
      res.t = single.t;
      return res;
    } else switch (self.non_voids) {
      0 => {
        res.t = self.types.void();
        return res;
      },
      1 => {
        res.t = if (self.direct) |direct|
          direct.t else self.list.items[0].typedef();
        return res;
      },
      else => {},
    }

    if (processed_auto) |at| {
      const repr = try self.types.calcSequence(
        if (self.direct) |direct| direct.t else null, self.list.items);
      const ret = if (generated) |gt| gt else blk: {
        const struc = try self.types.allocator.create(model.Type.Structural);
        struc.* = .{.sequence = undefined};
        break :blk &struc.sequence;
      };
      var index = for (repr.structural.sequence.inner) |item, i| {
        if (item == at) break i;
      } else unreachable;
      ret.* = .{
        .direct = if (self.direct) |direct| direct.t else null,
        .inner = repr.structural.sequence.inner,
        .auto = .{
          .index = @intCast(u21, index),
          .repr = &repr.structural.sequence,
        },
      };
      res.t = ret.typedef();
      return res;
    } else {
      if (generated) |gt| {
        try self.types.registerSequence(
          if (self.direct) |direct| direct.t else null, self.list.items, gt);
        res.t = gt.typedef();
        return res;
      } else {
        res.t = try self.types.calcSequence(
          if (self.direct) |direct| direct.t else null, self.list.items);
        return res;
      }
    }
  }
};