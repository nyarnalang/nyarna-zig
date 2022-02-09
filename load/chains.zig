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
  /// last chain item was resolved to a symbol.
  sym_ref: struct {
    ns: u15,
    sym: *model.Symbol,
    /// set if target symbol is declare in the namespace of a type and has been
    /// accessed via an expression of that type. Such a reference must directly
    /// be called.
    prefix: ?*model.Node = null,
  },
  /// the resolution failed because an identifier in the chain could not be
  /// resolved – this is not necessarily an error since the chain may be
  /// successfully resolved later.
  failed,
  /// this will be set if the chain is guaranteed to be faulty.
  poison,
};

pub const Resolver = struct {
  const SearchResult = union(enum) {
    field: struct {
      index: usize,
      t: model.Type,
    },
    symbol: *model.Symbol,
  };


  intpr: *interpret.Interpreter,
  stage: interpret.Stage,

  pub fn init(intpr: *interpret.Interpreter, stage: interpret.Stage) Resolver {
    return .{.intpr = intpr, .stage = stage};
  }

  fn searchAccessible(intpr: *interpret.Interpreter, t: model.Type,
                      name: []const u8) ?SearchResult {
    switch (t) {
      .intrinsic, .structural => {},
      .instantiated => |inst| switch (inst.data) {
        .record => |*rec| {
          for (rec.constructor.sig.parameters) |*field, index| {
            if (std.mem.eql(u8, field.name, name)) {
              return SearchResult{.field = .{.index = index, .t = field.ptype}};
            }
          }
        },
        else => {},
      }
    }
    if (intpr.type_namespaces.get(t)) |ns| {
      if (ns.data.get(name)) |sym| return SearchResult{.symbol = sym};
    }
    return null;
  }

  /// resolves an accessor chain of *model.Node. if stage.kind != .intermediate,
  /// failure to resolve the base symbol will be reported as error and
  /// .poison will be returned; else .failed will be returned.
  pub fn resolve(self: Resolver, chain: *model.Node)
      nyarna.Error!Resolution {
    switch (chain.data) {
      .resolved_symref => |*rs| {
        return if (rs.sym.data == .poison) Resolution.poison
        else Resolution{.sym_ref = .{
          .ns = rs.ns,
          .sym = rs.sym,
          .prefix = null,
        }};
      },
      .unresolved_access => |value| {
        var res = try self.resolve(value.subject);
        switch (res) {
          .runtime_chain => |*rc| {
            if (searchAccessible(
                self.intpr, rc.t, value.id)) |sr| switch (sr) {
              .field => |field| {
                try rc.indexes.append(self.intpr.allocator, field.index);
                rc.t = field.t;
                return res;
              },
              .symbol => |sym| {
                if (sym.data == .poison) return Resolution.poison;
                const subject = if (rc.indexes.items.len == 0) rc.base
                  else (try self.intpr.node_gen.raccess(
                    chain.pos, rc.base, rc.indexes.items)).node();
                return Resolution{.sym_ref = .{
                  .ns = rc.ns,
                  .sym = sym,
                  .prefix = subject,
                }};
              },
            } else if (self.stage.kind != .intermediate and
                       self.stage.kind != .resolve) {
              // in .resolve stage there may still be unresolved accesses to
              // the current type's namespace, so we don't poison in that case
              // yet.
              self.intpr.ctx.logger.UnknownSymbol(chain.pos);
              return .poison;
            } else return .failed;
          },
          .sym_ref => |ref| {
            if (ref.prefix != null) {
              self.intpr.ctx.logger.PrefixedSymbolMustBeCalled(
                value.subject.pos);
              return .poison;
            }
            switch (ref.sym.data) {
              .func => |func| {
                const target = searchAccessible(
                  self.intpr, func.callable.typedef(), value.id) orelse
                    if (self.stage.kind == .keyword or
                        self.stage.kind == .final) {
                      self.intpr.ctx.logger.UnknownSymbol(chain.pos);
                      return .poison;
                    } else return .failed;
                switch (target) {
                  .field => unreachable, // TODO: do functions have fields?
                  .symbol => |sym| {
                    if (sym.data == .poison) return .poison;
                    return Resolution{.sym_ref = .{
                      .ns = ref.ns,
                      .sym = sym,
                      .prefix = value.subject,
                    }};
                  },
                }
              },
              .@"type" => |t| {
                const target = searchAccessible(self.intpr, t, value.id) orelse
                  if (self.stage.kind == .keyword or self.stage.kind == .final)
                  {
                    self.intpr.ctx.logger.UnknownSymbol(chain.pos);
                    return .poison;
                  } else return .failed;

                switch (target) {
                  .field => {
                    self.intpr.ctx.logger.FieldAccessWithoutInstance(chain.pos);
                    return .poison;
                  },
                  .symbol => |sym| {
                    if (sym.data == .poison) return .poison;
                    return Resolution{.sym_ref = .{
                      .ns = ref.ns,
                      .sym = sym,
                      .prefix = null,
                    }};
                  },
                }
              },
              // TODO: could we get a prototype here?
              .variable, .poison, .prototype => unreachable,
            }
          },
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .unresolved_symref => |*usym| {
        if (self.stage.resolve) |r| {
          switch (try r.probeSibling(self.intpr.allocator, chain)) {
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
      .sym_ref => |*sr| {
        switch (sr.sym.data) {
          .func => |func| {
            const target_expr = try intpr.ctx.createValueExpr(
              (try intpr.ctx.values.funcRef(node.pos, func)).value());
            node.data = .{.expression = target_expr};
            return CallContext{
              .known = .{
                .target = node,
                .ns = sr.ns,
                .signature = func.sig(),
                .first_arg = sr.prefix,
              },
            };
          },
          .@"type" => |t| {
            const target_expr = try intpr.ctx.createValueExpr(
              (try intpr.ctx.values.@"type"(node.pos, t)).value());
            switch (target_expr.expected_type) {
              .intrinsic => |intr| if (intr == .poison) return .poison,
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
          .prototype => |pt| {
            const target_expr = try intpr.ctx.createValueExpr(
              (try intpr.ctx.values.prototype(node.pos, pt)).value());
            node.data = .{.expression = target_expr};
            return CallContext{
              .known = .{
                .target = node,
                .ns = undefined,
                .signature = intpr.ctx.types().prototypeConstructor(
                  pt).callable.sig,
                .first_arg = null,
              },
            };
          },
          .poison, .variable => unreachable,
        }
      },
      .failed => return .unknown,
      .poison => return .poison,
    }
  }
};