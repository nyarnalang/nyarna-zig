const std = @import("std");
const nyarna = @import("nyarna.zig");
const model = nyarna.model;
const Interpreter = @import("load/interpret.zig").Interpreter;

/// evaluates expressions and returns values.
pub const Evaluator = struct {
  ctx: nyarna.Context,
  // current type that is being called. used by type constructors that need to
  // behave depending on the target type
  target_type: model.Type = undefined,

  fn setupParameterStackFrame(
      self: *Evaluator, sig: *const model.Type.Signature, ns_dependent: bool,
      prev_frame: ?[*]model.StackItem) ![*]model.StackItem {
    const data = self.ctx.data;
    const num_params =
      sig.parameters.len + if (ns_dependent) @as(usize, 1) else 0;
    if ((@ptrToInt(data.stack_ptr) - @ptrToInt(data.stack.ptr))
        / @sizeOf(model.StackItem) + num_params > data.stack.len) {
      return nyarna.Error.nyarna_stack_overflow;
    }
    const ret = data.stack_ptr;
    data.stack_ptr += num_params + 1;
    ret.* = .{.frame_ref = prev_frame};
    return ret;
  }

  fn resetParameterStackFrame(self: *Evaluator, frame_ptr: *?[*]model.StackItem,
                              sig: *const model.Type.Signature) void {
    frame_ptr.* = frame_ptr.*.?[0].frame_ref;
    self.ctx.data.stack_ptr -= sig.parameters.len - 1;
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
      for (vars) |v, i| {
        v.cur_value = &base[i];
      }
    } else {
      for (vars) |v| {
        v.cur_value = null;
      }
    }
  }

  fn RetTypeForCtx(comptime ImplCtx: type) type {
    return switch (ImplCtx) {
      *Evaluator => *model.Value,
      *Interpreter => *model.Node,
      else => unreachable
    };
  }

  fn FnTypeForCtx(comptime ImplCtx: type) type {
    return switch (ImplCtx) {
      *Evaluator => nyarna.lib.Provider.BuiltinWrapper,
      *Interpreter => nyarna.lib.Provider.KeywordWrapper,
      else => unreachable
    };
  }

  fn registeredFnForCtx(self: *Evaluator, comptime ImplCtx: type, index: usize)
      FnTypeForCtx(ImplCtx) {
    return switch (ImplCtx) {
      *Evaluator => self.ctx.data.builtin_registry.items[index],
      *Interpreter => self.ctx.data.keyword_registry.items[index],
      else => unreachable
    };
  }

  fn poison(impl_ctx: anytype, pos: model.Position)
      nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    switch (@TypeOf(impl_ctx)) {
      *Evaluator => return try impl_ctx.ctx.values.poison(pos),
      *Interpreter => return impl_ctx.node_gen.poison(pos),
      else => unreachable,
    }
  }

  fn callConstructor(self: *Evaluator, impl_ctx: anytype,
      call: *model.Expression.Call, constr: nyarna.types.Constructor)
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
          .ext => |*ef| {
            const target_impl =
              self.registeredFnForCtx(@TypeOf(impl_ctx), ef.impl_index);
            std.debug.assert(
              call.exprs.len == fr.func.sig().parameters.len);
            fr.func.cur_frame = try self.setupParameterStackFrame(
              fr.func.sig(), ef.ns_dependent, fr.func.cur_frame);
            var frame_ptr = fr.func.cur_frame.? + 1;
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
            defer self.resetParameterStackFrame(
              &fr.func.cur_frame, fr.func.sig());
            return if (try self.fillParameterStackFrame(
                call.exprs, frame_ptr))
              target_impl(impl_ctx, call.expr().pos, fr.func.cur_frame.? + 1)
            else poison(impl_ctx, call.expr().pos);
          },
          .ny => |*nf| {
            defer bindVariables(nf.variables, fr.func.cur_frame);
            fr.func.cur_frame = try self.setupParameterStackFrame(
              fr.func.sig(), false, fr.func.cur_frame);
            defer self.resetParameterStackFrame(
              &fr.func.cur_frame, fr.func.sig());
            if (try self.fillParameterStackFrame(
                call.exprs, fr.func.cur_frame.? + 1)) {
              bindVariables(nf.variables, fr.func.cur_frame);
              const val = try self.evaluate(nf.body);
              return switch (@TypeOf(impl_ctx)) {
                *Evaluator => val,
                *Interpreter => val.data.ast.root,
                else => unreachable,
              };
            } else return poison(impl_ctx, call.expr().pos);
          },
        }
      },
      .@"type" => |tv| {
        const constr = self.ctx.types().typeConstructor(tv.t);
        self.target_type = tv.t;
        return self.callConstructor(impl_ctx, call, constr);
      },
      .prototype => |pv| {
        const constr = self.ctx.types().prototypeConstructor(pv.pt);
        return self.callConstructor(impl_ctx, call, constr);
      },
      .poison => return switch (@TypeOf(impl_ctx)) {
        *Evaluator => self.ctx.values.poison(call.expr().pos),
        *Interpreter => impl_ctx.node_gen.poison(call.expr().pos),
        else => unreachable,
      },
      else => unreachable
    }
  }

  pub fn evaluateKeywordCall(self: *Evaluator, intpr: *Interpreter,
                             call: *model.Expression.Call) !*model.Node {
    return self.evaluateCall(intpr, call);
  }

  /// actual evaluation of expressions.
  fn doEvaluate(self: *Evaluator, expr: *model.Expression)
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
          self.ctx.global(), expr.pos, .void);
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
        if (self.ctx.types().valueType(condition).is(.poison))
          return model.Value.create(
            self.ctx.global(), expr.pos, .poison);
        return self.evaluate(
          branches.branches[condition.data.@"enum".index]);
      },
      .concatenation => |concat| {
        var builder = ConcatBuilder.init(
          self.ctx, expr.pos, expr.expected_type);
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
                self.ctx.global(), cur.data.text.content);
              try content_builder.appendSlice(
                self.ctx.global(), next.data.text.content);
              i += 1;
              var last_pos = next.origin;
              while (i < concat.len) : (i += 1) {
                next = try self.evaluate(concat[i]);
                if (next.data != .text) break;
                try content_builder.appendSlice(
                  self.ctx.global(), next.data.text.content);
                last_pos = next.origin;
              }
              const scalar_val = try self.ctx.values.textScalar(
                cur.origin.span(last_pos), builder.scalar_type,
                content_builder.items);
              try builder.push(scalar_val.value());
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
      .poison => return self.ctx.values.poison(expr.pos),
      .void => return self.ctx.values.void(expr.pos),
    }
  }

  inline fn toString(self: *Evaluator, input: anytype) ![]u8 {
    return std.fmt.allocPrint(self.ctx.global(), "{}", .{input});
  }

  fn coerce(self: *Evaluator, value: *model.Value, expected_type: model.Type)
      std.mem.Allocator.Error!*model.Value {
    const value_type = self.ctx.types().valueType(value);
    if (value_type.eql(expected_type)) return value;
    switch (expected_type) {
      .intrinsic => |intr| switch (intr) {
        .poison => return value,
        // for .literal, this can only be a coercion from .space.
        // for .raw, this could be a coercion from any scalar type.
        .literal, .raw => {
          const content = switch (value.data) {
            .text => |*text_val| text_val.content,
            .number => |*num_val| try self.toString(num_val.content),
            .float => |*float_val| try switch (float_val.t.precision) {
              .half => self.toString(float_val.content.half),
              .single => self.toString(float_val.content.single),
              .double => self.toString(float_val.content.double),
              .quadruple, .octuple =>
                self.toString(float_val.content.quadruple),
            },
            .@"enum" => |ev| ev.t.values.entries.items(.key)[ev.index],
            // type checking ensures this never happens
            else => unreachable,
          };
          return model.Value.create(
            self.ctx.global(), value.origin,
            model.Value.TextScalar{.t = expected_type, .content = content});
        },
        // other coercions can never happen.
        else => {
          const v =
            std.fmt.Formatter(nyarna.errors.formatType){.data = value_type};
          const e =
            std.fmt.Formatter(nyarna.errors.formatType){.data = expected_type};
          std.debug.panic("coercion from {} to {} requested, which is illegal",
            .{v, e});
        }
      },
      // TODO: implement enums being coerced to Identifier.
      .instantiated => unreachable,
      .structural => |strct| switch (strct.*) {
        // these are virtual types and thus can never be the expected type.
        .optional, .intersection => unreachable,
        .concat => |*concat| {
          var cv = try self.ctx.values.concat(value.origin, concat);
          if (!value_type.is(.void)) {
            const inner_value = try self.coerce(value, concat.inner);
            try cv.content.append(inner_value);
          }
          return cv.value();
        },
        .paragraphs => |*para| {
          var lv = try self.ctx.values.para(value.origin, para);
          if (!value_type.is(.void)) {
            const para_value = for (para.inner) |cur| {
              if (self.ctx.types().lesserEqual(value_type, cur))
                break try self.coerce(value, cur);
            } else unreachable;
            try lv.content.append(para_value);
          }
          return lv.value();
        },
        .list, .map => unreachable, // TODO: implement coercion of inner values.
        .callable => unreachable, // TODO: implement callable wrapper.
      }
    }
  }

  /// evaluate the expression, and coerce the resulting value according to the
  /// expression's expected type [8.3].
  pub fn evaluate(self: *Evaluator, expr: *model.Expression)
      nyarna.Error!*model.Value {
    const res = try self.doEvaluate(expr);
    const expected_type = self.ctx.types().expectedType(
      self.ctx.types().valueType(res), expr.expected_type);
    return try self.coerce(res, expected_type);
  }
};

const ConcatBuilder = struct {
  cur: ?*model.Value,
  concat_val: ?*model.Value.Concat,
  ctx: nyarna.Context,
  pos: model.Position,
  inner_type: model.Type,
  expected_type: model.Type,
  scalar_type: model.Type,

  fn init(ctx: nyarna.Context, pos: model.Position,
          expected_type: model.Type) ConcatBuilder {
    return .{
      .cur = null,
      .concat_val = null,
      .ctx = ctx,
      .pos = pos,
      .inner_type = model.Type{.intrinsic = .every},
      .expected_type = expected_type,
      .scalar_type =
        nyarna.types.containedScalar(expected_type) orelse undefined,
    };
  }

  fn emptyConcat(self: *ConcatBuilder) !*model.Value.Concat {
    return self.ctx.values.concat(
      self.pos, &self.expected_type.structural.concat);
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
    self.inner_type = try self.ctx.types().sup(
      self.inner_type, self.ctx.types().valueType(item));

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
        model.Value.create(self.ctx.global(), self.pos, .void)
      else blk: {
        std.debug.assert(
          nyarna.types.containedScalar(self.expected_type) != null);
        break :blk (try self.ctx.values.textScalar(
          self.pos, self.scalar_type, "")).value();
      };
    }
  }
};