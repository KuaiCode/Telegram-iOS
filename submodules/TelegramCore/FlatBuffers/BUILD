load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "FlatBuffers",
    module_name = "FlatBuffers",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # -suppress-warnings conflicts with the diagnostic group policy in .bazelrc.
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)
