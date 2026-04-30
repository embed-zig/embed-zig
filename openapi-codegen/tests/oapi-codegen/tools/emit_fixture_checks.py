#!/usr/bin/env python3
"""Emit explicit checkFixture() bodies (+ TestRunner) from spec.json. Run from repo root:
    python3 tests/oapi-codegen/tools/emit_fixture_checks.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # tests/oapi-codegen
REPO = ROOT.parent.parent  # repo root


def zig_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def emit_schema_inspect(name: str, schema: object, lines: list[str], indent: str) -> None:
    if not isinstance(schema, dict):
        return
    sor = f"_sor_{re.sub(r'[^a-zA-Z0-9_]', '_', name)}"
    lines.append(
        f"{indent}const {sor} = Spec.findNamed(Spec.SchemaOrRef, components.schemas, {zig_str(name)}) orelse return error.FixtureMismatch;"
    )
    lines.append(f"{indent}switch ({sor}) {{")
    lines.append(f"{indent}    .reference => |r| {{")
    lines.append(f"{indent}        _ = r.ref_path;")
    lines.append(f"{indent}    }},")
    lines.append(f"{indent}    .schema => |sch| {{")
    before_schema_arm = len(lines)
    if "type" in schema and isinstance(schema["type"], str):
        lines.append(
            f"{indent}        try std.testing.expectEqualStrings({zig_str(schema['type'])}, sch.schema_type orelse return error.FixtureMismatch);"
        )
    if "anyOf" in schema and isinstance(schema["anyOf"], list):
        lines.append(
            f"{indent}        try std.testing.expectEqual(@as(usize, {len(schema['anyOf'])}), sch.any_of.len);"
        )
    if "oneOf" in schema and isinstance(schema["oneOf"], list):
        lines.append(
            f"{indent}        try std.testing.expectEqual(@as(usize, {len(schema['oneOf'])}), sch.one_of.len);"
        )
    if "allOf" in schema and isinstance(schema["allOf"], list):
        lines.append(
            f"{indent}        try std.testing.expectEqual(@as(usize, {len(schema['allOf'])}), sch.all_of.len);"
        )
    if "properties" in schema and isinstance(schema["properties"], dict):
        lines.append(
            f"{indent}        try std.testing.expectEqual(@as(usize, {len(schema['properties'])}), sch.properties.len);"
        )
        for prop_name, psc in schema["properties"].items():
            if isinstance(psc, dict) and "anyOf" in psc and isinstance(psc["anyOf"], list):
                n = len(psc["anyOf"])
                pfn = zig_str(prop_name)
                lines.append(f"{indent}        {{")
                lines.append(
                    f"{indent}            const pf = Spec.findNamed(Spec.SchemaOrRef, sch.properties, {pfn}) orelse return error.FixtureMismatch;"
                )
                lines.append(f"{indent}            const pSch = switch (pf) {{")
                lines.append(f"{indent}                .schema => |x| x,")
                lines.append(
                    f"{indent}                .reference => return error.FixtureMismatch,"
                )
                lines.append(f"{indent}            }};")
                lines.append(
                    f"{indent}            try std.testing.expectEqual(@as(usize, {n}), pSch.any_of.len);"
                )
                lines.append(f"{indent}        }}")
    if "required" in schema and isinstance(schema["required"], list):
        lines.append(
            f"{indent}        try std.testing.expectEqual(@as(usize, {len(schema['required'])}), sch.required.len);"
        )
    if len(lines) == before_schema_arm:
        lines.append(f"{indent}        _ = sch;")
    lines.append(f"{indent}    }},")
    lines.append(f"{indent}}}")


def emit_response_schema_checks(path_key: str, method: str, op: dict, lines: list[str], indent: str) -> None:
    responses = op.get("responses") or {}
    if not isinstance(responses, dict):
        return
    for status, resp in responses.items():
        if not isinstance(resp, dict):
            continue
        content = resp.get("content")
        # Some fixtures omit `content` and put media-type keys directly under the status object.
        if not content and all(
            isinstance(k, str) and "/" in k for k in resp.keys()
        ):
            content = resp
        if not isinstance(content, dict):
            continue
        for media, mt in content.items():
            if not isinstance(mt, dict):
                continue
            sc = mt.get("schema")
            if not isinstance(sc, dict):
                continue
            # Nested anyOf under items (inline pets API)
            if (
                sc.get("type") == "object"
                and "properties" in sc
                and isinstance(sc["properties"], dict)
            ):
                for prop_name, psc in sc["properties"].items():
                    if not isinstance(psc, dict):
                        continue
                    items = psc.get("items")
                    if isinstance(items, dict) and "anyOf" in items and isinstance(items["anyOf"], list):
                        n = len(items["anyOf"])
                        mop_var = f"{method}_op"
                        lines.append(f"{indent}{{")
                        lines.append(
                            f"{indent}    const res_or = Spec.findNamed(Spec.ResponseOrRef, {mop_var}.responses, {zig_str(status)}) orelse return error.FixtureMismatch;"
                        )
                        lines.append(f"{indent}    const res = switch (res_or) {{")
                        lines.append(f"{indent}        .response => |x| x,")
                        lines.append(
                            f"{indent}        .reference => return error.FixtureMismatch,"
                        )
                        lines.append(f"{indent}    }};")
                        lines.append(
                            f"{indent}    const mt = Spec.findNamed(Spec.MediaType, res.content, {zig_str(media)}) orelse return error.FixtureMismatch;"
                        )
                        lines.append(
                            f"{indent}    const root_sch_ptr = mt.schema orelse return error.FixtureMismatch;"
                        )
                        lines.append(f"{indent}    const root_sch = switch (root_sch_ptr.*) {{")
                        lines.append(f"{indent}        .schema => |s| s,")
                        lines.append(
                            f"{indent}        .reference => return error.FixtureMismatch,"
                        )
                        lines.append(f"{indent}    }};")
                        lines.append(
                            f"{indent}    const data_f = Spec.findNamed(Spec.SchemaOrRef, root_sch.properties, {zig_str(prop_name)}) orelse return error.FixtureMismatch;"
                        )
                        lines.append(f"{indent}    const data_sch = switch (data_f) {{")
                        lines.append(f"{indent}        .schema => |s| s,")
                        lines.append(
                            f"{indent}        .reference => return error.FixtureMismatch,"
                        )
                        lines.append(f"{indent}    }};")
                        lines.append(
                            f"{indent}    const items_ptr = data_sch.items orelse return error.FixtureMismatch;"
                        )
                        lines.append(f"{indent}    const items_sch = switch (items_ptr.*) {{")
                        lines.append(f"{indent}        .schema => |s| s,")
                        lines.append(
                            f"{indent}        .reference => return error.FixtureMismatch,"
                        )
                        lines.append(f"{indent}    }};")
                        lines.append(
                            f"{indent}    try std.testing.expectEqual(@as(usize, {n}), items_sch.any_of.len);"
                        )
                        lines.append(f"{indent}}}")


def emit_check_body(spec: dict) -> str:
    lines: list[str] = []
    indent = "            "
    lines.append(
        f'{indent}try std.testing.expectEqualStrings({zig_str(spec["openapi"])}, spec.openapi);'
    )
    info = spec.get("info") or {}
    lines.append(
        f'{indent}try std.testing.expectEqualStrings({zig_str(info.get("title", ""))}, spec.info.title);'
    )
    lines.append(
        f'{indent}try std.testing.expectEqualStrings({zig_str(info.get("version", ""))}, spec.info.version);'
    )

    paths = spec.get("paths") or {}
    if isinstance(paths, dict):
        lines.append(
            f"{indent}try std.testing.expectEqual(@as(usize, {len(paths)}), spec.paths.len);"
        )
        for path_key, path_obj in paths.items():
            if not isinstance(path_obj, dict):
                continue
            pk = zig_str(path_key)
            lines.append(f"{indent}{{")
            lines.append(
                f"{indent}    const p_or = Spec.findNamed(Spec.PathItemOrRef, spec.paths, {pk}) orelse return error.FixtureMismatch;"
            )
            if "$ref" in path_obj:
                ref = path_obj.get("$ref")
                lines.append(f"{indent}    const pref = switch (p_or) {{")
                lines.append(f"{indent}        .path_item => return error.FixtureMismatch,")
                lines.append(f"{indent}        .reference => |x| x,")
                lines.append(f"{indent}    }};")
                if isinstance(ref, str):
                    lines.append(
                        f"{indent}    try std.testing.expectEqualStrings({zig_str(ref)}, pref.ref_path);"
                    )
                lines.append(f"{indent}}}")
                continue
            lines.append(f"{indent}    const p_it = switch (p_or) {{")
            lines.append(f"{indent}        .path_item => |x| x,")
            lines.append(
                f"{indent}        .reference => return error.FixtureMismatch,"
            )
            lines.append(f"{indent}    }};")
            methods_present = [
                m
                for m in ("get", "post", "put", "delete", "patch", "options", "head", "trace")
                if m in path_obj and isinstance(path_obj.get(m), dict)
            ]
            if not methods_present:
                lines.append(f"{indent}    _ = p_it;")
            else:
                for meth in methods_present:
                    op = path_obj[meth]
                    assert isinstance(op, dict)
                    oid = op.get("operationId")
                    lines.append(
                        f"{indent}    const {meth}_op = p_it.{meth} orelse return error.FixtureMismatch;"
                    )
                    if oid is not None:
                        lines.append(
                            f"{indent}    try std.testing.expectEqualStrings({zig_str(oid)}, {meth}_op.operation_id orelse return error.FixtureMismatch);"
                        )
                    else:
                        lines.append(
                            f"{indent}    try std.testing.expectEqual(@as(?[]const u8, null), {meth}_op.operation_id);"
                        )
                    params = op.get("parameters")
                    if isinstance(params, list):
                        lines.append(
                            f"{indent}    try std.testing.expectEqual(@as(usize, {len(params)}), {meth}_op.parameters.len);"
                        )
                    emit_response_schema_checks(
                        path_key, meth, op, lines, indent + "    "
                    )
            lines.append(f"{indent}}}")

    comps = spec.get("components") or {}
    schemas = comps.get("schemas") if isinstance(comps, dict) else None
    if isinstance(schemas, dict) and schemas:
        lines.append(
            f"{indent}const components = spec.components orelse return error.FixtureMismatch;"
        )
        lines.append(
            f"{indent}try std.testing.expectEqual(@as(usize, {len(schemas)}), components.schemas.len);"
        )
        for name, schema in schemas.items():
            if isinstance(schema, dict) and "$ref" in schema and len(schema) == 1:
                ref = schema["$ref"]
                sor = f"_ref_{re.sub(r'[^a-zA-Z0-9_]', '_', name)}"
                lines.append(
                    f"{indent}const {sor} = Spec.findNamed(Spec.SchemaOrRef, components.schemas, {zig_str(name)}) orelse return error.FixtureMismatch;"
                )
                lines.append(f"{indent}switch ({sor}) {{")
                lines.append(f"{indent}    .reference => |r| try std.testing.expectEqualStrings({zig_str(ref)}, r.ref_path),")
                lines.append(
                    f"{indent}    .schema => return error.FixtureMismatch,"
                )
                lines.append(f"{indent}}}")
            elif isinstance(schema, dict):
                emit_schema_inspect(name, schema, lines, indent)

    return "\n".join(lines)


def embedded_test_runner_fn(body: str) -> str:
    """TestRunner with local Spec alias (for files that also define ClientApi / ServerApi at top level)."""
    spec_decl = (
        "            const Spec = openapi.Spec;\n"
        if "Spec." in body
        else ""
    )
    return f"""pub fn TestRunner() testing.TestRunner {{
    const Runner = struct {{
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {{}}

        pub fn run(_: *@This(), t: *testing.T, allocator: std.mem.Allocator) bool {{
            checkFixture(allocator) catch |e| {{
                t.logFatal(@errorName(e));
                return false;
            }};
            return true;
        }}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {{}}

        fn checkFixture(allocator: std.mem.Allocator) !void {{
{spec_decl}            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const spec = try openapi.json.parseAlloc(a, @embedFile("spec.json"));
{body}
        }}
    }};

    const holder = struct {{
        var state: Runner = .{{}};
    }};

    return testing.TestRunner.make(Runner).new(&holder.state);
}}
"""


PARSE_ASSERT_FIXTURE_TEST_RE = re.compile(
    r"\ntest \"parse, roundtrip, and validate structure\" \{\n"
    r"\s*try helpers\.assertDetailedFixture\(@embedFile\(\"spec\.json\"\)\);\n"
    r"\}\n"
)


def ensure_std_testing_openapi_imports(text: str) -> str:
    to_add: list[str] = []
    if re.search(r"^const std = @import\(\"std\"\);", text, re.MULTILINE) is None:
        to_add.append('const std = @import("std");')
    if re.search(r"^const embed = @import\(\"embed\"\);", text, re.MULTILINE) is None:
        to_add.append('const embed = @import("embed");')
    if re.search(r"^const testing = embed\.testing;", text, re.MULTILINE) is None:
        to_add.append('const testing = embed.testing;')
    if re.search(r"^const openapi = @import\(\"openapi\"\);", text, re.MULTILINE) is None:
        to_add.append('const openapi = @import("openapi");')
    if not to_add:
        return text
    return "\n".join(to_add) + "\n" + text


def migrate_parse_assert_fixture_test(
    text: str, body: str, test_zig: Path
) -> str | None:
    if not PARSE_ASSERT_FIXTURE_TEST_RE.search(text):
        return None
    if "pub fn TestRunner()" in text:
        return None
    text2 = PARSE_ASSERT_FIXTURE_TEST_RE.sub("\n", text, count=1)
    text2 = ensure_std_testing_openapi_imports(text2)
    block = embedded_test_runner_fn(body) + "\n"
    m = re.search(r"^(test |pub fn )", text2, re.MULTILINE)
    if m:
        return text2[: m.start()] + block + text2[m.start() :]
    return text2 + block


RUNNER_TEMPLATE_SINGLE = """const std = @import("std");
const embed = @import("embed");
const testing = embed.testing;
const openapi = @import("openapi");
const Spec = openapi.Spec;

pub fn TestRunner() testing.TestRunner {{
    const Runner = struct {{
        pub fn init(_: *@This(), _: std.mem.Allocator) !void {{}}

        pub fn run(_: *@This(), t: *testing.T, allocator: std.mem.Allocator) bool {{
            checkFixture(allocator) catch |e| {{
                t.logFatal(@errorName(e));
                return false;
            }};
            return true;
        }}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {{}}

        fn checkFixture(allocator: std.mem.Allocator) !void {{
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const spec = try openapi.json.parseAlloc(a, @embedFile("spec.json"));
{body}
        }}
    }};

    const holder = struct {{
        var state: Runner = .{{}};
    }};

    return testing.TestRunner.make(Runner).new(&holder.state);
}}
"""


def is_simple_runner_only(text: str) -> bool:
    return (
        "assertDetailedFixture" in text
        and "pub fn runner()" in text
        and text.count("pub fn ") == 1
    )


def is_single_test_runner_refresh(text: str, test_zig: Path) -> bool:
    """Regenerate emitted body for fixed one-runner fixtures (already using TestRunner)."""
    if re.search(r"^test ", text, re.MULTILINE):
        return False
    return (
        "pub fn TestRunner()" in text
        and text.count("pub fn ") == 1
        and "checkFixture" in text
    )


def replace_runner_spec(text: str, body: str) -> str:
    # Legacy: pub fn runnerSpec() ... fromFn ... assertDetailedFixture
    pattern = r"pub fn runnerSpec\(\) testing\.TestRunner \{[\s\S]*?try helpers\.assertDetailedFixture\(@embedFile\(\"spec\.json\"\)\);\s*\}\s*\}\s*\.run\);\s*\}"
    replacement = embedded_test_runner_fn(body)
    new_text, n = re.subn(pattern, replacement, text, count=1)
    if n != 1:
        raise RuntimeError("runnerSpec pattern not found or ambiguous")
    return new_text


def strip_unused_helpers_import(text: str) -> str:
    if "@import(\"helpers\")" not in text:
        return text
    if re.search(r"helpers\.", text):
        return text
    return re.sub(r"const helpers = @import\(\"helpers\"\);\n", "", text)


def strip_redundant_inner_spec_in_checkfixture(text: str) -> str:
    """Remove checkFixture-local `const Spec` when the file already aliases Spec at module scope."""
    if not re.search(r"^const Spec = openapi\.Spec;$", text, re.MULTILINE):
        return text
    return re.sub(
        r"(fn checkFixture\(allocator: std.mem.Allocator\) !void \{\n)            const Spec = openapi\.Spec;\n(            var arena = std.heap.ArenaAllocator\.init)",
        r"\1\2",
        text,
    )


def inject_spec_into_checkfixtures(text: str) -> str:
    """Multi-runner fixtures (or manual migrations) may use Spec.* in checkFixture without a local alias."""
    m = re.search(
        r"fn checkFixture\(allocator: std.mem.Allocator\) !void \{", text
    )
    if not m:
        return text
    before = text[: m.start()]
    if re.search(r"^const Spec = openapi\.Spec;$", before, re.MULTILINE):
        return text
    return re.sub(
        r"(fn checkFixture\(allocator: std.mem.Allocator\) !void \{)\n(            var arena = std.heap.ArenaAllocator\.init)",
        r"\1\n            const Spec = openapi.Spec;\n\2",
        text,
    )


def main() -> None:
    for test_zig in sorted(ROOT.rglob("test.zig")):
        spec_path = test_zig.parent / "spec.json"
        if not spec_path.exists():
            continue
        spec = json.loads(spec_path.read_text())
        body = emit_check_body(spec)
        text = test_zig.read_text()
        new_text = text

        if is_simple_runner_only(text):
            new_text = RUNNER_TEMPLATE_SINGLE.format(body=body)
        elif "assertDetailedFixture" in text and "pub fn runnerSpec()" in text:
            new_text = replace_runner_spec(text, body)
        else:
            mig = migrate_parse_assert_fixture_test(text, body, test_zig)
            if mig is not None:
                new_text = mig
            elif is_single_test_runner_refresh(text, test_zig):
                new_text = RUNNER_TEMPLATE_SINGLE.format(body=body)
            elif "assertDetailedFixture" in text:
                print("SKIP (manual):", test_zig.relative_to(REPO))

        new_text = strip_unused_helpers_import(new_text)
        if new_text != text:
            test_zig.write_text(new_text)

    for test_zig in sorted(ROOT.rglob("test.zig")):
        txt = test_zig.read_text()
        txt2 = strip_redundant_inner_spec_in_checkfixture(txt)
        if txt2 != txt:
            test_zig.write_text(txt2)
            txt = txt2
        if "fn checkFixture(allocator: std.mem.Allocator) !void {" not in txt:
            continue
        if "Spec.findNamed" not in txt and "Spec.PathItemOrRef" not in txt:
            continue
        new_txt = inject_spec_into_checkfixtures(txt)
        if new_txt != txt:
            test_zig.write_text(new_txt)

    root = REPO / "tests" / "oapi-codegen.zig"
    z = root.read_text()
    z2 = z.replace(").runnerSpec()", ").TestRunner()")
    z2 = z2.replace(").runner()", ").TestRunner()")
    root.write_text(z2)


if __name__ == "__main__":
    main()
