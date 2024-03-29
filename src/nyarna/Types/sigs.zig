const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model = nyarna.model;
const Types = nyarna.Types;

pub const CallableReprFinder = struct {
  pub const Result = struct {
    found: *?*model.Type.Structural,
    needs_different_repr: bool,
    num_items: usize,
  };
  const Self = @This();

  iter: Types.TreeNode(bool).Iter,
  needs_different_repr: bool,
  count: usize,

  pub fn init(types: *Types) CallableReprFinder {
    return .{
      .iter = .{
        .cur   = &types.prefix_trees.callable,
        .types = types,
      },
      .needs_different_repr = false,
      .count                = 0,
    };
  }

  fn checkParamName(self: *Self, name: []const u8) void {
    if (name.len > 0 and name[0] == 'p') {
      var buf: [16]u8 = undefined;
      const num = std.fmt.bufPrint(&buf, "{}", .{self.count}) catch unreachable;
      if (!std.mem.eql(u8, num, name[1..])) {
        self.needs_different_repr = true;
      }
    } else self.needs_different_repr = true;
  }

  pub fn push(self: *Self, loc: *model.Value.Location) !void {
    self.count += 1;
    try self.iter.descend(loc.spec.t, loc.borrow != null);
    if (loc.default != null or loc.primary != null or loc.varargs != null or
        loc.varmap != null or loc.header != null) {
      self.needs_different_repr = true;
    } else self.checkParamName(loc.name.content);
  }

  pub fn pushType(self: *Self, t: model.Type, name: []const u8) !void {
    self.count += 1;
    try self.iter.descend(t, false);
    self.checkParamName(name);
  }

  pub fn finish(self: *Self, returns: model.Type, is_type: bool) !Result {
    try self.iter.descend(returns, is_type);
    return Result{
      .found                = &self.iter.cur.value,
      .needs_different_repr = self.needs_different_repr,
      .num_items            = self.count,
    };
  }
};

pub const SigBuilderResult = struct {
  /// the built signature
  sig: *model.Signature,
  /// if build_repr has been set in init(), the representative signature
  /// for the type lattice. else null.
  repr: ?*model.Signature,
  /// list of location values that represent this signature's parameters.
  locations: []*model.Value,

  pub fn createCallable(
    self     : @This(),
    allocator: std.mem.Allocator,
    kind     : model.Type.Callable.Kind,
  ) !*model.Type.Callable {
    const strct = try allocator.create(model.Type.Structural);
    errdefer allocator.destroy(strct);
    strct.* = .{
      .callable = .{
        .sig       = self.sig,
        .kind      = kind,
        .repr      = undefined,
        .locations = self.locations,
      },
    };
    strct.callable.repr = if (self.repr) |repr_sig| blk: {
      const repr = try allocator.create(model.Type.Structural);
      errdefer allocator.destroy(repr);
      repr.* = .{
        .callable = .{
          .sig       = repr_sig,
          .kind      = kind,
          .repr      = undefined,
          .locations = self.locations,
        },
      };
      repr.callable.repr = &repr.callable;
      break :blk &repr.callable;
    } else &strct.callable;
    return &strct.callable;
  }
};

pub const SigBuilder = struct {
  const Result = SigBuilderResult;

  val       : *model.Signature,
  repr      : ?*model.Signature,
  ctx       : nyarna.Context,
  locations : []*model.Value,
  next_param: u21,

  const Self = @This();

  /// if returns type is yet to be determined, give .every.
  /// the returns type is given early to know whether this is a keyword.
  ///
  /// if build_repr is true, a second signature will be built to be the
  /// signature of the repr Callable in the type lattice.
  pub fn init(
    ctx       : nyarna.Context,
    num_params: usize,
    returns   : model.Type,
    build_repr: bool,
  ) !Self {
    var ret = Self{
      .val  = try ctx.global().create(model.Signature),
      .repr = if (build_repr) (
          try ctx.global().create(model.Signature)
      ) else null,
      .ctx        = ctx,
      .locations  = try ctx.global().alloc(*model.Value, num_params),
      .next_param = 0,
    };
    ret.val.* = .{
      .parameters =
        try ctx.global().alloc(model.Signature.Parameter, num_params),
      .primary      = null,
      .varmap       = null,
      .auto_swallow = null,
      .returns      = returns,
    };
    if (ret.repr) |sig| {
      sig.* = .{
        .parameters =
          try ctx.global().alloc(model.Signature.Parameter, num_params),
        .primary      = null,
        .varmap       = null,
        .auto_swallow = null,
        .returns      = returns,
      };
    }
    return ret;
  }

  fn addParamLoc(
    self : *Self,
    param: model.Signature.Parameter,
  ) !void {
    const loc = try self.ctx.values.location(
      param.pos, try self.ctx.values.textScalar(
        param.pos, self.ctx.types().system.identifier,
        try self.ctx.global().dupe(u8, param.name)
      ),
      param.spec);
    self.locations[self.next_param] = loc.value();
  }

  pub fn pushUnwrapped(
    self: *Self,
    pos : model.Position,
    name: []const u8,
    spec: model.SpecType,
  ) !void {
    const param = &self.val.parameters[self.next_param];
    param.* = .{
      .pos     = pos,
      .name    = name,
      .spec    = spec,
      .capture = .default,
      .default = null,
      .config  = null,
    };
    try self.addParamLoc(param.*);
    if (self.repr) |sig| {
      const repr_name = try std.fmt.allocPrint(
        self.ctx.global(), "p{}", .{self.next_param + 1});
      sig.parameters[self.next_param] = .{
        .pos     = pos,
        .name    = repr_name,
        .spec    = spec,
        .capture = .default,
        .default = null,
        .config  = null,
      };
    }
    self.next_param += 1;
  }

  pub fn pushParam(
    self : *Self,
    param: model.Signature.Parameter,
  ) !void {
    self.val.parameters[self.next_param] = param;
    try self.addParamLoc(param);
    if (self.repr) |sig| {
      const repr_name = try std.fmt.allocPrint(
        self.ctx.global(), "p{}", .{self.next_param + 1});
      sig.parameters[self.next_param] = .{
        .pos     = param.pos,
        .name    = repr_name,
        .spec    = param.spec,
        .capture = .default,
        .default = null,
        .config  = null,
      };
    }
    self.next_param += 1;
  }

  pub fn push(self: *Self, loc: *model.Value.Location) !void {
    const param = &self.val.parameters[self.next_param];
    param.* = .{
      .pos     = loc.value().origin,
      .name    = loc.name.content,
      .spec    = loc.spec,
      .capture = if (loc.varargs) |_| .varargs else if (loc.borrow) |_|
        @as(@TypeOf(param.capture), .borrow) else .default,
      .default = loc.default,
      .config  = if (loc.header) |bh| bh.config else null,
    };
    self.locations[self.next_param] = loc.value();
    const t: model.Type =
      if (!self.val.isKeyword() and Types.containsAst(loc.spec.t)) blk: {
        self.ctx.logger.AstNodeInNonKeyword(loc.value().origin);
        break :blk self.ctx.types().poison();
      } else loc.spec.t;
    if (loc.primary) |p| {
      if (self.val.primary) |pindex| {
        self.ctx.logger.DuplicateFlag(
          "primary", p, self.val.parameters[pindex].pos);
      } else {
        self.val.primary = self.next_param;
      }
    }
    if (loc.varmap) |v| {
      if (self.val.varmap) |vindex| {
        self.ctx.logger.DuplicateFlag(
          "varmap", v, self.val.parameters[vindex].pos);
      } else {
        self.val.varmap = self.next_param;
      }
    }
    if (loc.header) |bh| {
      if (bh.swallow_depth) |depth| {
        if (self.val.auto_swallow) |as| {
          var buf: [4]u8 = undefined;
          // inlining this into the errorMsg call leads to a compiler bug :)
          const repr = if (as.depth == 0) blk: {
            std.mem.copy(u8, &buf, ":>");
            break :blk @as([]const u8, buf[0..2]);
          } else std.fmt.bufPrint(&buf, ":{}>", .{as.depth})
            catch unreachable;
          self.ctx.logger.DuplicateAutoSwallow(
            repr, bh.value().origin, self.val.parameters[as.param_index].pos);
        } else {
          self.val.auto_swallow = .{
            .depth = depth,
            .param_index = self.next_param
          };
        }
      }
    }
    if (self.repr) |sig| {
      const repr_name = try std.fmt.allocPrint(
        self.ctx.global(), "p{}", .{self.next_param + 1});
      sig.parameters[self.next_param] = .{
        .pos     = loc.value().origin,
        .name    = repr_name,
        .spec    = t.at(loc.spec.pos),
        .capture = .default,
        .default = null,
        .config  = null,
      };
    }
    self.next_param += 1;
  }

  pub fn finish(self: *Self) Result {
    std.debug.assert(self.next_param == self.val.parameters.len);
    return Result{
      .sig       = self.val,
      .repr      = self.repr,
      .locations = self.locations,
    };
  }
};