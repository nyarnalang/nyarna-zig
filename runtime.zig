const std = @import("std");
const nyarna = @import("nyarna.zig");
const data = nyarna.data;

pub const Errors = error {
  nyarna_stack_overflow
};

/// evaluates expressions and returns values.
pub const Evaluator = struct {
  context: *nyarna.Context,

  pub fn init(context: *nyarna.Context) Evaluator {
    return Evaluator{.context = context};
  }

  fn setupParameterStackFrame(
      self: *Evaluator, sig: *data.Type.Signature,
      prev_frame: ?[*]data.StackItem) ![*]data.StackItem {
    if (self.context.stack_ptr + sig.parameters.len - self.context.stack.ptr >
        self.context.stack.len) {
      return Errors.nyarna_stack_overflow;
    }
    const ret = self.context.stack_ptr;
    self.context.stack_ptr += sig.parameters.len + 1;
    ret.*.frame_ref = prev_frame;
    return ret;
  }

  fn resetParameterStackFrame(self: *Evaluator, target: anytype) void {
    target.cur_frame = target.cur_frame.?.frame_ref;
    self.context.stack_ptr -= target.signature.parameters.len - 1;
  }

  fn fillParameterStackFrame(self: *Evaluator, exprs: []*data.Expression,
                             frame: [*]data.StackItem) !void {
    for (exprs) |expr, i| {
      frame[i].value = try self.evaluate(expr);
    }
  }

  fn bindVariables(vars: *data.VariableContainer,
                   frame: ?[*]data.StackItem) void {
    if (frame) |base| {
      for (vars) |*v, i| {
        v.cur_value = base + i;
      }
    } else {
      for (vars) |*v| {
        v.cur_value = null;
      }
    }
  }

  pub fn evaluate(self: *Evaluator, expr: *data.Expression) !*data.Value {
    return switch (expr.data) {
      .constr_call => |_| {
        unreachable; // TODO
      },
      .call => |*call| blk: {
        const target = try self.evaluate(call.target);
        break :blk switch (target.data) {
          .funcref => |fr| innerblk: {
            switch (fr.func.data) {
              .ext_func => |*ef| {
                const target_impl =
                  self.context.builtin_registry.items[ef.impl_index];
                std.debug.assert(
                  call.exprs.len == ef.signature.parameters.len);
                ef.cur_frame = try self.setupParameterStackFrame(
                  ef.signature, ef.cur_frame.?);
                defer self.resetParameterStackFrame(ef);
                try self.fillParameterStackFrame(
                  call.exprs, ef.cur_frame.? + 1);
                break :innerblk target_impl(self, expr.pos, ef.cur_frame.? + 1);
              },
              .ny_func => |*nf| {
                defer bindVariables(&nf.variables, nf.cur_frame);
                nf.cur_frame = try self.setupParameterStackFrame(
                  nf.signature, nf.cur_frame);
                defer self.resetParameterStackFrame(nf);
                try self.fillParameterStackFrame(
                  call.exprs, nf.cur_frame.? + 1);
                bindVariables(&nf.variables, nf.cur_frame);
                break :blk self.evaluate(nf.body);
              },
              else => unreachable,
            }
          },
          .typeval => |_| {
            unreachable; // not implemented yet
          },
          .poison => data.Value.create(
            &self.context.storage.allocator, expr.pos, .poison),
          else => unreachable
        };
      },
      .assignment => |*assignment| blk: {
        var cur_ptr = assignment.target.cur_value.?;
        for (assignment.path) |index| {
          cur_ptr = switch (cur_ptr.*.data) {
            .record => |*record| &record.fields[index],
            .list   => |*list|   &list.items.items[index],
            else => unreachable,
          };
        }
        cur_ptr.* = try self.evaluate(assignment.expr);
        break :blk data.Value.create(
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
      .var_retrieval => |*var_retr| var_retr.variable.cur_value.*,
      .literal => |*literal| &literal.value,
      .poison =>
        data.Value.create(&self.context.storage.allocator, expr.pos, .poison),
      .void =>
        data.Value.create(&self.context.storage.allocator, expr.pos, .void),
    };
  }
};