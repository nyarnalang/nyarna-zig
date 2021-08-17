const std = @import("std");
const Builder = std.build.Builder;

const dataPkg = std.build.Pkg{
  .name = "data",
  .path = "data.zig",
};

const errorsPkg = std.build.Pkg{
  .name = "errors",
  .path = "errors_generated.zig",
  .dependencies = &.{dataPkg},
};

fn internalPackages(s: *std.build.LibExeObjStep) void {
  s.addPackage(dataPkg);
  s.addPackage(errorsPkg);
  s.addPackage(.{
    .name = "lex",
    .path = "load/lex.zig",
    .dependencies = &.{dataPkg},
  });
  s.addPackage(.{
    .name = "parse",
    .path = "load/parse.zig",
    .dependencies = &.{dataPkg, errorsPkg},
  });
  s.addPackage(.{
    .name = "source",
    .path = "load/source.zig",
  });
  s.addPackage(.{
    .name = "interpret",
    .path = "load/interpret.zig",
    .dependencies = &.{errorsPkg},
  });
}

pub fn build(b: *Builder) !void {
  const mode = b.standardReleaseOptions();
  const target = b.standardTargetOptions(.{});

  var ehgen_exe = b.addExecutable("ehgen", "build/gen_errorhandler.zig");
  ehgen_exe.addPackage(.{
    .name = "errors",
    .path = "errors.zig"
  });
  var ehgen_cmd = ehgen_exe.run();
  ehgen_cmd.cwd = ".";
  ehgen_cmd.step.dependOn(&ehgen_exe.step);

  var testgen_exe = b.addExecutable("testgen", "build/gen_tests.zig");
  var testgen_cmd = testgen_exe.run();
  testgen_cmd.cwd = "test";
  testgen_cmd.step.dependOn(&testgen_exe.step);

  var lex_test = b.addTest("test/lex_test.zig");
  lex_test.step.dependOn(&testgen_cmd.step);
  lex_test.step.dependOn(&ehgen_cmd.step);
  internalPackages(lex_test);

  var lex_test_step = b.step("lexTest", "Run lexer tests");
  lex_test_step.dependOn(&lex_test.step);

  var parse_test = b.addTest("test/parse_test.zig");
  parse_test.step.dependOn(&ehgen_cmd.step);
  internalPackages(parse_test);

  var parse_test_step = b.step("parseTest", "Run parser tests");
  parse_test_step.dependOn(&parse_test.step);
}