# Mbedz CodeReview CoC

这个文档中的章节、规则和 example，优先引用 `embed-zig-example/` 里的真实文件作为证明和索引，而不是引用本机路径或只给抽象规则。

这个文档中出现的 `embed-zig-example/...` 相对路径，都应该相对于当前 `CODE_OF_CONDUCT.md` 所在目录解析，而不是相对于用户当前 worktree 根目录或 shell cwd 解析。

## ToC

1. naming convention
2. Import 规则
3. Function Order 规则
4. 项目结构
5. patterns
6. MUST / MUST NOT / MAY

## 1. naming convention

### 1.1 variable names

- 函数使用 `camelCase`
- 类型使用 `PascalCase`
- 变量使用 `snake_case`
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

### 1.2 file names

- 对于 namespace，使用 `snake_case.zig`
- 对于 file-as-struct，使用 `PascalCase.zig`
- 参考 example：`embed-zig-example/lib/petstore.zig`、`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

### 1.3 function names

- 函数使用 `camelCase`
- 使用 `make` 来构造一个 type，例如：`Pet.make(Impl)`
- 使用 `init` 来初始化一个 type 的实例，例如：`PetStore.init`
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

## 2. Import 规则

### 2.1 import order

- 先写 package import，例如：`const dep = @import("dep");`
- 如果需要，再从 package namespace 中取子 namespace，例如：`const embed = dep.embed;`
- 再写本地文件 import，例如：`const Pet = @import("Pet.zig");`
- 在 import 之后，再写 `const PetStore = @This();`
- 参考 example：`embed-zig-example/lib/petstore/PetStore.zig`

### 2.2 use embed instead of std

- 不应该直接依赖 `std`，而应该使用 `embed`
- 在 example 项目里，通常通过 `dep.embed` 使用 `embed`
- `embed` 是 `std` 的一个 subset drop-in replacement
- 参考 example：`embed-zig-example/pkg/dep.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

如果 `embed` 没有提供对应的方法，有三种解决方式：

1. 在 `embed` 中 re-export `std` 的结构
2. 在 `embed` 中重新实现一个 `std` 的结构
3. 使用 `make a type` pattern，利用 `make`，传入一个 `comptime` 的 `std` namespace

### 2.3 external dependencies

- 外部依赖如果来自 GitHub，应该使用 `codeload.github.com` 下载 tar
- 参考 example：`embed-zig-example/build.zig.zon`

### 2.4 example

```zig
const dep = @import("dep");
const embed = dep.embed;
const Pet = @import("Pet.zig");

const PetStore = @This();
```

这个 example 对应：`embed-zig-example/lib/petstore/PetStore.zig`

## 3. Function Order 规则

- 文件的主要的 `pub` 函数
- 其他 `pub` 函数
- 内部函数
- `pub` 的 `TestRunner` 函数
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

## 4. 项目结构

### 4.1 Build

- `/build/`
- `/build.zig`
- `/build.zig.zon`
- `build/` 是一个目录，包括 `module`、`pkg` 和测试的 build 脚本
- 顶层的 `build.zig` 提供输出
- `build.zig.zon` 用来声明依赖
- 参考 example：`embed-zig-example/build.zig`、`embed-zig-example/build.zig.zon`、`embed-zig-example/build/lib/petstore.zig`、`embed-zig-example/build/pkg/dep.zig`、`embed-zig-example/build/pkg/stb_truetype.zig`、`embed-zig-example/build/tests.zig`

### 4.2 lib 和 pkg

- `lib` 和 `pkg` 都是 zig module
- `pkg` 一般是平台相关的、optional 编译的、c library，或者外部依赖的 module
- `lib` 是项目自己的纯 zig module
- 项目中可以有 `lib/` 目录，用来放自己的多个 libs
- 项目中可以有 `pkg/` 目录，用来放自己的多个 pkgs
- 参考 example：`embed-zig-example/lib/petstore.zig`、`embed-zig-example/pkg/dep.zig`、`embed-zig-example/pkg/stb_truetype.zig`

### 4.3 代码组织

- 通常使用这种方式来组织代码：
- `thread/`：这里是这个功能分区的细节实现
- `Thread.zig`：这里是聚合输出
- 聚合输出可以是一个 file-as-struct，也可以是一个 namespace
- 参考 example：`embed-zig-example/lib/petstore.zig`、`embed-zig-example/lib/petstore/`

### 4.4 testing

#### 4.4.1 test blocks

- 这里的 `test blocks` 指的是 Zig 的 `test "xxx" {}` 顶层测试块
- 项目中的 `test blocks` 只能出现在 `lib/tests.zig` 和 `pkg/{pkg}.zig` 文件中
- 其他文件不能有 `test blocks`
- 文件内的 test 逻辑应该包装到唯一的一个 `TestRunner` 中，以便让 `unit.zig` 可以统一调用和测试
- 其他 zig 文件如果需要测试，应该通过 `TestRunner` 暴露给 `lib/tests.zig` 或 `pkg/{pkg}.zig` 来统一运行
- 这样做的主要目的是让所有测试可以在不同平台运行，而不是只能在 host 本机运行
- 参考 example：`embed-zig-example/lib/tests.zig`、`embed-zig-example/pkg/stb_truetype.zig`

#### 4.4.2 module 级别的测试

- `module test runner`：模块级别的 `test runner`
- 应用于 `lib` 和 `pkg`
- `test_runner` 下面应该只有四种结构：

```text
test_runner/integration/
test_runner/integration.zig

test_runner/unit/
test_runner/unit.zig

test_runner/benchmark/
test_runner/benchmark.zig

test_runner/cork/
test_runner/cork.zig
```

- `test_runner` 下不应该有其他文件
- 参考 example：`embed-zig-example/lib/petstore/test_runner/unit.zig`、`embed-zig-example/lib/petstore/test_runner/integration.zig`、`embed-zig-example/lib/petstore/test_runner/benchmark.zig`、`embed-zig-example/lib/petstore/test_runner/cork.zig`、`embed-zig-example/pkg/stb_truetype/test_runner/unit.zig`

#### 4.4.3 测试夹具放在哪

- `test_utils` 用来放测试辅助工具和 harness
- `test_utils` 可以写在 `test_runner/test_utils`
- 也可以写在 `test_runner/<type>/test_utils`
- 参考 example：`embed-zig-example/lib/petstore/test_runner/test_utils/MockPet.zig`

#### 4.4.4 单元测试（文件测试）放在哪

- unit 测试只适用于纳入 unit testing 范畴的文件
- 有些文件可以没有 unit 测试，也可以没有 `TestRunner`；这些文件不纳入 unit 测试的范畴
- 对于纳入 unit testing 范畴的文件，unit 测试就是文件级别测试，应该和代码文件 `1:1` 对应
- unit 测试不应该引入任何新增的测试文件；如果为了测试新增了额外文件，这些应归到集成测试而不是 unit 测试
- 对于纳入 unit testing 范畴的文件，unit 测试文件名的大小写需要和对应代码文件保持一致
- 对于纳入 unit testing 范畴的文件，`TestRunner` 按照 `Function Order` 的顺序放在文件最下面
- 对于纳入 unit testing 范畴的文件，`TestRunner` 需要的所有 import、函数和变量，都应该封装在 `TestRunner` 函数里
- 对于纳入 unit testing 范畴的文件，文件级单元测试需要的辅助函数有且只能定义在 `TestRunner` 这个大函数内部，不能定义在全局
- 对于纳入 unit testing 范畴的文件，文件级单元测试需要的 `std` 引用也必须封装在 `TestRunner` 内部，不能出现在文件全局
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

### 4.5 example

#### 4.5.1 project

```text
embed-zig-example/
├── build.zig
├── build.zig.zon
├── build/
│   ├── lib/petstore.zig
│   ├── pkg/dep.zig
│   ├── pkg/stb_truetype.zig
│   └── tests.zig
├── lib/
│   ├── tests.zig
│   ├── petstore.zig
│   └── petstore/
│       ├── Pet.zig
│       ├── PetStore.zig
│       └── test_runner/
│           ├── unit.zig
│           ├── unit/
│           │   ├── pet.zig
│           │   └── pet_store.zig
│           ├── integration.zig
│           ├── integration/
│           │   └── petstore.zig
│           ├── benchmark.zig
│           ├── benchmark/
│           │   └── petstore.zig
│           ├── cork.zig
│           ├── cork/
│           │   └── petstore.zig
│           └── test_utils/
│               └── MockPet.zig
└── pkg/
    ├── dep.zig
    ├── dep/
    │   └── README.md
    ├── stb_truetype.zig
    └── stb_truetype/
        ├── src/
        │   ├── Font.zig
        │   ├── binding.zig
        │   └── types.zig
        └── test_runner/
            ├── unit.zig
            └── unit/
                └── font.zig
```

- `embed-zig-example/build.zig` 在顶层提供输出
- `embed-zig-example/build.zig.zon` 使用 codeload 声明 `embed-zig` 的 GitHub 依赖
- `embed-zig-example/build/lib/*.zig` 和 `build/pkg/*.zig` 使用 `create` / `link` 的 build pattern
- `embed-zig-example/build/` 中放 build 相关脚本
- `embed-zig-example/lib/` 中只放项目自己的纯 zig modules，这里只有 `petstore`
- `embed-zig-example/pkg/` 中放平台相关、optional、c library 或外部依赖的 modules
- `embed-zig-example/pkg/dep.zig` 用来统一 re-export 依赖
- `embed-zig-example/lib/tests.zig` 是 lib 级别测试聚合入口
- `embed-zig-example/lib/petstore.zig` 是 module 入口和聚合输出
- `embed-zig-example/lib/petstore/Pet.zig` 和 `PetStore.zig` 是模块内文件
- `embed-zig-example/lib/petstore/test_runner/` 展示 module 级别测试组织方式

#### 4.5.2 file_test_runner.zig

- 文件级别的测试可以直接写在对应的 zig 文件里
- `Pet.zig` 和 `PetStore.zig` 都可以提供 `pub fn TestRunner(comptime std: type) dep.testing.TestRunner`
- 文件内的单元测试代码仍然放在文件底部
- `TestRunner` 负责把这个文件里的测试统一导出为一个文件级 test runner
- 对应 example：`embed-zig-example/lib/petstore/Pet.zig`、`embed-zig-example/lib/petstore/PetStore.zig`

```zig
pub fn TestRunner(comptime std: type) @import("dep").testing.TestRunner {
    const testing_api = @import("dep").testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            // run file-local test cases here
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
```

#### 4.5.3 module 入口导出 test_runner namespace

- module 入口文件统一导出 `test_runner` namespace
- 最后由 module 的 `test_runner` 的 `unit` 测试入口统一导出
- 这里可以参考 `embed-zig-example/lib/petstore.zig`

```zig
pub const test_runner = struct {
    pub const unit = @import("petstore/test_runner/unit.zig");
    pub const integration = @import("petstore/test_runner/integration.zig");
    pub const benchmark = @import("petstore/test_runner/benchmark.zig");
    pub const cork = @import("petstore/test_runner/cork.zig");
};
```

## 5. patterns

### 5.1 make a type

- 使用 `make` 来构造一个类型
- `make` 中建议直接给一个 `comptime` block
- 在这个 `comptime` block 中检查传入的 `Impl` 是否符合要求
- 可以使用 `@as(...)` 的方式检查函数签名
- 如果第一个参数是 `std` namespace，那么这个参数应该写成 `comptime std: type`
- 对于这个 `std` namespace 参数，不需要使用 `comptime` block 去检查函数签名
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`

### 5.2 make a VTable type

- 这是 `Pet.zig` 的 pattern
- 一个 `VTable` 文件通过 `make` 返回一个构造类
- 通过 `init` 返回一个 erased type 的 `VTable` 类型
- 建议把 `VTable` 的具体构造直接写在 `make` 内部
- 参考 example：`embed-zig-example/lib/petstore/Pet.zig`

## 6. MUST / MUST NOT / MAY

MUST: 在 review 中优先使用 `embed-zig-example/` 里的真实文件作为证明和索引。
MUST: 函数使用 `camelCase`。
MUST: 类型使用 `PascalCase`。
MUST: 变量使用 `snake_case`。
MUST: namespace 文件使用 `snake_case.zig`。
MUST: file-as-struct 文件使用 `PascalCase.zig`。
MUST: package import 写在本地文件 import 之前。
MUST: `@This()` 写在 import 之后。
MUST: GitHub 外部依赖通过 `codeload.github.com` 下载 tar。
MUST: 文件的主要 `pub` 函数写在其他函数之前。
MUST: `TestRunner` 按 `Function Order` 放在文件最下面。
MUST: `build/`、`build.zig`、`build.zig.zon` 按项目结构规则组织。
MUST: `lib` 和 `pkg` 按模块职责组织。
MUST: `test blocks` 只能出现在 `lib/tests.zig` 和 `pkg/{pkg}.zig`。
MUST: 文件内的 test 逻辑包装到唯一的一个 `TestRunner` 中。
MUST: 其他 zig 文件通过 `TestRunner` 暴露给测试入口统一运行。
MUST: `test_runner` 只保留 `integration`、`unit`、`benchmark`、`cork` 四种结构。
MUST: 对于纳入 unit testing 范畴的文件，unit 测试和代码文件 `1:1` 对应。
MUST: 对于纳入 unit testing 范畴的文件，unit 测试文件名的大小写和对应代码文件保持一致。
MUST: 对于纳入 unit testing 范畴的文件，`TestRunner` 放在文件最下面。
MUST: 对于纳入 unit testing 范畴的文件，文件级单元测试需要的辅助函数定义在 `TestRunner` 内部。
MUST: 对于纳入 unit testing 范畴的文件，文件级单元测试需要的 `std` 引用封装在 `TestRunner` 内部。
MUST NOT: 在其他文件中写顶层 `test "xxx" {}`。
MUST NOT: 直接依赖 `std`，当规则要求 `embed` 时应改用 `embed`。
MUST NOT: 为 unit 测试新增额外测试文件；这类新增文件应归为集成测试。
MUST NOT: 对于纳入 unit testing 范畴的文件，在文件全局定义单元测试辅助函数。
MUST NOT: 对于纳入 unit testing 范畴的文件，在文件全局写单元测试需要的 `std` 引用。
MUST NOT: 在 `test_runner` 下放除四种结构和允许的 `test_utils` 之外的其他文件。
MUST NOT: 依赖本机私有路径来证明规则。
MAY: 有些文件没有 unit 测试，也没有 `TestRunner`。
MAY: 通过 `dep.embed` 使用 `embed`。
MAY: 当 `embed` 缺少能力时，在 `embed` 中 re-export `std` 的结构。
MAY: 当 `embed` 缺少能力时，在 `embed` 中重新实现对应的 `std` 结构。
MAY: 使用 `make a type` pattern 传入 `comptime` 的 `std` namespace。
MAY: 聚合输出实现成 file-as-struct。
MAY: 聚合输出实现成 namespace。
MAY: 在 `test_runner/test_utils` 放测试辅助工具和 harness。
MAY: 在 `test_runner/<type>/test_utils` 放测试辅助工具和 harness。
MAY: 在适用场景下使用 `make` pattern。
MAY: 在适用场景下使用 VTable pattern。