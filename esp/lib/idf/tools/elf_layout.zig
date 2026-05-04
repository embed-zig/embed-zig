// Host tool that inspects the built app ELF and summarizes its memory/layout
// characteristics for regression tracking.
// Outputs a human-readable `elf_layout.txt` report and mirrors the same report
// to stdout for immediate inspection.
const std = @import("std");

const SHF_WRITE = 0x1;
const SHF_ALLOC = 0x2;
const SHF_EXECINSTR = 0x4;
const PF_X = 0x1;
const PF_W = 0x2;
const PF_R = 0x4;
const SHT_NOBITS = 8;
const SHT_SYMTAB = 2;
const SHT_DYNSYM = 11;
const STT_NOTYPE = 0;
const STT_OBJECT = 1;
const STT_FUNC = 2;
const STT_SECTION = 3;
const STT_FILE = 4;
const top_code_symbol_limit = 40;

const Elf32Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf32Shdr = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u32,
    sh_addr: u32,
    sh_offset: u32,
    sh_size: u32,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u32,
    sh_entsize: u32,
};

const Elf32Phdr = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

const Elf32Sym = extern struct {
    st_name: u32,
    st_value: u32,
    st_size: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
};

const Section = struct {
    index: usize,
    name: []const u8,
    sh_type: u32,
    flags: u32,
    addr: u32,
    offset: u32,
    size: u32,
    link: u32,
    info: u32,
    addralign: u32,
    entsize: u32,
};

const Program = struct {
    index: usize,
    p_type: u32,
    offset: u32,
    vaddr: u32,
    paddr: u32,
    filesz: u32,
    memsz: u32,
    flags: u32,
    @"align": u32,
};

const CodeSymbol = struct {
    name: []const u8,
    source_name: []const u8,
    section_name: []const u8,
    value: u32,
    size: u32,
    bind: u8,
    typ: u8,

    fn desc(_: void, lhs: CodeSymbol, rhs: CodeSymbol) bool {
        if (lhs.size != rhs.size) return lhs.size > rhs.size;
        if (lhs.value != rhs.value) return lhs.value < rhs.value;
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }
};

const ModuleStat = struct {
    name: []const u8,
    total_size: u64,
    symbol_count: usize,

    fn desc(_: void, lhs: ModuleStat, rhs: ModuleStat) bool {
        if (lhs.total_size != rhs.total_size) return lhs.total_size > rhs.total_size;
        if (lhs.symbol_count != rhs.symbol_count) return lhs.symbol_count > rhs.symbol_count;
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }
};

fn readCString(blob: []const u8, off: u32) []const u8 {
    const start = @min(off, @as(u32, @intCast(blob.len)));
    var end: usize = start;
    while (end < blob.len and blob[end] != 0) : (end += 1) {}
    return blob[start..end];
}

fn sourceModuleName(path: []const u8) []const u8 {
    return stripExt(basename(path));
}

fn symbolModuleName(name: []const u8) []const u8 {
    if (name.len == 0) return name;

    if (std.mem.indexOfScalar(u8, name, '.')) |first_dot| {
        if (std.mem.indexOfScalarPos(u8, name, first_dot + 1, '.')) |second_dot| {
            return name[0..second_dot];
        }
        return name[0..first_dot];
    }

    if (std.mem.startsWith(u8, name, "lv_")) return "lvgl";
    if (std.mem.startsWith(u8, name, "opus_")) return "opus";
    if (std.mem.startsWith(u8, name, "ogg_")) return "ogg";
    if (std.mem.startsWith(u8, name, "celt_")) return "opus.celt";
    if (std.mem.startsWith(u8, name, "silk_")) return "opus.silk";

    if (name[0] == '_') {
        if (std.mem.indexOfScalarPos(u8, name, 1, '_')) |next_underscore| {
            return name[0..next_underscore];
        }
        return name;
    }

    if (std.mem.indexOfScalar(u8, name, '_')) |underscore| {
        return name[0..underscore];
    }

    if (std.mem.indexOfScalar(u8, name, '(')) |paren| {
        return name[0..paren];
    }

    return name;
}

fn topLevelModuleName(name: []const u8) []const u8 {
    if (name.len == 0) return name;
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

fn shtName(t: u32) []const u8 {
    return switch (t) {
        0 => "NULL",
        1 => "PROGBITS",
        2 => "SYMTAB",
        3 => "STRTAB",
        4 => "RELA",
        5 => "HASH",
        6 => "DYNAMIC",
        7 => "NOTE",
        8 => "NOBITS",
        9 => "REL",
        10 => "SHLIB",
        11 => "DYNSYM",
        else => "UNKNOWN",
    };
}

fn ptName(t: u32) []const u8 {
    return switch (t) {
        0 => "NULL",
        1 => "LOAD",
        2 => "DYNAMIC",
        3 => "INTERP",
        4 => "NOTE",
        5 => "SHLIB",
        6 => "PHDR",
        7 => "TLS",
        0x6474E551 => "GNU_STACK",
        else => "UNKNOWN",
    };
}

fn etName(t: u16) []const u8 {
    return switch (t) {
        0 => "NONE (None)",
        1 => "REL (Relocatable file)",
        2 => "EXEC (Executable file)",
        3 => "DYN (Shared object file)",
        4 => "CORE (Core file)",
        else => "UNKNOWN",
    };
}

fn stTypeName(t: u8) []const u8 {
    return switch (t) {
        STT_NOTYPE => "NOTYPE",
        STT_OBJECT => "OBJECT",
        STT_FUNC => "FUNC",
        STT_SECTION => "SECTION",
        STT_FILE => "FILE",
        else => "OTHER",
    };
}

fn stBindName(b: u8) []const u8 {
    return switch (b) {
        0 => "LOCAL",
        1 => "GLOBAL",
        2 => "WEAK",
        else => "OTHER",
    };
}

fn formatShFlags(buf: *[3]u8, flags: u32) []const u8 {
    var i: usize = 0;
    if (flags & SHF_WRITE != 0) {
        buf[i] = 'W';
        i += 1;
    }
    if (flags & SHF_ALLOC != 0) {
        buf[i] = 'A';
        i += 1;
    }
    if (flags & SHF_EXECINSTR != 0) {
        buf[i] = 'X';
        i += 1;
    }
    return buf[0..i];
}

fn formatPhFlags(buf: *[3]u8, flags: u32) []const u8 {
    buf[0] = if (flags & PF_R != 0) 'R' else ' ';
    buf[1] = if (flags & PF_W != 0) 'W' else ' ';
    buf[2] = if (flags & PF_X != 0) 'E' else ' ';
    var len: usize = 3;
    while (len > 0 and buf[len - 1] == ' ') : (len -= 1) {}
    return buf[0..len];
}

fn sectionInSegment(sec: Section, prog: Program) bool {
    if (sec.flags & SHF_ALLOC == 0) return false;
    const start = sec.addr;
    const end = start + @max(sec.size, 1);
    const seg_start = prog.vaddr;
    const seg_end = seg_start + @max(prog.memsz, 1);
    if (start < seg_start or end > seg_end) return false;
    if (sec.sh_type != SHT_NOBITS) {
        const file_start = sec.offset;
        const file_end = file_start + @max(sec.size, 1);
        const seg_file_start = prog.offset;
        const seg_file_end = seg_file_start + @max(prog.filesz, 1);
        if (file_start < seg_file_start or file_end > seg_file_end) return false;
    }
    return true;
}

fn fileSize(path: []const u8) u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

fn sliceRange(data: []const u8, offset: u32, size: u32) ![]const u8 {
    const start: usize = @intCast(offset);
    const len: usize = @intCast(size);
    const end = try std.math.add(usize, start, len);
    if (end > data.len) return error.InvalidElfRange;
    return data[start..end];
}

fn findTopLevelElf(allocator: std.mem.Allocator, idf_dir: []const u8) ![]const u8 {
    var dir = try std.fs.cwd().openDir(idf_dir, .{ .iterate = true });
    defer dir.close();
    var candidate: ?[]const u8 = null;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".elf")) continue;
        if (std.mem.eql(u8, entry.name, "bootloader.elf")) continue;
        if (candidate != null) return error.MultipleElfFiles;
        candidate = try std.fs.path.join(allocator, &.{ idf_dir, entry.name });
    }
    return candidate orelse error.NoElfFound;
}

fn parseElf(allocator: std.mem.Allocator, path: []const u8) !struct {
    header: Elf32Header,
    sections: []Section,
    programs: []Program,
    data: []const u8,
} {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);

    if (data.len < @sizeOf(Elf32Header)) return error.TooSmall;
    if (!std.mem.eql(u8, data[0..4], "\x7fELF")) return error.NotElf;
    if (data[4] != 1 or data[5] != 1) return error.Not32BitLE;

    const hdr: *const Elf32Header = @ptrCast(@alignCast(data.ptr));

    const shstr_shdr_offset = hdr.e_shoff + @as(u32, hdr.e_shstrndx) * @as(u32, hdr.e_shentsize);
    const shstr_shdr: *const Elf32Shdr = @ptrCast(@alignCast(data.ptr + shstr_shdr_offset));
    const shstr_data = data[shstr_shdr.sh_offset .. shstr_shdr.sh_offset + shstr_shdr.sh_size];

    const sections = try allocator.alloc(Section, hdr.e_shnum);
    for (0..hdr.e_shnum) |i| {
        const off = hdr.e_shoff + @as(u32, @intCast(i)) * @as(u32, hdr.e_shentsize);
        const sh: *const Elf32Shdr = @ptrCast(@alignCast(data.ptr + off));
        sections[i] = .{
            .index = i,
            .name = readCString(shstr_data, sh.sh_name),
            .sh_type = sh.sh_type,
            .flags = sh.sh_flags,
            .addr = sh.sh_addr,
            .offset = sh.sh_offset,
            .size = sh.sh_size,
            .link = sh.sh_link,
            .info = sh.sh_info,
            .addralign = sh.sh_addralign,
            .entsize = sh.sh_entsize,
        };
    }

    const programs = try allocator.alloc(Program, hdr.e_phnum);
    for (0..hdr.e_phnum) |i| {
        const off = hdr.e_phoff + @as(u32, @intCast(i)) * @as(u32, hdr.e_phentsize);
        const ph: *const Elf32Phdr = @ptrCast(@alignCast(data.ptr + off));
        programs[i] = .{
            .index = i,
            .p_type = ph.p_type,
            .offset = ph.p_offset,
            .vaddr = ph.p_vaddr,
            .paddr = ph.p_paddr,
            .filesz = ph.p_filesz,
            .memsz = ph.p_memsz,
            .flags = ph.p_flags,
            .@"align" = ph.p_align,
        };
    }

    return .{ .header = hdr.*, .sections = sections, .programs = programs, .data = data };
}

fn symbolTableSection(sections: []const Section) ?Section {
    var fallback: ?Section = null;
    for (sections) |sec| {
        if (sec.sh_type == SHT_SYMTAB) return sec;
        if (sec.sh_type == SHT_DYNSYM and fallback == null) fallback = sec;
    }
    return fallback;
}

fn isCodeSection(sec: Section) bool {
    return sec.flags & SHF_ALLOC != 0 and sec.flags & SHF_EXECINSTR != 0;
}

fn shouldIncludeCodeSymbol(name: []const u8, typ: u8) bool {
    if (name.len == 0) return false;
    if (typ == STT_SECTION or typ == STT_FILE or typ == STT_OBJECT) return false;
    if (std.mem.startsWith(u8, name, ".L")) return false;
    if (name[0] == '$') return false;
    return typ == STT_FUNC or typ == STT_NOTYPE;
}

fn parseCodeSymbols(
    allocator: std.mem.Allocator,
    data: []const u8,
    sections: []const Section,
) ![]CodeSymbol {
    const symtab = symbolTableSection(sections) orelse return allocator.alloc(CodeSymbol, 0);
    if (symtab.entsize == 0) return allocator.alloc(CodeSymbol, 0);
    if (symtab.link >= sections.len) return error.InvalidSymbolStringTable;

    const strtab = sections[symtab.link];
    const symtab_data = try sliceRange(data, symtab.offset, symtab.size);
    const strtab_data = try sliceRange(data, strtab.offset, strtab.size);
    const entry_size: usize = @intCast(symtab.entsize);
    const count = symtab_data.len / entry_size;

    var out = std.ArrayList(CodeSymbol).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, count);
    var current_file_name: []const u8 = "";

    for (0..count) |i| {
        const off = i * entry_size;
        if (off + @sizeOf(Elf32Sym) > symtab_data.len) break;
        const sym: *const Elf32Sym = @ptrCast(@alignCast(symtab_data.ptr + off));
        const typ = sym.st_info & 0x0f;
        const bind = sym.st_info >> 4;

        if (typ == STT_FILE) {
            current_file_name = sourceModuleName(readCString(strtab_data, sym.st_name));
            continue;
        }

        if (sym.st_shndx == 0 or sym.st_shndx >= sections.len) continue;
        if (sym.st_size == 0) continue;

        const sec = sections[sym.st_shndx];
        if (!isCodeSection(sec)) continue;

        const name = readCString(strtab_data, sym.st_name);
        if (!shouldIncludeCodeSymbol(name, typ)) continue;

        try out.append(allocator, .{
            .name = name,
            .source_name = if (bind == 0) current_file_name else "",
            .section_name = sec.name,
            .value = sym.st_value,
            .size = sym.st_size,
            .bind = bind,
            .typ = typ,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn resolveModuleName(
    allocator: std.mem.Allocator,
    sym: CodeSymbol,
) !struct { name: []const u8, owned: bool } {
    const symbol_name = symbolModuleName(sym.name);
    if (sym.source_name.len != 0 and std.mem.eql(u8, sym.source_name, "zig_entry") and symbol_name.len != 0) {
        const base_name = topLevelModuleName(symbol_name);
        return .{
            .name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sym.source_name, base_name }),
            .owned = true,
        };
    }

    if (symbol_name.len != 0) return .{ .name = symbol_name, .owned = false };
    if (sym.source_name.len != 0) return .{ .name = sym.source_name, .owned = false };
    return .{ .name = sym.section_name, .owned = false };
}

const ModuleSummary = struct {
    stats: []ModuleStat,
    owned_names: [][]const u8,

    fn deinit(self: ModuleSummary, allocator: std.mem.Allocator) void {
        for (self.owned_names) |name| allocator.free(name);
        allocator.free(self.owned_names);
        allocator.free(self.stats);
    }
};

fn summarizeModules(allocator: std.mem.Allocator, code_symbols: []const CodeSymbol) !ModuleSummary {
    var module_indexes: std.StringHashMapUnmanaged(usize) = .{};
    defer module_indexes.deinit(allocator);

    var owned_names = std.ArrayList([]const u8).empty;
    errdefer {
        for (owned_names.items) |name| allocator.free(name);
        owned_names.deinit(allocator);
    }

    var out = std.ArrayList(ModuleStat).empty;
    errdefer out.deinit(allocator);

    for (code_symbols) |sym| {
        const resolved = try resolveModuleName(allocator, sym);
        const gop = try module_indexes.getOrPut(allocator, resolved.name);
        if (!gop.found_existing) {
            if (resolved.owned) try owned_names.append(allocator, resolved.name);
            gop.value_ptr.* = out.items.len;
            try out.append(allocator, .{
                .name = resolved.name,
                .total_size = sym.size,
                .symbol_count = 1,
            });
        } else {
            if (resolved.owned) allocator.free(resolved.name);
            const stat = &out.items[gop.value_ptr.*];
            stat.total_size += sym.size;
            stat.symbol_count += 1;
        }
    }

    const stats = try out.toOwnedSlice(allocator);
    errdefer allocator.free(stats);
    const names = try owned_names.toOwnedSlice(allocator);
    return .{
        .stats = stats,
        .owned_names = names,
    };
}

fn secSize(sections: []const Section, name: []const u8) u32 {
    for (sections) |sec| {
        if (std.mem.eql(u8, sec.name, name)) return sec.size;
    }
    return 0;
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn stripExt(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |pos| return name[0..pos];
    return name;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 5) {
        std.fs.File.stderr().writeAll("usage: elf_layout_golden <test_dir> <build_dir> <build_config> <bsp>\n") catch {};
        std.process.exit(1);
    }

    const test_dir = args[1];
    const build_dir = args[2];
    const build_config = args[3];
    const bsp = args[4];

    const idf_dir = try std.fs.path.join(allocator, &.{ test_dir, build_dir, "idf" });
    defer allocator.free(idf_dir);

    const elf_path = try findTopLevelElf(allocator, idf_dir);
    defer allocator.free(elf_path);

    const app_name = stripExt(basename(elf_path));
    const app_bin_name = try std.fmt.allocPrint(allocator, "{s}.bin", .{app_name});
    defer allocator.free(app_bin_name);
    const app_bin_path = try std.fs.path.join(allocator, &.{ idf_dir, app_bin_name });
    defer allocator.free(app_bin_path);
    const bootloader_bin_path = try std.fs.path.join(allocator, &.{ idf_dir, "bootloader", "bootloader.bin" });
    defer allocator.free(bootloader_bin_path);

    const elf = try parseElf(allocator, elf_path);
    defer allocator.free(elf.sections);
    defer allocator.free(elf.programs);
    defer allocator.free(elf.data);

    const code_symbols = try parseCodeSymbols(allocator, elf.data, elf.sections);
    defer allocator.free(code_symbols);
    std.sort.heap(CodeSymbol, code_symbols, {}, CodeSymbol.desc);

    const module_summary = try summarizeModules(allocator, code_symbols);
    defer module_summary.deinit(allocator);
    const module_stats = module_summary.stats;
    std.sort.heap(ModuleStat, module_stats, {}, ModuleStat.desc);

    var alloc_buf = try allocator.alloc(Section, elf.sections.len);
    defer allocator.free(alloc_buf);
    var alloc_count: usize = 0;
    for (elf.sections) |sec| {
        if (sec.index != 0 and sec.flags & SHF_ALLOC != 0) {
            alloc_buf[alloc_count] = sec;
            alloc_count += 1;
        }
    }
    const alloc_sections = alloc_buf[0..alloc_count];

    const profile = dirname(build_config);
    const iram_used = secSize(alloc_sections, ".iram0.vectors") + secSize(alloc_sections, ".iram0.text");
    var iram_reserved: u32 = 0;
    for (elf.programs) |prog| {
        for (alloc_sections) |sec| {
            if (sectionInSegment(sec, prog)) {
                if (std.mem.eql(u8, sec.name, ".iram0.vectors") or std.mem.eql(u8, sec.name, ".iram0.text")) {
                    iram_reserved = prog.memsz;
                    break;
                }
            }
        }
        if (iram_reserved != 0) break;
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const w = out.writer(allocator);
    try w.print("# {s} ELF layout golden\n", .{app_name});
    try w.print("# Built from: {s}\n", .{test_dir});
    try w.print("# Build profile: {s}\n", .{profile});
    try w.print("# Command inputs:\n", .{});
    try w.print("#   -Dbuild_config={s}\n", .{build_config});
    try w.print("#   -Dbsp={s}\n", .{bsp});
    try w.print("#\n", .{});
    try w.print("# Image size summary:\n", .{});
    try w.print("#   bootloader.bin: {} bytes\n", .{fileSize(bootloader_bin_path)});
    try w.print("#   {s}.bin: {} bytes\n", .{ app_name, fileSize(app_bin_path) });
    try w.print("#   IRAM used (.iram0.vectors + .iram0.text): {} bytes\n", .{iram_used});
    try w.print("#   IRAM reserved LOAD segment: {} bytes\n", .{iram_reserved});
    try w.print("#   Flash appdesc (.flash.appdesc): {} bytes\n", .{secSize(alloc_sections, ".flash.appdesc")});
    try w.print("#   Flash rodata (.flash.rodata): {} bytes\n", .{secSize(alloc_sections, ".flash.rodata")});
    try w.print("#   Flash text (.flash.text): {} bytes\n", .{secSize(alloc_sections, ".flash.text")});
    try w.print("#\n", .{});
    try w.print("# Capture source:\n", .{});
    try w.print("#   generated by lib/idf/tools/elf_layout.zig\n", .{});
    try w.print("\n", .{});
    try w.print("Elf file type is {s}\n", .{etName(elf.header.e_type)});
    try w.print("Entry point 0x{x:0>8}\n", .{elf.header.e_entry});
    try w.print("\n", .{});
    try w.print("Section Headers:\n", .{});
    try w.print("  [Nr] Name                Type      Addr     Off    Size   ES Flg Lk Inf Al\n", .{});

    for (alloc_sections) |sec| {
        var flags_buf: [3]u8 = undefined;
        const flags_str = formatShFlags(&flags_buf, sec.flags);
        try w.print("  [{d:2}] {s:<19} {s:<9} {x:0>8} {x:0>6} {x:0>6} {x:0>2} {s:>3} {d:2} {d:3} {d:2}\n", .{
            sec.index,
            sec.name,
            shtName(sec.sh_type),
            sec.addr,
            sec.offset,
            sec.size,
            sec.entsize,
            flags_str,
            sec.link,
            sec.info,
            sec.addralign,
        });
    }

    try w.print("\nCode Modules:\n", .{});
    if (module_stats.len == 0) {
        try w.print("  (no alloc+exec code modules found in symbol table)\n", .{});
    } else {
        try w.print("  TotalSize Symbols Module\n", .{});
        for (module_stats) |stat| {
            try w.print("  {d:>9} {d:>7} {s}\n", .{
                stat.total_size,
                stat.symbol_count,
                stat.name,
            });
        }
    }

    try w.print("\nTop Code Symbols:\n", .{});
    if (code_symbols.len == 0) {
        try w.print("  (no alloc+exec symbols with sizes found in symbol table)\n", .{});
    } else {
        try w.print("  Size     Addr     Bind   Type    Section             Symbol\n", .{});
        const limit = @min(code_symbols.len, top_code_symbol_limit);
        for (code_symbols[0..limit]) |sym| {
            try w.print("  {d:>8} 0x{x:0>8} {s:<6} {s:<7} {s:<19} {s}\n", .{
                sym.size,
                sym.value,
                stBindName(sym.bind),
                stTypeName(sym.typ),
                sym.section_name,
                sym.name,
            });
        }
        if (code_symbols.len > limit) {
            try w.print("  ... {} more symbols omitted\n", .{code_symbols.len - limit});
        }
    }

    try w.print("\nProgram Headers:\n", .{});
    try w.print("  Type      Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align\n", .{});

    for (elf.programs) |prog| {
        var flags_buf: [3]u8 = undefined;
        const flags_str = formatPhFlags(&flags_buf, prog.flags);
        try w.print("  {s:<9} 0x{x:0>6} 0x{x:0>8} 0x{x:0>8} 0x{x:0>5} 0x{x:0>5} {s:<3} 0x{x}\n", .{
            ptName(prog.p_type),
            prog.offset,
            prog.vaddr,
            prog.paddr,
            prog.filesz,
            prog.memsz,
            flags_str,
            prog.@"align",
        });
    }

    try w.print("\nSection to Segment mapping:\n", .{});
    try w.print("  Segment Sections...\n", .{});

    for (elf.programs) |prog| {
        var has_any = false;
        for (alloc_sections) |sec| {
            if (sectionInSegment(sec, prog)) {
                has_any = true;
                break;
            }
        }
        if (has_any) {
            try w.print("   {d:0>2}     ", .{prog.index});
            var first = true;
            for (alloc_sections) |sec| {
                if (sectionInSegment(sec, prog)) {
                    if (!first) try w.print(" ", .{});
                    try w.print("{s}", .{sec.name});
                    first = false;
                }
            }
            try w.print("\n", .{});
        }
    }

    const layout_path = try std.fs.path.join(allocator, &.{ test_dir, build_dir, "elf_layout.txt" });
    defer allocator.free(layout_path);

    std.fs.cwd().writeFile(.{ .sub_path = layout_path, .data = out.items }) catch |err| {
        std.debug.print("failed to write {s}: {}\n", .{ layout_path, err });
        std.process.exit(1);
    };

    std.fs.File.stdout().writeAll(out.items) catch {};
}
