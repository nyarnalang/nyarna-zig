const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const interpret = @import("interpret.zig");

/// Result of resolving an accessor chain.
pub const Resolution = union(enum) {
  /// chain descends into a runtime value. The base may be either a variable or
  /// an arbitrary expression.
  runtime_chain: struct {
    base: *model.Node,
    /// command character used for the base
    ns: u15,
    /// list of indexes to descend into at runtime.
    indexes: std.ArrayListUnmanaged(usize) = .{},
    /// the current type of the accessed value.
    t: model.Type,
  },
  /// last chain item was resolved to a function.
  func_ref: struct {
    ns: u15,
    target: *model.Function,
    /// set if target is a function reference in the namespace of a type,
    /// which has been accessed via an expression of that type. Such a function
    /// reference must directly be called.
    prefix: ?*model.Node = null,
  },
  /// last chain item was resolved to a type. Value is a pointer into a
  /// model.Symbol.
  type_ref: *model.Type,
  /// last chain item was resolved to a prototype. Value is a pointer into a
  /// model.Symbol.
  proto_ref: *model.Prototype,
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
        var res = try self.resolve(value.subject);
        switch (res) {
          .runtime_chain => |*rc| {
            if (searchField(rc.t, value.id)) |field| {
              try rc.indexes.append(self.intpr.allocator(), field.index);
              rc.t = field.t;
              return res;
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
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .resolved_symref => |*rs| return switch (rs.sym.data) {
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
          .runtime_chain = .{
            .base = chain,
            .ns = rs.ns,
            .t = v.t,
          },
        },
        .poison => Resolution.poison,
      },
      .unresolved_symref => |*usym| {
        if (self.stage.resolve) |r| {
          switch (try r.probeSibling(self.intpr.allocator(), chain)) {
            .variable => |v| {
              chain.data = .{.resolved_symref = .{
                .sym = v.sym(),
                .ns = usym.ns,
              }};
              return Resolution{
                .runtime_chain = .{
                  .base = chain,
                  .ns = usym.ns,
                  .t = v.t,
                },
              };
            },
            .failed => return Resolution.poison,
            else => return Resolution.failed,
              // TODO: support chains for partially resolvable things.
          }
        }
      },
      else => {}
    }
    if (try self.intpr.tryInterpret(chain, self.stage)) |expr| {
      chain.data = .{.expression = expr};
      return Resolution{.runtime_chain = .{
        .base = chain,
        .ns = undefined,
        .t = expr.expected_type,
      }};
    } else return @as(Resolution, if (self.stage.kind != .intermediate)
      .poison else .failed);
  }
};

pub const CallContext = union(enum) {
  known: struct {
    target: *model.Node,
    ns: u15,
    signature: *const model.Type.Signature,
    first_arg: ?*model.Node,
  },
  unknown, poison,

  fn chainIntoCallCtx(intpr: *interpret.Interpreter, target: *model.Node,
                      t: model.Type, ns: u15) !CallContext {
    const callable = switch (t) {
      .structural => |strct| switch (strct.*) {
        .callable => |*callable| callable,
        else => null,
      },
      .intrinsic => |intr| if (intr == .poison) return .poison else null,
      .instantiated => null,
    } orelse {
      intpr.ctx.logger.CantBeCalled(target.pos);
      return .poison;
    };
    return CallContext{
      .known = .{
        .target = target,
        .ns = ns,
        .signature = callable.sig,
        .first_arg = null,
      },
    };
  }

  pub fn fromChain(intpr: *interpret.Interpreter, node: *model.Node,
                   res: Resolution) !CallContext {
    switch (res) {
      .runtime_chain => |rc| {
        const subject = if (rc.indexes.items.len == 0) rc.base
        else (try intpr.node_gen.raccess(
          node.pos, rc.base, rc.indexes.items)).node();
        return try chainIntoCallCtx(intpr, subject, rc.t, rc.ns);
      },
      .func_ref => |fr| {
        const target_expr = try intpr.ctx.createValueExpr(
          (try intpr.ctx.values.funcRef(node.pos, fr.target)).value());
        node.data = .{.expression = target_expr};
        return CallContext{
          .known = .{
            .target = node,
            .ns = fr.ns,
            .signature = fr.target.sig(),
            .first_arg = fr.prefix,
          },
        };
      },
      .type_ref => |tref| {
        const target_expr = try intpr.ctx.createValueExpr(
          (try intpr.ctx.values.@"type"(node.pos, tref.*)).value());
        switch (target_expr.expected_type) {
          .intrinsic => |intr| if (intr == .poison) return CallContext.poison,
          .structural => |strct| switch (strct.*) {
            .callable => |*callable| {
              node.data = .{.expression = target_expr};
              return CallContext{
                .known = .{
                  .target = node,
                  .ns = undefined,
                  .signature = callable.sig,
                  .first_arg = null,
                },
              };
            },
            else => {},
          },
          .instantiated => {},
        }
        intpr.ctx.logger.CantBeCalled(target_expr.pos);
        return CallContext.poison;
      },
      .proto_ref => |pref| {
        const target_expr = try intpr.ctx.createValueExpr(
          (try intpr.ctx.values.prototype(node.pos, pref.*)).value());
        node.data = .{.expression = target_expr};
        return CallContext{
          .known = .{
            .target = node,
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