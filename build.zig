const std = @import("std");
const Builder = std.build.Builder;

const dataPkg = std.build.Pkg{
  .name = "data",
  .path = "data.zig",
};

fn internalPackages(s: *std.build.LibExeObjStep) void {
  s.addPackage(dataPkg);
  s.addPackage(.{
    .name = "lex",
    .path = "load/lex.zig",
    .dependencies = &.{dataPkg},
  });
  s.addPackage(.{
    .name = "parse",
    .path = "load/parse.zig",
    .dependencies = &.{dataPkg},
  });
  s.addPackage(.{
    .name = "source",
    .path = "load/source.zig",
  });
  s.addPackage(.{
    .name = "interpret",
    .path = "load/interpret.zig",
  });
}

pub fn build(b: *Builder) !void {
  const mode = b.standardReleaseOptions();
  const target = b.standardTargetOptions(.{});

  var testgen_exe = b.addExecutable("testgen", "test/testgen.zig");
  var testgen_cmd = testgen_exe.run();
  testgen_cmd.cwd = "test";
  testgen_cmd.step.dependOn(&testgen_exe.step);

  var lex_test = b.addTest("test/lex_test.zig");
  lex_test.step.dependOn(&testgen_cmd.step);
  internalPackages(lex_test);

  var lex_test_step = b.step("lexTest", "Run lexer tests");
  lex_test_step.dependOn(&lex_test.step);

  var parse_test = b.addTest("test/parse_test.zig");
  internalPackages(parse_test);

  var parse_test_step = b.step("parseTest", "Run parser tests");
  parse_test_step.dependOn(&parse_test.step);
}