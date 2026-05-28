/+ dub.sdl:
name "custom_key_demo"
dependency "dleveldb" path="../"
+/

module examples.custom_key_demo;

/**
 * 自定义 Key Demo
 * 
 * 演示如何使用 ulong 类型的 key
 * 包括自定义比较器、编码/解码函数
 * 
 * 使用方法:
 *   dub --single examples/custom_key_demo.d
 */

import std.stdio;
import std.file;
import std.path;
import std.conv;
import dleveldb.db;
import dleveldb.options;
import dleveldb.slice;
import dleveldb.comparator;
import dleveldb.write_batch;

/**
 * ulong 类型键比较器
 * 
 * 用于比较以大端序编码的 8 字节 ulong 键
 */
class UlongComparator : Comparator
{
    /// 获取比较器名称
    /// Returns: 比较器名称字符串，用于 MANIFEST 持久化标识
    string name() const
    {
        return "dleveldb.UlongComparator";
    }

    /// 比较两个 Slice 表示的 ulong 键
    /// Params: a = 第一个键
    /// Params: b = 第二个键
    /// Returns: 小于0表示a<b，等于0表示a==b，大于0表示a>b
    int compare(Slice a, Slice b) const nothrow @nogc
    {
        if (a.size() < 8 || b.size() < 8)
            return a.opCmp(b);

        ulong va = decodeUlong(a);
        ulong vb = decodeUlong(b);

        if (va < vb) return -1;
        if (va > vb) return 1;
        return 0;
    }

    /// 找最短分隔键（未实现）
    /// Params: start = 起始键
    /// Params: limit = 上限键
    void findShortestSeparator(ref Slice start, Slice limit) const
    {
    }

    /// 找短后继键（未实现）
    /// Params: key = 输入键
    void findShortSuccessor(ref Slice key) const
    {
    }

private:
    /// 解码 Slice 为 ulong（内部使用）
    /// Params: s = 8字节大端序编码的 Slice
    /// Returns: 解码后的 ulong 值
    static ulong decodeUlong(Slice s) nothrow @nogc
    {
        if (s.size() < 8)
            return 0;

        const(ubyte)* p = s.data();
        ulong result = 0;
        result |= cast(ulong)(p[0]) << 56;
        result |= cast(ulong)(p[1]) << 48;
        result |= cast(ulong)(p[2]) << 40;
        result |= cast(ulong)(p[3]) << 32;
        result |= cast(ulong)(p[4]) << 24;
        result |= cast(ulong)(p[5]) << 16;
        result |= cast(ulong)(p[6]) << 8;
        result |= cast(ulong)(p[7]);
        return result;
    }
}

/// 将 ulong 编码为大端序 8 字节 Slice
/// Params: value = 要编码的 ulong 值
/// Returns: 8字节大端序编码的 Slice
Slice encodeUlong(ulong value)
{
    ubyte[8] buf;
    buf[0] = cast(ubyte)(value >> 56);
    buf[1] = cast(ubyte)(value >> 48);
    buf[2] = cast(ubyte)(value >> 40);
    buf[3] = cast(ubyte)(value >> 32);
    buf[4] = cast(ubyte)(value >> 24);
    buf[5] = cast(ubyte)(value >> 16);
    buf[6] = cast(ubyte)(value >> 8);
    buf[7] = cast(ubyte)(value);
    return Slice(buf.dup);
}

/// 将大端序 8 字节 Slice 解码为 ulong
/// Params: s = 8字节大端序编码的 Slice
/// Returns: 解码后的 ulong 值，若长度不足8则返回0
ulong decodeUlong(Slice s)
{
    if (s.size() < 8)
        return 0;

    const(ubyte)* p = s.data();
    ulong result = 0;
    result |= cast(ulong)(p[0]) << 56;
    result |= cast(ulong)(p[1]) << 48;
    result |= cast(ulong)(p[2]) << 40;
    result |= cast(ulong)(p[3]) << 32;
    result |= cast(ulong)(p[4]) << 24;
    result |= cast(ulong)(p[5]) << 16;
    result |= cast(ulong)(p[6]) << 8;
    result |= cast(ulong)(p[7]);
    return result;
}

void main()
{
    version (Windows)
    {
        import core.sys.windows.windows;
        SetConsoleOutputCP(65001);
        SetConsoleCP(65001);
    }

    writeln("╔══════════════════════════════════════════╗");
    writeln("║      自定义 Key (ulong) 使用示例         ║");
    writeln("╚══════════════════════════════════════════╝");
    writeln();

    auto dbPath = buildPath("temp", "custom_key_db");
    if (exists(dbPath))
        rmdirRecurse(dbPath);

    auto opt = Options();
    opt.createIfMissing = true;
    opt.comparator = new UlongComparator();

    auto db = new LevelDB(opt, dbPath);
    scope (exit)
    {
        db.close();
        if (exists(dbPath))
            rmdirRecurse(dbPath);
    }

    writeln("数据库路径: ", dbPath);
    writeln("使用自定义比较器: UlongComparator");
    writeln();

    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("1. 写入 ulong key 数据");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    ulong[] testKeys = [1, 100, 999, 1000, 5000, 9999, 10000];
    foreach (key; testKeys)
    {
        string value = "value_for_" ~ key.to!string;
        auto keySlice = encodeUlong(key);
        db.put(keySlice, value);
        writeln("  写入 key=", key, " → ", value);
    }

    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("2. 读取 ulong key 数据");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    foreach (key; testKeys)
    {
        auto keySlice = encodeUlong(key);
        string value;
        if (db.get(keySlice, value))
        {
            writeln("  读取 key=", key, " → ", value);
        }
        else
        {
            writeln("  ✗ key=", key, " 未找到");
        }
    }

    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("3. 测试迭代器遍历 (按 ulong 顺序)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    auto iter = db.iterator();
    iter.seekToFirst();

    writeln("  所有键值对 (按 ulong 升序):");
    while (iter.valid())
    {
        auto keySlice = iter.key();
        auto valueSlice = iter.value();
        ulong key = decodeUlong(keySlice);
        string value = valueSlice.toString();
        writeln("    key=", key, " → ", value);
        iter.next();
    }

    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("4. 测试 Seek 操作 (找第一个 >= key 的元素)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    ulong seekKey = 1000;
    auto seekSlice = encodeUlong(seekKey);
    iter.seek(seekSlice);

    if (iter.valid())
    {
        auto foundKey = decodeUlong(iter.key());
        auto foundValue = iter.value().toString();
        writeln("  Seek(", seekKey, ") → key=", foundKey, " (精确匹配)");
    }
    else
    {
        writeln("  Seek(", seekKey, ") 未找到");
    }

    seekKey = 500;
    seekSlice = encodeUlong(seekKey);
    iter.seek(seekSlice);

    if (iter.valid())
    {
        auto foundKey = decodeUlong(iter.key());
        auto foundValue = iter.value().toString();
        writeln("  Seek(", seekKey, ") → key=", foundKey, " (第一个 >= 500 的 key)");
    }
    else
    {
        writeln("  Seek(", seekKey, ") 未找到");
    }

    seekKey = 10000;
    seekSlice = encodeUlong(seekKey);
    iter.seek(seekSlice);

    if (iter.valid())
    {
        auto foundKey = decodeUlong(iter.key());
        auto foundValue = iter.value().toString();
        writeln("  Seek(", seekKey, ") → key=", foundKey);
    }
    else
    {
        writeln("  Seek(", seekKey, ") 未找到 (超出最大 key)");
    }

    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("5. 删除测试");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    ulong delKey = 999;
    auto delSlice = encodeUlong(delKey);
    db.remove(delSlice);
    writeln("  已删除 key=", delKey);

    string value;
    if (!db.get(delSlice, value))
    {
        writeln("  ✓ key=", delKey, " 已被删除");
    }

    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("6. 批量写入测试");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    auto batch = new WriteBatch();
    foreach (i; 0 .. 100)
    {
        ulong key = 10000 + i;
        string batchValue = "batch_value_" ~ key.to!string;
        auto keySlice = encodeUlong(key);
        batch.put(keySlice, Slice(batchValue.dup));
    }
    db.write(batch);
    writeln("  批量写入 100 条记录");

    size_t count = 0;
    iter.seekToFirst();
    while (iter.valid())
    {
        count++;
        iter.next();
    }
    writeln("  当前总记录数: ", count);

    writeln();
    writeln("自定义 Key Demo 完成！");
}
