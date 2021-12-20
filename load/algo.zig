const std = @import("std");

const graph = @import("graph.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;

/// A type definition inside a \declare that might not yet be finished.
pub const DeclaredType = struct {
  /// unfinished parts of an inner item of a type that has been constructed
  /// but not finished. the inner item may be an inner type of a
  /// concat/list/optional, or a field of a record.
  const UnfinishedDetails = struct {
    /// index of the item in the type structure
    index: usize,
    /// unresolved node describing the type, if any
    item_type: ?*model.Node,
    /// unresolved node describing the default expression of a field, if any.
    default_expr: ?*model.Node,
  };

  name: []const u8,
  value: model.Type,
  /// list of unresolved inner parts of the type.
  details: []UnfinishedDetails,
};

// A func definition inside a \declare that might not yet be finished.
const DeclaredFunction = struct {
  name: []const u8,
  callable: *model.Type.Callable,
  variables: model.VariableContainer,
  body: *model.Node,
  /// the currently calculated return type during fixpoint iteration
  cur_returns: model.Type,
  /// true iff the return type has been explicitly set by the user.
  explicit_returns: bool,
};

const DeclaredItem = union {
  declared_type: DeclaredType,
  declared_function: DeclaredFunction,
  finished_sym: *model.Symbol,
};

const DeclaredItems = struct {
  items: []DeclaredItem,
  root: ?u21,
};

const TypeResolution = struct {
  context: graph.ResolutionContext,
  data: *DeclaredItems,
  intpr: *nyarna.Interpreter,
  filling: bool,

  fn init(data: *DeclaredItems) TypeResolution {
    return .{
      .context = .{
        .resolveInSiblingDefinitions = resolveSibling,
      },
      .data = data,
    };
  }

  fn length(self: *TypeResolution) usize {
    return self.data.items.len;
  }

  fn swap(self: *TypeResolution, left: usize, right: usize) void {
    const tmp = self.data.items[left];
    self.data.items[left] = self.data.items[right];
    self.data.items[right] = tmp;
  }

  fn resolveSibling(ctx: *graph.ResolutionContext, item: *model.Node)
      std.mem.Allocator.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(TypeResolution, "context", ctx);
    switch (item.data) {
      .unresolved_symref => |*ur| {
        for (self.data.items) |*decl, index| {
          if (std.mem.eql(u8, decl.name, ur.name)) {
            if (self.filling) switch (decl) {
              .finished_sym => |sym| {
                item.data = .{
                  .resolved_symref = sym,
                };
                return graph.ResolutionContext.Result{.resolved};
              },
              .declared_type => |*dt| {
                item.data = .{
                  .expression = try self.intpr.genPublicLiteral(
                    item.pos, .{
                      .@"type" = .{.t = dt.value},
                    }),
                };
                return graph.ResolutionContext.Result{.unfinished_type};
              },
              .declared_function => |*df|
                return graph.ResolutionContext.Result{
                    .preliminary_type = df.cur_returns}
            } else return graph.ResolutionContext.Result{.known = index};
          }
        }
      },
      .unresolved_call => |_| {
        unreachable; // TODO
      }
    }
    return graph.ResolutionContext.Result{.failed};
  }
};

fn callTarget(def: *model.Value.Definition) ?*model.Symbol.ExtFunc {
  switch (def.content.root.data) {
    .resolved_call => |*rc| switch (rc.target.data) {
      .literal => |*lit| switch (lit.value.data) {
        .funcref => |fr| switch (fr.func.data) {
          .ext_func => |*ef| return ef,
        },
      },
    },
  }
  return null;
}

fn isPrototype(ef: *model.Symbol.ExtFunc) bool {
  return ef.callable.kind == .prototype;
}

pub const DeclareResolution = struct {
  const Processor = graph.GraphProcessor(*DeclareResolution);

  defs: []*model.Value.Definition,
  processor: Processor,
  dep_discovery_ctx: graph.ResolutionContext,
  intpr: *nyarna.Interpreter,

  pub fn create(intpr: *nyarna.Interpreter,
                defs: []*model.Value.Definition,
                ns: u15) !*DeclareResolution {
    var res = try intpr.storage.allocator.create(DeclareResolution);
    res.defs = defs;
    res.processor = try Processor.init(&intpr.storage.allocator, res);
    res.dep_discovery_ctx = .{
      .resolveInSiblingDefinitions = discoverDependencies,
      .ns = ns,
    };
    res.intpr = intpr;
    return res;
  }

  fn pregenType(_: *DeclareResolution,
                _: *model.Node.ResolvedCall) ?model.Type {
    unreachable; // TODO
  }

  fn genTypeArgs(_: *DeclareResolution,
                 _: *model.Node.ResolvedCall,
                 _: []*model.Value.Definition) void {
    unreachable; // TODO
  }

  pub fn execute(self: *DeclareResolution) !void {
    try self.processor.firstStep();
    try self.processor.secondStep(&self.intpr.storage.allocator);
    // third step: process components in reverse topological order.

    for (self.processor.components) |first_index, cmpt_index| {
      const num_nodes = if (cmpt_index == self.processor.components.len - 1)
        self.defs.len - first_index
      else
        self.processor.components[cmpt_index + 1] - first_index;
      const defs = self.defs[first_index..first_index+num_nodes];

      // first, allocate all types and create their symbols. This allows
      // referring to them even when not all information (record field types,
      // inner types, default expressions) has been resolved.
      for (defs) |def| {
        switch (def.content.root.data) {
          .resolved_call => |*rcall| {
            const t = self.pregenType(rcall) orelse continue;
            const sym = try self.intpr.createPublic(model.Symbol);
            sym.* = .{
              .defined_at = def.name.value().origin,
              .name = def.name.content,
              .data = .{
                .@"type" = t,
              },
            };
            // TODO: add sym to node
          },
          else => {}
        }
      }

      // now, resolve all references in the prototype calls' arguments.
      // only nodes defining default values may be unresolvable, and only if
      // the type for the location for which the default value cannot be
      // resolved is explicitly given.
      for (defs) |def| {
        switch (def.content.root.data) {
          .resolved_call => |*rcall| {
            self.genTypeArgs(rcall, defs);
          },
          else => {},
        }
      }
    }
  }

  //----------------
  // graph interface
  //----------------

  pub fn length(self: *const DeclareResolution) usize {
    return self.defs.len;
  }

  pub fn collectDeps(self: *DeclareResolution, index: usize,
                     edges: *[]usize) !void {
    self.dep_discovery_ctx.dependencies = .{};
    _ = try self.intpr.probeType(
      self.defs[index].content.root, &self.dep_discovery_ctx);
    edges.* = self.dep_discovery_ctx.dependencies.items;
  }

  pub fn swap(self: *DeclareResolution, x: usize, y: usize) void {
    const tmp = self.defs[x];
    self.defs[x] = self.defs[y];
    self.defs[y] = tmp;
  }

  //----------------------------
  // ResolutionContext interface
  //----------------------------

  fn discoverDependencies(
      ctx: *graph.ResolutionContext, item: *model.Node)
      nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(DeclareResolution, "dep_discovery_ctx", ctx);
    switch (item.data) {
      .unresolved_symref => |*ur| {
        for (self.defs) |def, i| if (std.mem.eql(u8, def.name.content, ur.name))
          return graph.ResolutionContext.Result{.known = @intCast(u21, i)};
        return graph.ResolutionContext.Result.failed;
      },
      .unresolved_call => |*uc| {
        _ = try self.intpr.probeType(uc.target, &self.dep_discovery_ctx);
        for (uc.proto_args) |*arg|
          _ = try self.intpr.probeType(arg.content, ctx);
        return graph.ResolutionContext.Result{.known = null};
      },
      else => unreachable,
    }
  }

};