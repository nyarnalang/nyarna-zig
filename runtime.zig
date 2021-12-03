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
      self: *Evaluator, sig: *const model.Type.Signature,
      prev_frame: ?[*]model.StackItem) ![*]model.StackItem {
    if ((@ptrToInt(self.context.stack_ptr) - @ptrToInt(self.context.stack.ptr))
        / @sizeOf(model.StackItem) + sig.parameters.len >
        self.context.stack.len) {
      return nyarna.Error.nyarna_stack_overflow;
    }
    const ret = self.context.stack_ptr;
    self.context.stack_ptr += sig.parameters.len + 1;
    ret.* = .{.frame_ref = prev_frame};
    return ret;
  }

  fn resetParameterStackFrame(self: *Evaluator, target: anytype) void {
    target.cur_frame = target.cur_frame.?[0].frame_ref;
    self.context.stack_ptr -= target.sig().parameters.len - 1;
  }

  fn fillParameterStackFrame(self: *Evaluator, exprs: []*model.Expression,
                             frame: [*]model.StackItem) !void {
    for (exprs) |expr, i| {
      frame[i] = .{.value = try self.evaluate(expr)};
    }
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

  fn evaluateCall(
      self: *Evaluator, impl_ctx: anytype, call: *model.Expression.Call)
      nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    const target = try self.evaluate(call.target);
    return switch (target.data) {
      .funcref => |fr| blk: {
        std.debug.print("evaluateCall => {s}\n", .{fr.func.name});
        switch (fr.func.data) {
          .ext_func => |*ef| {
            const target_impl =
              self.registeredFnForCtx(@TypeOf(impl_ctx), ef.impl_index);
            std.debug.assert(
              call.exprs.len == ef.sig().parameters.len);
            ef.cur_frame = try self.setupParameterStackFrame(
              ef.sig(), ef.cur_frame);
            defer self.resetParameterStackFrame(ef);
            try self.fillParameterStackFrame(
              call.exprs, ef.cur_frame.? + 1);
            break :blk target_impl(
              impl_ctx, call.expr().pos, ef.cur_frame.? + 1);
          },
          .ny_func => |*nf| {
            defer bindVariables(nf.variables, nf.cur_frame);
            nf.cur_frame = try self.setupParameterStackFrame(
              nf.sig(), nf.cur_frame);
            defer self.resetParameterStackFrame(nf);
            try self.fillParameterStackFrame(
              call.exprs, nf.cur_frame.? + 1);
            bindVariables(nf.variables, nf.cur_frame);
            const val = try self.evaluate(nf.body);
            break :blk switch (@TypeOf(impl_ctx)) {
              *Evaluator => val,
              *nyarna.Interpreter => val.data.ast.root,
              else => unreachable,
            };
          },
          else => unreachable,
        }
      },
      .typeval => |_| {
        unreachable; // not implemented yet
      },
      .poison => switch (@TypeOf(impl_ctx)) {
        *Evaluator => model.Value.create(
          &self.context.storage.allocator, call.expr().pos, .poison),
        *nyarna.Interpreter => model.Node.poison(
          &impl_ctx.storage.allocator,  call.expr().pos),
        else => unreachable,
      },
      else => unreachable
    };
  }

  pub fn evaluateKeywordCall(self: *Evaluator, intpr: *nyarna.Interpreter,
                             call: *model.Expression.Call) !*model.Node {
    intpr.currently_called_ns = call.ns;
    return self.evaluateCall(intpr, call);
  }

  pub fn evaluate(self: *Evaluator, expr: *model.Expression)
      nyarna.Error!*model.Value {
    return switch (expr.data) {
      .call => |*call| self.evaluateCall(self, call),
      .assignment => |*assignment| blk: {
        var cur_ptr = &assignment.target.cur_value.?.*.value;
        for (assignment.path) |index| {
          cur_ptr = switch (cur_ptr.*.data) {
            .record => |*record| &record.fields[index],
            .list   => |*list|   &list.items.items[index],
            else => unreachable,
          };
        }
        cur_ptr.* = try self.evaluate(assignment.expr);
        break :blk try model.Value.create(
          &self.context.storage.allocator, expr.pos, .void);
      },
      .access => |*access| blk: {
        var cur = try self.evaluate(access.subject);
        for (access.path) |index| {
          cur = switch (cur.data) {
            .record => |*record| record.fields[index],
            .list   => |*list|   list.items.items[index],
            else    => unreachable,
          };
        }
        break :blk cur;
      },
      .branches => |*branches| blk: {
        var condition = try self.evaluate(branches.condition);
        if (self.context.types.valueType(condition).is(.poison))
          break :blk model.Value.create(
            &self.context.storage.allocator, expr.pos, .poison);
        break :blk self.evaluate(
          branches.branches[condition.data.enumval.index]);
      },
      .concatenation => |_| unreachable,
      .var_retrieval => |*var_retr| var_retr.variable.cur_value.?.value,
      .literal => |*literal| &literal.value,
      .poison =>
        model.Value.create(&self.context.storage.allocator, expr.pos, .poison),
      .void =>
        model.Value.create(&self.context.storage.allocator, expr.pos, .void),
    };
  }
};