const std = @import("std");

const nyarna           = @import("../../nyarna.zig");
const SigBuilderResult = @import("sigs.zig").SigBuilderResult;

const model  = nyarna.model;
const Types  = nyarna.Types;

const stringOrder = @import("../helpers.zig").stringOrder;

/// PrototypeFuncs contains function definitions belonging to a prototype.
/// Those functions are to be named for each instance of that prototype.
///
/// The functions are named lazily to avoid lots of superfluous
/// instantiations for every instance of e.g. Concat (which are often implicitly
/// created). This type holds the function definitions and implements this
/// instantiation.
pub const PrototypeFuncs = struct {
  pub const Item = struct {
    name: *model.Value.TextScalar,
    /// each parameter is an expression that will evaluate to a location value.
    /// the parameters may reference the prototype's variables, defined below.
    params: []*model.Expression,
    /// expression that returns a type, may reference prototype variables.
    returns: *model.Expression,
    impl_index: usize,
  };
  constructor: ?struct {
    params: []*model.Expression,
    impl_index: usize,
  } = null,
  defs: []Item = &.{},
  /// used by the variables referencing an instance's arguments. Must be filled
  /// when instantiating a prototype func. the first variable will be \This, the
  /// reference to the named type.
  var_container: *model.VariableContainer = undefined,

  fn lessThan(
    context: u0,
    lhs: Item,
    rhs: Item,
  ) bool {
    _ = context;
    return stringOrder(lhs.name.content, rhs.name.content) == .lt;
  }

  /// given list will be consumed.
  pub fn set(self: *PrototypeFuncs, defs: []Item) void {
    std.sort.sort(Item, defs, @as(u0, 0), lessThan);
    self.defs = defs;
  }

  fn find(self: *PrototypeFuncs, name: []const u8) ?usize {
    var defs = self.defs;
    var offset: usize = 0;
    while (defs.len > 0) {
      const i = @divTrunc(defs.len, 2);
      const def = defs[i];
      switch (stringOrder(name, def.name.content)) {
        .lt => defs = defs[0..i],
        .eq => return offset + i,
        .gt => {
          defs = defs[i+1..];
          offset += i+1;
        },
      }
    } else return null;
  }
};

pub const InstanceFuncs = struct {
  pt  : *PrototypeFuncs,
  syms: []?*model.Symbol,
  /// arguments of the instantiation. The first argument is always the resulting
  /// type, then come the user-supplied arguments to the Prototype call.
  arguments  : []*model.Value.TypeVal,
  constructor: ?*model.Type.Callable,

  pub fn create(
    pt       : *PrototypeFuncs,
    allocator: std.mem.Allocator,
    arguments: []*model.Value.TypeVal,
  ) !*InstanceFuncs {
    var ret = try allocator.create(InstanceFuncs);
    errdefer allocator.destroy(ret);
    ret.* = .{
      .pt          = pt,
      .syms        = try allocator.alloc(?*model.Symbol, pt.defs.len),
      .arguments   = arguments,
      .constructor = null,
    };
    std.mem.set(?*model.Symbol, ret.syms, null);
    return ret;
  }

  fn buildCallableRes(comptime ret_t: type) type {
    return if (ret_t == *model.Expression) ?SigBuilderResult
    else SigBuilderResult;
  }

  fn buildCallable(
    self  : *InstanceFuncs,
    ctx   : nyarna.Context,
    params: []*model.Expression,
    ret   : anytype,
  ) !buildCallableRes(@TypeOf(ret)) {
    // fill variable container with argument values.
    var eval = ctx.evaluator();
    self.pt.var_container.cur_frame = try eval.allocateStackFrame(
      self.pt.var_container.num_values, self.pt.var_container.cur_frame);
    const frame = self.pt.var_container.cur_frame.? + 1;
    defer eval.resetStackFrame(
      &self.pt.var_container.cur_frame, self.pt.var_container.num_values, false
    );
    for (self.arguments) |arg, i| frame[i] = .{.value = arg.value()};

    const ret_type = if (@TypeOf(ret) == *model.Expression) switch (
      (try eval.evaluate(ret)).data
    ) {
      .@"type" => |tv| tv.t,
      .poison  => return null,
      else     => unreachable,
    } else ret;

    // since this is language defined, we can be sure no func has more than 10
    // args.
    var locs: [10]?*model.Value.Location = undefined;

    var finder = Types.CallableReprFinder.init(ctx.types());
    for (params) |param, i| switch ((try eval.evaluate(param)).data) {
      .location => |*loc| {
        try finder.push(loc);
        locs[i] = loc;
      },
      .poison   => locs[i] = null,
      else      => unreachable,
    };

    const finder_res = try finder.finish(ret_type, false);
    var builder = try Types.SigBuilder.init(
      ctx, params.len, ret_type, finder_res.needs_different_repr
    );
    for (params) |_, i| if (locs[i]) |loc| try builder.push(loc);
    return builder.finish();
  }

  pub fn find(
    self: *InstanceFuncs,
    ctx : nyarna.Context,
    name: []const u8,
  ) !?*model.Symbol {
    const index = self.pt.find(name) orelse return null;
    if (self.syms[index]) |sym| return sym;
    const def = self.pt.defs[index];

    const sym = try ctx.global().create(model.Symbol);
    sym.* = .{
      .defined_at  = def.name.value().origin,
      .name        = def.name.content,
      .data        = undefined,
      .parent_type = self.arguments[0].t,
    };

    const builder_res = (
      try self.buildCallable(ctx, def.params, def.returns)
    ) orelse {
      sym.data = .poison;
      self.syms[index] = sym;
      return sym;
    };

    const container = try ctx.global().create(model.VariableContainer);
    container.* =
      .{.num_values = @intCast(u15, builder_res.sig.parameters.len)};
    const func = try ctx.global().create(model.Function);
    func.* = .{
      .callable   = try builder_res.createCallable(ctx.global(), .function),
      .defined_at = def.name.value().origin,
      .data = .{.ext = .{
        .ns_dependent = false,
        .impl_index   = def.impl_index,
      }},
      .name = sym,
      .variables = container,
    };
    sym.data = .{.func = func};
    self.syms[index] = sym;
    return sym;
  }

  pub fn genConstructor(
    self: *InstanceFuncs,
    ctx : nyarna.Context,
  ) !void {
    if (self.constructor != null) return;
    if (self.pt.constructor) |constr| {
      ctx.types().instantiating_instance_funcs = true;
      defer ctx.types().instantiating_instance_funcs = false;

      const builder_res = try self.buildCallable(
        ctx, constr.params, self.arguments[0].t);
      const callable = try builder_res.createCallable(ctx.global(), .@"type");
      self.constructor = callable;
    }
  }
};