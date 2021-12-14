const std = @import("std");
const nyarna = @import("nyarna.zig");
const model = nyarna.model;

/// evaluates expressions and returns values.
pub const Evaluator = struct {
  context: *nyarna.Context,

  pub fn init(context: *nyarna.Context) Evaluator {
    return Evaluator{.context = context};
  }

  fn setupParameterStackFrame(
      self: *Evaluator, sig: *const model.Type.Signature, ns_dependent: bool,
      prev_frame: ?[*]model.StackItem) ![*]model.StackItem {
    const num_params =
      sig.parameters.len + if (ns_dependent) @as(usize, 1) else 0;
    if ((@ptrToInt(self.context.stack_ptr) - @ptrToInt(self.context.stack.ptr))
        / @sizeOf(model.StackItem) + num_params > self.context.stack.len) {
      return nyarna.Error.nyarna_stack_overflow;
    }
    const ret = self.context.stack_ptr;
    self.context.stack_ptr += num_params + 1;
    ret.* = .{.frame_ref = prev_frame};
    return ret;
  }

  fn resetParameterStackFrame(self: *Evaluator, frame_ptr: *?[*]model.StackItem,
                              sig: *const model.Type.Signature) void {
    frame_ptr.* = frame_ptr.*.?[0].frame_ref;
    self.context.stack_ptr -= sig.parameters.len - 1;
  }

  fn fillParameterStackFrame(self: *Evaluator, exprs: []*model.Expression,
                             frame: [*]model.StackItem) !bool {
    var seen_poison = false;
    for (exprs) |expr, i| {
      const val = try self.evaluate(expr);
      frame[i] = .{.value = val};
      if (val.data == .poison) seen_poison = true;
    }
    return !seen_poison;
  }

  fn bindVariables(vars: model.VariableContainer,
                   frame: ?[*]model.StackItem) void {
    if (frame) |base| {
      for (vars) |*v, i| {
        v.cur_value = &base[i];
      }
    } else {
      for (vars) |*v| {
        v.cur_value = null;
      }
    }
  }

  fn RetTypeForCtx(comptime ImplCtx: type) type {
    return switch (ImplCtx) {
      *Evaluator => *model.Value,
      *nyarna.Interpreter => *model.Node,
      else => unreachable
    };
  }

  fn FnTypeForCtx(comptime ImplCtx: type) type {
    return switch (ImplCtx) {
      *Evaluator => nyarna.lib.Provider.BuiltinWrapper,
      *nyarna.Interpreter => nyarna.lib.Provider.KeywordWrapper,
      else => unreachable
    };
  }

  fn registeredFnForCtx(self: *Evaluator, comptime ImplCtx: type, index: usize)
      FnTypeForCtx(ImplCtx) {
    return switch (ImplCtx) {
      *Evaluator => self.context.builtin_registry.items[index],
      *nyarna.Interpreter => self.context.keyword_registry.items[index],
      else => unreachable
    };
  }

  fn poison(impl_ctx: anytype, pos: model.Position)
      nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    switch (@TypeOf(impl_ctx)) {
      *Evaluator => {
        const ret = try impl_ctx.context.storage.allocator.create(model.Value);
        ret.* = .{
          .data = .poison,
          .origin = pos,
        };
        return ret;
      },
      *nyarna.Interpreter => {
        const ret = try impl_ctx.storage.allocator.create(model.Node);
        ret.* = .{
          .pos = pos,
          .data = .poisonNode,
        };
        return ret;
      },
      else => unreachable,
    }
  }

  fn callConstructor(self: *Evaluator, impl_ctx: anytype,
      call: *model.Expression.Call, constr: *const nyarna.types.Constructor)
      nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    const target_impl =
      self.registeredFnForCtx(@TypeOf(impl_ctx), constr.impl_index);
    std.debug.assert(
      call.exprs.len == constr.callable.sig.parameters.len);
    var frame: ?[*]model.StackItem = try self.setupParameterStackFrame(
      constr.callable.sig, false, null);
    defer self.resetParameterStackFrame(&frame, constr.callable.sig);
    return if (try self.fillParameterStackFrame(
        call.exprs, frame.? + 1))
      target_impl(impl_ctx, call.expr().pos, frame.? + 1)
    else poison(impl_ctx, call.expr().pos);
  }

  fn evaluateCall(
      self: *Evaluator, impl_ctx: anytype, call: *model.Expression.Call)
      nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    const target = try self.evaluate(call.target);
    switch (target.data) {
      .funcref => |fr| {
        std.debug.print("evaluateCall => {s}\n", .{fr.func.name});
        switch (fr.func.data) {
          .ext_func => |*ef| {
            const target_impl =
              self.registeredFnForCtx(@TypeOf(impl_ctx), ef.impl_index);
            std.debug.assert(
              call.exprs.len == ef.sig().parameters.len);
            ef.cur_frame = try self.setupParameterStackFrame(
              ef.sig(), ef.ns_dependent, ef.cur_frame);
            var frame_ptr = ef.cur_frame.? + 1;
            var ns_val: model.Value = undefined;
            if (ef.ns_dependent) {
              ns_val = .{
                .data = .{
                  .number = .{
                    .t = undefined, // not accessed, since the wrapper assumes
                                    // that the value adheres to the target
                                    // type's constraints
                    .content = call.ns,
                  },
                },
                .origin = undefined,
              };
              frame_ptr.* = .{
                .value = &ns_val,
              };
              frame_ptr += 1;
            }
            defer self.resetParameterStackFrame(&ef.cur_frame, ef.sig());
            return if (try self.fillParameterStackFrame(
                call.exprs, frame_ptr))
              target_impl(impl_ctx, call.expr().pos, ef.cur_frame.? + 1)
            else poison(impl_ctx, call.expr().pos);
          },
          .ny_func => |*nf| {
            defer bindVariables(nf.variables, nf.cur_frame);
            nf.cur_frame = try self.setupParameterStackFrame(
              nf.sig(), false, nf.cur_frame);
            defer self.resetParameterStackFrame(&nf.cur_frame, nf.sig());
            if (try self.fillParameterStackFrame(
                call.exprs, nf.cur_frame.? + 1)) {
              bindVariables(nf.variables, nf.cur_frame);
              const val = try self.evaluate(nf.body);
              return switch (@TypeOf(impl_ctx)) {
                *Evaluator => val,
                *nyarna.Interpreter => val.data.ast.root,
                else => unreachable,
              };
            } else return poison(impl_ctx, call.expr().pos);
          },
          else => unreachable,
        }
      },
      .@"type" => |tv| {
        const constr = self.context.types.typeConstructor(tv.t);
        return self.callConstructor(impl_ctx, call, constr);
      },
      .prototype => |pv| {
        const constr = self.context.types.prototypeConstructor(pv.pt);
        return self.callConstructor(impl_ctx, call, constr);
      },
      .poison => return switch (@TypeOf(impl_ctx)) {
        *Evaluator => model.Value.create(
          &self.context.storage.allocator, call.expr().pos, .poison),
        *nyarna.Interpreter => model.Node.poison(
          &impl_ctx.storage.allocator,  call.expr().pos),
        else => unreachable,
      },
      else => unreachable
    }
  }

  pub fn evaluateKeywordCall(self: *Evaluator, intpr: *nyarna.Interpreter,
                             call: *model.Expression.Call) !*model.Node {
    return self.evaluateCall(intpr, call);
  }

  pub fn evaluate(self: *Evaluator, expr: *model.Expression)
      nyarna.Error!*model.Value {
    switch (expr.data) {
      .call => |*call| return self.evaluateCall(self, call),
      .assignment => |*assignment| {
        var cur_ptr = &assignment.target.cur_value.?.*.value;
        for (assignment.path) |index| {
          cur_ptr = switch (cur_ptr.*.data) {
            .record => |*record| &record.fields[index],
            .list   => |*list|   &list.content.items[index],
            else => unreachable,
          };
        }
        cur_ptr.* = try self.evaluate(assignment.expr);
        return try model.Value.create(
          &self.context.storage.allocator, expr.pos, .void);
      },
      .access => |*access| {
        var cur = try self.evaluate(access.subject);
        for (access.path) |index| {
          cur = switch (cur.data) {
            .record => |*record| record.fields[index],
            .list   => |*list|   list.content.items[index],
            else    => unreachable,
          };
        }
        return cur;
      },
      .branches => |*branches| {
        var condition = try self.evaluate(branches.condition);
        if (self.context.types.valueType(condition).is(.poison))
          return model.Value.create(
            &self.context.storage.allocator, expr.pos, .poison);
        return self.evaluate(
          branches.branches[condition.data.enumval.index]);
      },
      .concatenation => |concat| {
        var builder = ConcatBuilder.init(
          self.context, expr.pos, expr.expected_type);
        var i: usize = 0;
        while (i < concat.len) : (i += 1) {
          var cur = try self.evaluate(concat[i]);
          if (cur.data == .text and i + 1 < concat.len) {
            i += 1;
            var next = try self.evaluate(concat[i]);
            if (next.data != .text) {
              try builder.push(cur);
              cur = next;
            } else {
              var content_builder = std.ArrayListUnmanaged(u8){};
              try content_builder.appendSlice(
                &self.context.storage.allocator, cur.data.text.content);
              try content_builder.appendSlice(
                &self.context.storage.allocator, next.data.text.content);
              i += 1;
              var last_pos = next.origin;
              while (i < concat.len) : (i += 1) {
                next = try self.evaluate(concat[i]);
                if (next.data != .text) break;
                try content_builder.appendSlice(
                  &self.context.storage.allocator, next.data.text.content);
                last_pos = next.origin;
              }
              const scalar_val = try self.context.storage.allocator.create(
                model.Value);
              scalar_val.* = .{
                .origin = cur.origin.span(last_pos),
                .data = .{
                  .text = .{
                    .t = builder.scalar_type,
                    .content = content_builder.items,
                  },
                },
              };
              try builder.push(scalar_val);
              if (i == concat.len) break;
              cur = next;
            }
          }
          try builder.push(cur);
        }
        return try builder.finish();
      },
      .var_retrieval => |*var_retr| return var_retr.variable.cur_value.?.value,
      .literal => |*literal| return &literal.value,
      .poison => return
        model.Value.create(&self.context.storage.allocator, expr.pos, .poison),
      .void => return
        model.Value.create(&self.context.storage.allocator, expr.pos, .void),
    }
  }
};

const ConcatBuilder = struct {
  cur: ?*model.Value,
  concat_val: ?*model.Value.Concat,
  context: *nyarna.Context,
  pos: model.Position,
  inner_type: model.Type,
  expected_type: model.Type,
  scalar_type: model.Type,

  fn init(context: *nyarna.Context, pos: model.Position,
          expected_type: model.Type) ConcatBuilder {
    return .{
      .cur = null,
      .concat_val = null,
      .context = context,
      .pos = pos,
      .inner_type = model.Type{.intrinsic = .every},
      .expected_type = expected_type,
      .scalar_type =
        nyarna.types.containedScalar(expected_type) orelse undefined,
    };
  }

  fn emptyConcat(self: *ConcatBuilder) !*model.Value.Concat {
    const v = try self.context.storage.allocator.create(model.Value);
    v.* = .{
      .origin = self.pos,
      .data = .{
        .concat = .{
          .t = &self.expected_type.structural.concat,
          .content = std.ArrayList(*model.Value).init(
            &self.context.storage.allocator),
        },
      },
    };
    const cval = &v.data.concat;
    return cval;
  }

  fn concatWith(self: *ConcatBuilder, first_val: *model.Value)
      !*model.Value.Concat {
    const cval = try self.emptyConcat();
    try cval.content.append(first_val);
    return cval;
  }

  fn push(self: *ConcatBuilder, item: *model.Value) !void {
    if (self.cur) |first_val| {
      self.concat_val = try self.concatWith(first_val);
      self.cur = null;
    }
    self.inner_type = try self.context.types.sup(
      self.inner_type, self.context.types.valueType(item));

    if (self.concat_val) |cval| try cval.content.append(item)
    else self.cur = item;
  }

  fn finish(self: *ConcatBuilder) !*model.Value {
    if (self.concat_val) |cval| {
      return cval.value();
    } else if (self.cur) |single| {
      return if (self.expected_type.isStructural(.concat))
        (try self.concatWith(single)).value() else single;
    } else {
      return if (self.expected_type.isStructural(.concat))
        (try self.emptyConcat()).value()
      else if (self.expected_type.is(.void)) try
        model.Value.create(&self.context.storage.allocator, self.pos, .void)
      else blk: {
        std.debug.assert(
          nyarna.types.containedScalar(self.expected_type) != null);
        const scalar_val =
          try self.context.storage.allocator.create(model.Value);
        scalar_val.* = .{
          .origin = self.pos,
          .data = .{
            .text = .{
              .t = self.scalar_type,
              .content = "",
            },
          },
        };
        break :blk scalar_val;
      };
    }
  }
};