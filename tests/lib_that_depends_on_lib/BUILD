package(default_visibility = ["//visibility:public"])

load("@io_bazel_rules_d//d:d.bzl", "d_library")

d_library(
    name = "lib_that_depends_on_lib",
    srcs = ["lib_that_depends_on_lib.d"],
    deps = ["//tests/simple_d_library",
    		"//tests/simple_c_library",
        	"//tests/simple_c_library:simple_c_library_wrapper",
        	],
    imports = ["..",
    		   "../simple_d_library"],
)
6