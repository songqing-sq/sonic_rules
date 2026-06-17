# BUILD for @thrift_src_0_17_0: build the standalone Apache Thrift 0.17.0
# compiler (compiler/cpp/ only) as a cc_binary.
#
# The compiler is the codegen program: it does NOT link libthrift or boost. Its
# only generated inputs are the flex lexer (thriftl.ll) and bison parser
# (thrifty.yy). Mirrors compiler/cpp/CMakeLists.txt:
#   * BISON_TARGET thrifty.yy -> thrifty.cc + thrifty.hh  (C/yacc parser)
#   * FLEX_TARGET  thriftl.ll -> thriftl.cc
#   * compiler sources: main.cc, audit/t_audit.cpp, common.cc,
#     generate/t_generator.cc, parse/t_typedef.cc, parse/parse.cc, and every
#     generate/t_*_generator.cc (all langs ON by default in CMake).
#   * include dirs: src (for "thrift/...") + the genfiles dir (for the generated
#     "thrift/thrifty.hh" the lexer #includes).
# logging.cc is intentionally excluded: main.cc already defines g_debug/pdebug/
# pwarning/failure/... (the autotools thrift_SOURCES list omits logging.cc), so
# including it causes multiple-definition link errors under modern gcc.

load("@rules_bison//bison:bison.bzl", "bison")
load("@rules_flex//flex:flex.bzl", "flex")
load("@rules_cc//cc:defs.bzl", "cc_binary")

package(default_visibility = ["//visibility:public"])

# --- bison: thrifty.yy -> thrifty.cc + thrifty.h ---------------------------
# rules_bison's `bison` rule emits {name}.cc + {name}.h for a .yy source (C++
# output filename, but with the default C/yacc skeleton -> yacc-compatible
# yyparse, which is what thrift's main.cc / lexer expect). NOTE: the generated
# thrifty.cc #includes its own header by basename "thrifty.hh" (not .h), and
# thrift's lexer (thriftl.ll) #includes "thrift/thrifty.hh" by default. So the
# staging genrule below renames bison's thrifty.h -> thrifty.hh and places both
# thrifty.cc + thrifty.hh under gen/thrift/ (same dir, so the .cc's basename
# include resolves and the lexer's "thrift/thrifty.hh" resolves via includes=gen).
# language = "c": thrift's parser uses the yacc-compatible C skeleton (global
# yyparse / yylex), NOT bison's C++ `yy::parser` class. rules_bison would default
# a .yy source to --language=c++ (incompatible: yylex signature mismatch), so the
# C language is forced. C mode emits thrifty.c + thrifty.h, renamed/staged below.
bison(
    name = "thrifty",
    src = "compiler/cpp/src/thrift/thrifty.yy",
    language = "c",
    bison_options = ["-Wno-deprecated"],
)

# --- flex: thriftl.ll -> thriftl.c -----------------------------------------
# language = "c": thrift's lexer is a traditional C flex scanner (global yylex),
# NOT a C++ yyFlexLexer class. rules_flex would default a .ll source to flex++
# (--c++, incompatible), so the C language is forced. C mode emits thriftl.c.
flex(
    name = "thriftl",
    src = "compiler/cpp/src/thrift/thriftl.ll",
    language = "c",
)

# Stage the generated parser/lexer under gen/thrift/ with the names the thrift
# sources expect: thrifty.cc, thrifty.hh (renamed from bison's thrifty.h), and
# thriftl.cc. The generated thrifty.cc includes "thrifty.hh" (same dir) and the
# lexer includes "thrift/thrifty.hh" (resolved via includes = ["gen"]).
# bison C mode -> thrifty.c + thrifty.h ; flex C mode -> thriftl.c + thriftl.h.
# Stage as: thrifty.cc, thrifty.hh, thriftl.cc (thriftl.h is unused by thrift).
genrule(
    name = "gen_parser_staged",
    srcs = [":thrifty", ":thriftl"],
    outs = [
        "gen/thrift/thrifty.cc",
        "gen/thrift/thrifty.hh",
        "gen/thrift/thriftl.cc",
    ],
    cmd = """
set -e
out=$(RULEDIR)/gen/thrift
mkdir -p $$out
for f in $(locations :thrifty) $(locations :thriftl); do
  case $$f in
    *thrifty.c)  cp $$f $$out/thrifty.cc ;;
    *thrifty.h)  cp $$f $$out/thrifty.hh ;;
    *thriftl.c)  cp $$f $$out/thriftl.cc ;;
  esac
done
""",
)

# Every language generator (all ON in CMakeLists THRIFT_ADD_COMPILER defaults).
GENERATOR_SRCS = glob(["compiler/cpp/src/thrift/generate/t_*_generator.cc"])

cc_binary(
    name = "thrift_compiler",
    srcs = [
        "compiler/cpp/src/thrift/main.cc",
        "compiler/cpp/src/thrift/audit/t_audit.cpp",
        "compiler/cpp/src/thrift/common.cc",
        "compiler/cpp/src/thrift/generate/t_generator.cc",
        "compiler/cpp/src/thrift/parse/t_typedef.cc",
        "compiler/cpp/src/thrift/parse/parse.cc",
        "gen/thrift/thrifty.cc",
        "gen/thrift/thrifty.hh",
        "gen/thrift/thriftl.cc",
    ] + GENERATOR_SRCS + glob([
        "compiler/cpp/src/thrift/**/*.h",
    ]),
    copts = [
        # Generated flex/bison + 0.17-era sources trip modern -W; the autotools
        # build was not -Werror for these. Silence to keep the build clean.
        "-w",
    ],
    includes = [
        # "thrift/..." resolves from compiler/cpp/src.
        "compiler/cpp/src",
        # "thrift/thrifty.hh" (the staged generated header) resolves from gen/.
        "gen",
    ],
    linkopts = ["-lm"],
)
