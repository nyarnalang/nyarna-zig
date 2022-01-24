const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const interpret = @import("interpret.zig");

/// Result of resolving an accessor chain.
pub const Resolution = union(enum) {
  /// chain starts at a variable reference and descends into its fields.
  var_chain: struct {
    /// the target variable that is to be indexed.
    target: struct {
      variable: *model.Symbol.Variable,
      pos: model.Position,
      ns: u15,
    },
    /// chain into the fields of a variable. Each item is the index of a
    /// nested field.
    field_chain: std.ArrayListUnmanaged(usize) = .{},
    t: model.Type,
  },
  /// last chain item was resolved to a function.
  func_ref: struct {
    ns: u15,
    target: *model.Function,
    /// set if target is a function reference in the namespace of a type,
    /// which has been accessed via an expression of that type. Such a function
    /// reference must directly be called.
    prefix: ?*model.Expression = null,
  },
  /// last chain item was resolved to a type. Value is a pointer into a
  /// model.Symbol.
  type_ref: *model.Type,
  /// last chain item was resolved to a prototype. Value is a pointer into a
  /// model.Symbol.
  proto_ref: *model.Prototype,
  /// chain starts at an expression and descends into the returned value.
  expr_chain: struct {
    expr: *model.Expression,
    field_chain: std.ArrayListUnmanaged(usize) = .{},
    t: model.Type,
  },
  /// the resolution failed because an identifier in the chain could not be
  /// resolved – this is not necessarily an error since the chain may be
  /// successfully resolved later.
  failed,
  /// this will be set if the chain is guaranteed to be faulty.
  poison,
};

pub const Resolver = struct {
  const Field = struct {
    index: usize,
    t: model.Type,
  };

  intpr: *interpret.Interpreter,
  stage: interpret.Stage,

  pub fn init(intpr: *interpret.Interpreter, stage: interpret.Stage) Resolver {
    return .{.intpr = intpr, .stage = stage};
  }

  fn searchField(t: model.Type, name: []const u8) ?Field {
    // TODO: search type namespace
    switch (t) {
      .intrinsic, .structural => return null,
      .instantiated => |inst| switch (inst.data) {
        .record => |*rec| {
          for (rec.constructor.sig.parameters) |*field, index| {
            if (std.mem.eql(u8, field.name, name)) {
              return Field{.index = index, .t = field.ptype};
            }
          }
          return null;
        },
        else => return null,
      }
    }
  }

  /// resolves an accessor chain of *model.Node. if stage.kind != .intermediate,
  /// failure to resolve the base symbol will be reported as error and
  /// .poison will be returned; else .failed will be returned.
  pub fn resolve(self: Resolver, chain: *model.Node)
      nyarna.Error!Resolution {
    switch (chain.data) {
      .access => |value| {
        var inner = try self.resolve(value.subject);
        switch (inner) {
          .var_chain => |*vc| {
            if (searchField(vc.t, value.id)) |field| {
              try vc.field_chain.append(self.intpr.allocator(), field.index);
              vc.t = field.t;
              return inner;
            } else if (self.stage.kind != .intermediate) {
              self.intpr.ctx.logger.UnknownField(chain.pos);
              return .poison;
            } else return .failed;
          },
          .func_ref => |ref| {
            if (ref.prefix != null) {
              self.intpr.ctx.logger.PrefixedFunctionMustBeCalled(
                value.subject.pos);
              return .poison;
            }
            // TODO: transform function reference to variable ref, then search
            // in that expression's type for the symbol.
            unreachable;
          },
          .type_ref => |_| {
            // TODO: search in the namespace of the type for the given name.
            unreachable;
          },
          .proto_ref => |_| {
            // TODO: decide whether prototypes have a namespace
            unreachable;
          },
          .expr_chain => |*ec| {
            if (searchField(ec.t, value.id)) |field| {
              try ec.field_chain.append(self.intpr.allocator(), field.index);
              ec.t = field.t;
              return inner;
            } else if (self.stage.kind != .intermediate) {
              self.intpr.ctx.logger.UnknownField(chain.pos);
              return .poison;
            } else return .failed;
          },
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .resolved_symref => |rs| return switch (rs.sym.data) {
        .func => |func| Resolution{
          .func_ref = .{
            .ns = rs.ns,
            .target = func,
            .prefix = null,
          },
        },
        .@"type" => |*t| Resolution{.type_ref = t},
        .prototype => |*pv| Resolution{.proto_ref = pv},
        .variable => |*v| Resolution{
          .var_chain = .{
            .target = .{.variable = v, .pos = chain.pos, .ns = rs.ns},
            .field_chain = .{},
            .t = v.t,
          },
        },
      },
      else =>
        return if (try self.intpr.tryInterpret(chain, self.stage)) |expr|
          Resolution{.expr_chain = .{.expr = expr, .t = expr.expected_type}}
        else @as(Resolution, if (self.stage.kind != .intermediate)
          .poison else .failed),
    }
  }
};

pub const CallContext = union(enum) {
  known: struct {
    target: *model.Expression,
    ns: u15,
    signature: *const model.Type.Signature,
    first_arg: ?*model.Node,
  },
  unknown, poison,

  fn chainIntoExpr(intpr: *interpret.Interpreter, pos: model.Position,
                   start: *model.Expression, t: model.Type, ns: u15,
                   field_chain: []const usize) !CallContext {
    const callable = switch (t) {
      .structural => |strct| switch (strct.*) {
        .callable => |*callable| callable,
        else => null,
      },
      .intrinsic, .instantiated => null,
    } orelse {
      intpr.ctx.logger.CantBeCalled(start.pos);
      return .poison;
    };

    var target_expr = if (field_chain.len > 0) blk: {
      const acc = try intpr.ctx.global().create(model.Expression);
      acc.* = .{
        .pos = pos,
        .data = .{.access = .{.subject = start, .path = field_chain}},
        .expected_type = t,
      };
      break :blk acc;
    } else start;
    return CallContext{
      .known = .{
        .target = target_expr,
        .ns = ns,
        .signature = callable.sig,
        .first_arg = null,
      },
    };
  }

  pub fn fromChain(intpr: *interpret.Interpreter, pos: model.Position,
                   res: Resolution) !CallContext {
    switch (res) {
      .var_chain => |vc| {
        const vr = try intpr.ctx.global().create(model.Expression);
        vr.* = .{
          .pos = vc.target.pos,
          .data = .{.var_retrieval = .{.variable = vc.target.variable}},
          .expected_type = vc.target.variable.t,
        };
        return try chainIntoExpr(
          intpr, pos, vr, vc.t, vc.target.ns, vc.field_chain.items);
      },
      .func_ref => |fr| {
        const target_expr = try intpr.ctx.createValueExpr(
          (try intpr.ctx.values.funcRef(pos, fr.target)).value());
        return CallContext{
          .known = .{
            .target = target_expr,
            .ns = fr.ns,
            .signature = fr.target.sig(),
            .first_arg = if (fr.prefix) |prefix|
              try intpr.node_gen.expression(prefix) else null,
          },
        };
      },
      .expr_chain => |ec| {
        // cannot be a function depending on ns
        return try chainIntoExpr(intpr, pos, ec.expr, ec.t, undefined,
          ec.field_chain.items);
      },
      .type_ref => |_| {
        unreachable; // TODO
      },
      .proto_ref => |pref| {
        const target_expr = try intpr.ctx.createValueExpr(
          (try intpr.ctx.values.prototype(pos, pref.*)).value());
        return CallContext{
          .known = .{
            .target = target_expr,
            .ns = undefined,
            .signature = intpr.ctx.types().prototypeConstructor(
              pref.*).callable.sig,
            .first_arg = null,
          },
        };
      },
      .failed => return .unknown,
      .poison => return .poison,
    }
  }
};