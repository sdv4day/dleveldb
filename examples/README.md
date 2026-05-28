# D 语言示例代码

本目录包含符合 [Dlang_SP.md](../.lingma/rules/Dlang_SP.md) 规范的示例代码。

## 示例列表

### 1. CTFE 示例 (`ctfe_demo.d`)

演示编译时求值（Compile-Time Function Execution）的使用。

**特性**:
- 编译时生成查找表
- 编译时字符串处理
- 编译时数学计算
- 编译时数组操作

**运行方式**:
```bash
# 作为独立脚本运行
dub --single examples/ctfe_demo.d

# 或者编译后运行
dub run --compiler=ldc2 examples/ctfe_demo.d
```

**学习要点**:
- 如何使用 `pure` 函数进行 CTFE
- `immutable` vs `enum` 的区别
- CTFE 的性能优势（运行时零开销）

---

### 2. 模板示例 (`template_demo.d`)

演示模板元编程和 `static if` 的使用。

**特性**:
- 使用 `static if` 进行类型分支
- 模板约束（`if` 表达式）
- 可变参数模板
- 使用 `traits` 进行编译时检查

**运行方式**:
```bash
dub --single examples/template_demo.d
```

**学习要点**:
- `static if` vs 运行时 `if`
- 模板约束的语法和用途
- 可变参数模板的递归展开
- `__traits` 的使用

---

### 3. 独立测试示例 (`standalone_test.d`)

演示如何使用 `dub --single` 运行独立的测试脚本。

**特性**:
- 文件头部包含 dub 配置注释
- 自动依赖解析
- 完整的单元测试
- 无需项目配置文件

**运行方式**:
```bash
dub --single examples/standalone_test.d
```

**学习要点**:
- `dub --single` 的使用方法
- 在 `.d` 文件中嵌入 dub 配置
- 独立测试脚本的最佳实践

---

## 规范符合性

所有示例都严格遵循 [Dlang_SP.md](../.lingma/rules/Dlang_SP.md) 规范：

✅ **项目管理**: 使用 dub 包管理器  
✅ **CTFE**: 优先使用编译时求值  
✅ **模板**: 使用 `static if` 而非 mixin  
✅ **单元测试**: 每个示例都有完整的单元测试  
✅ **独立测试**: 展示 `dub --single` 用法  
✅ **代码质量**: 使用 `pure`、`@safe`、`@nogc` 等属性  

---

## 快速开始

### 运行所有示例

```bash
# CTFE 示例
dub --single examples/ctfe_demo.d

# 模板示例
dub --single examples/template_demo.d

# 独立测试示例
dub --single examples/standalone_test.d
```

### 运行单元测试

```bash
# 为每个示例运行测试
dub test --compiler=dmd examples/ctfe_demo.d
dub test --compiler=dmd examples/template_demo.d
dub test --compiler=dmd examples/standalone_test.d
```

---

## 学习资源

- [D 语言官方文档](https://dlang.org/)
- [Dlang_SP.md 规范](../.lingma/rules/Dlang_SP.md)
- [dleveldb 项目文档](../)

---

## 贡献

欢迎提交更多示例代码！请确保：

1. 符合 Dlang_SP.md 规范
2. 包含完整的单元测试
3. 有清晰的注释和文档
4. 展示 D 语言的独特特性
