const std = @import("std");
const Builder = std.build.Builder;

const data_pkg = std.build.Pkg{
  .name = "data",
  .path = "data.zig",
};

const errors_pkg = std.build.Pkg{
  .name = "errors",
  .path = "errors_generated.zig",
  .dependencies = &.{data_pkg},
};

const source_pkg = std.build.Pkg{
  .name = "source",
  .path = "load/source.zig",
};

const interpret_pkg = std.build.Pkg{
  .name = "interpret",
  .path = "load/interpret.zig",
  .dependencies = &.{errors_pkg, data_pkg},
};

const lex_pkg = std.build.Pkg{
  .name = "lex",
  .path = "load/lex.zig",
  .dependencies = &.{data_pkg},
};

const parse_pkg = std.build.Pkg{
  .name = "parse",
  .path = "load/parse.zig",
  .dependencies = &.{data_pkg, errors_pkg},
};

const internal_pkgs = [_]std.build.Pkg{
  data_pkg, errors_pkg, lex_pkg, parse_pkg, source_pkg, interpret_pkg};

fn internalPackages(s: *std.build.LibExeObjStep) void {
  for (internal_pkgs) |pkg| {
    s.addPackage(pkg);
  }
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
  testgen_exe.addPackage(.{
    .name = "tml",
    .path = "test/tml.zig",
  });
  var testgen_cmd = testgen_exe.run();
  testgen_cmd.cwd = "test";
  testgen_cmd.step.dependOn(&testgen_exe.step);

  var lex_test = b.addTest("test/lex_test.zig");
  lex_test.step.dependOn(&testgen_cmd.step);
  lex_test.step.dependOn(&ehgen_cmd.step);
  internalPackages(lex_test);
  lex_test.addPackage(.{
    .name = "testing",
    .path = "test/testing.zig",
    .dependencies = &internal_pkgs,
  });

  var lex_test_step = b.step("lexTest", "Run lexer tests");
  lex_test_step.dependOn(&lex_test.step);

  var parse_test = b.addTest("test/parse_test.zig");
  parse_test.step.dependOn(&testgen_cmd.step);
  parse_test.step.dependOn(&ehgen_cmd.step);
  internalPackages(parse_test);
  parse_test.addPackage(.{
    .name = "testing",
    .path = "test/testing.zig",
    .dependencies = &internal_pkgs,
  });

  var parse_test_step = b.step("parseTest", "Run parser tests");
  parse_test_step.dependOn(&parse_test.step);

  var parse_test_orig = b.addTest("test/parse_test_orig.zig");
  parse_test_orig.step.dependOn(&ehgen_cmd.step);
  internalPackages(parse_test_orig);
  parse_test_orig.addPackage(.{
    .name = "testing",
    .path = "test/testing.zig",
    .dependencies = &internal_pkgs,
  });

  var parse_test_orig_step = b.step("parseTestOrig", "Run original parser tests");
  parse_test_orig_step.dependOn(&parse_test_orig.step);
}