/**
 * LevelDB 核心数据库类定义
 *
 * 这是dleveldb库的主要用户接口，提供泛型的键值存储操作。
 * 
 * Copyright: BSL-1.0
 * Authors: sdv
 * Date: 2024
 */
module dleveldb.db;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.iterator;
import dleveldb.write_batch;
import dleveldb.snapshot;
import dleveldb.comparator;
import dleveldb.env;
import dleveldb.exceptions;
import dleveldb.db_impl;

import std.traits;

/**
 * LevelDB 核心数据库类
 * 
 * 提供泛型 put/get/del/find/get_slice 接口
 * 底层实现委托给 DBImpl
 * 
 * 关联数组风格操作：
 * ---
 * auto db = new LevelDB("mydb");
 * auto aa = db.aa;  // 获取关联数组操作接口
 * 
 * // 操作符语法
 * aa["key"] = "value";       // 设置值
 * auto val = aa["key"];       // 获取值
 * if ("key" in aa) { }        // 检查键存在
 * 
 * // AA 标准方法
 * auto count = aa.length;
 * auto keys = aa.keys;
 * aa.clear();
 * ---
 */
final class LevelDB
{
private:
    DBImpl m_impl;
    bool m_isOpen = false;
    LevelDBAA m_aa;

public:
    this()
    {
    }

    this(string dbpath)
    {
        auto opt = Options();
        open(opt, dbpath);
    }

    this(Options opt, string dbpath)
    {
        open(opt, dbpath);
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    /// 打开数据库
    void open(Options opt, string dbpath)
    {
        if (m_isOpen)
            close();

        m_impl = new DBImpl(opt, dbpath);
        Status s = m_impl.open();
        if (!s.ok())
        {
            import std.logger;
            warning("Failed to open database at ", dbpath, ": ", s.toString());
            throw new LeveldbException(s);
        }
        m_isOpen = true;
        import std.logger;
        info("Database opened successfully at ", dbpath);
    }

    /// 判断数据库是否打开
    @property bool isOpen() const pure nothrow @safe @nogc { return m_isOpen; }

    /**
     * 获取关联数组操作接口
     * 
     * 返回 LevelDBAA 实例，提供关联数组风格操作：
     * - aa["key"] = value   设置值
     * - aa["key"]           获取值
     * - "key" in aa         检查键存在
     * - aa["key"] ~= value  追加值
     * - aa.length           键值对数量
     * - aa.keys / aa.values 所有键/值
     * - aa.clear()          清空数据库
     */
    @property LevelDBAA aa()
    {
        if (m_aa is null)
            m_aa = new LevelDBAA(this);
        return m_aa;
    }

    /// 关闭数据库
    void close()
    {
        if (m_isOpen && m_impl !is null)
        {
            m_impl.close();
            m_impl = null;
            m_isOpen = false;
            m_aa = null;
        }
    }

    /**
     * 写入键值对（泛型）
     * 
     * 支持任意可序列化为 Slice 的类型
     * 示例：
     *   db.put("key", "value");
     *   db.put("key", 42);
     *   db.put(Slice("key"), Slice.owned(3.14));
     */
    void put(K, V)(in K key, in V value, const(WriteOptions) opt = WriteOptions())
    {
        checkOpen();
        auto s = m_impl.put(opt, toSliceKey(key), toSlice(value));
        if (!s.ok())
            throw new LeveldbException(s);
    }

    /**
     * 读取键值（泛型）
     * 
     * Returns: 是否找到
     * 示例：
     *   string val;
     *   if (db.get("key", val)) { ... }
     */
    bool get(K, V)(in K key, out V value, const(ReadOptions) opt = ReadOptions())
        if (!is(V == interface))
    {
        checkOpen();
        ubyte[] buf;
        auto s = m_impl.get(opt, toSliceKey(key), buf);
        if (!s.ok())
        {
            if (s.isNotFound())
                return false;
            throw new LeveldbException(s);
        }

        value = fromSlice!V(Slice(cast(const(ubyte)*) buf.ptr, buf.length));
        return true;
    }

    /**
     * 删除键（泛型）
     */
    void del(K)(in K key, const(WriteOptions) opt = WriteOptions())
    {
        checkOpen();
        auto s = m_impl.remove(opt, toSliceKey(key));
        if (!s.ok())
            throw new LeveldbException(s);
    }

    /**
     * 查找键值，不存在返回默认值（泛型）
     */
    V find(K, V)(in K key, V def, const(ReadOptions) opt = ReadOptions())
        if (!is(V == interface))
    {
        V value;
        if (get(key, value, opt))
            return value;
        return def;
    }

    /**
     * 获取键值的 Slice（不拷贝）
     * 
     * 注意：返回的 Slice 引用 GC 管理的内存，调用者应立即使用
     * 或通过 .dup 拷贝，不应长期持有。
     */
    auto getSlice(K)(in K key, const(ReadOptions) opt = ReadOptions())
    {
        checkOpen();
        ubyte[] buf;
        auto s = m_impl.get(opt, toSliceKey(key), buf);
        if (!s.ok())
        {
            if (s.isNotFound())
                return Slice();
            throw new LeveldbException(s);
        }
        return Slice(cast(const(ubyte)*) buf.ptr, buf.length);
    }

    /// 批量写
    void write(const(WriteBatch) batch, const(WriteOptions) opt = WriteOptions())
    {
        checkOpen();
        auto s = m_impl.write(opt, cast(WriteBatch) batch);
        if (!s.ok())
            throw new LeveldbException(s);
    }

    /// 获取快照
    @property const(Snapshot) snapshot()
    {
        checkOpen();
        return m_impl.getSnapshot();
    }

    /// 释放快照
    void releaseSnapshot(const(Snapshot) snap)
    {
        checkOpen();
        m_impl.releaseSnapshot(snap);
    }

    /// 创建迭代器
    Iterator iterator(const(ReadOptions) opt = ReadOptions())
    {
        checkOpen();
        return m_impl.newIterator(opt);
    }

    /// 压缩指定范围
    void compactRange(Slice begin, Slice end)
    {
        checkOpen();
        m_impl.compactRange(begin, end);
    }

    /**
     * 删除键：db.remove("key")
     * 
     * 示例：
     *   db.remove("key");
     */
    void remove(K)(K key)
    {
        del(key);
    }

    /**
     * 检查键是否存在
     * 
     * 示例：
     *   if (db.contains("key")) { ... }
     */
    bool contains(K)(K key)
    {
        return !getSlice(key).empty();
    }

    /**
     * 获取值或默认值：db.getOr("key", "default")
     * 
     * 示例：
     *   auto val = db.getOr("key", "default");
     */
    V getOr(K, V)(K key, V def)
    {
        return find(key, def);
    }

    /**
     * 获取值或计算默认值：db.getOr!"key"(() => expensiveDefault())
     * 
     * 示例：
     *   auto val = db.getOrCompute("key", () => computeDefault());
     */
    V getOrCompute(K, V)(K key, V delegate() compute)
    {
        V value;
        if (get(key, value))
            return value;
        return compute();
    }

    /// 销毁数据库
    static void destroyDB(Options opt, string dbpath)
    {
        import std.file : exists, rmdirRecurse;

        string dir = dbpath;
        if (dir.exists())
            dir.rmdirRecurse();
    }

    /// 修复数据库（简化实现：尝试打开）
    static void repairDB(Options opt, string dbpath)
    {
        auto repairOpt = opt;
        repairOpt.createIfMissing = true;
        auto db = new LevelDB(repairOpt, dbpath);
        db.close();
    }

private:
    void checkOpen() const
    {
        if (!m_isOpen)
            throw new LeveldbException("Not connected to a valid db");
    }

    /// 将任意类型转换为 Slice
    /// 返回的Slice在下次调用toSlice前有效（TLS缓冲区）
    static auto toSlice(T)(auto ref const T val)
    {
        static if (is(T == Slice))
        {
            return val;
        }
        else static if (__traits(compiles, OwnedSlice!int) && is(T : OwnedSlice!U, U))
        {
            // 已经是 OwnedSlice，直接返回其 slice
            return val.slice;
        }
        else static if (isSomeString!T)
        {
            return Slice(val);
        }
        else static if (isDynamicArray!T)
        {
            import std.range.primitives : ElementEncodingType;
            static if (is(ElementEncodingType!T == ubyte) || is(ElementEncodingType!T == const(ubyte)))
            {
                return Slice(val);
            }
            else static if (is(ElementEncodingType!T == char) || is(ElementEncodingType!T == const(char)))
            {
                return Slice(val);
            }
            else
            {
                return Slice(cast(const(void*)) val.ptr, val.length * ElementEncodingType!T.sizeof);
            }
        }
        else static if (isPointer!T)
        {
            import std.traits : PointerTarget;
            return Slice(cast(const(void*)) val, PointerTarget!T.sizeof);
        }
        else
        {
            // 基本类型和POD结构体：使用 Slice.owned 安全存储
            return Slice.owned(val);
        }
    }
    
    /// 将任意类型转换为 Slice（使用独立的存储，用于key）
    /// 与toSlice使用不同的存储，避免put(key,value)时覆盖
    static auto toSliceKey(T)(auto ref const T val)
    {
        static if (is(T == Slice))
        {
            return val;
        }
        else static if (__traits(compiles, OwnedSlice!int) && is(T : OwnedSlice!U, U))
        {
            // 已经是 OwnedSlice，直接返回其 slice
            return val.slice;
        }
        else static if (isSomeString!T || isDynamicArray!T || isPointer!T)
        {
            return toSlice(val);
        }
        else
        {
            // 使用 Slice.owned 安全存储 key
            return Slice.owned(val);
        }
    }

    /// 从 Slice 转换为目标类型
    static V fromSlice(V)(Slice s)
    {
        static if (isSomeString!V)
        {
            return s.asString().idup;
        }
        else static if (isDynamicArray!V && !is(V == class))
        {
            import std.range.primitives : ElementEncodingType;
            auto result = new V(s.length / ElementEncodingType!V.sizeof);
            result[] = (cast(ElementEncodingType!V[]) s.asBytes())[0 .. result.length];
            return result;
        }
        else static if (isSliceSerializable!V)
        {
            if (V.sizeof > s.size())
                throw new LeveldbException("Slice size too small for type " ~ V.stringof);
            return s.as!V;
        }
        else
        {
            throw new LeveldbException("Type " ~ V.stringof ~ " is not slice-serializable");
        }
    }
}

/**
 * 关联数组风格操作包装器
 * 
 * 参考 D 语言关联数组规范：https://dlang.org/spec/hash-map.html
 * 
 * 使用方法：
 * ---
 * auto db = new LevelDB("mydb");
 * auto aa = db.aa;  // 获取关联数组操作接口
 * 
 * // 操作符语法
 * aa["key"] = "value";       // 设置值
 * auto val = aa["key"];       // 获取值
 * if ("key" in aa) { }        // 检查键存在
 * 
 * // AA 标准方法
 * auto count = aa.length;
 * auto keys = aa.keys;
 * aa.clear();
 * ---
 */
final class LevelDBAA
{
private:
    LevelDB db_;

public:
    /**
     * 构造关联数组操作包装器
     * 
     * 参数：
     *   db - LevelDB 数据库实例
     */
    this(LevelDB db)
    {
        db_ = db;
    }

    // ============================================================
    // 操作符重载
    // ============================================================

    /**
     * 获取值：aa["key"]
     * 
     * 如果键不存在，抛出 KeyNotFoundException
     */
    Slice opIndex(K)(K key)
    {
        auto s = db_.getSlice(key);
        if (s.empty())
        {
            import std.conv : text;
            throw new KeyNotFoundException(text(key));
        }
        return s;
    }

    /**
     * 设置值：aa["key"] = value
     */
    void opIndexAssign(K, V)(V val, K key)
    {
        db_.put(key, val);
    }

    /**
     * 检查键是否存在："key" in aa
     */
    bool opBinaryRight(string op, K)(K key)
        if (op == "in")
    {
        return !db_.getSlice(key).empty();
    }

    /**
     * 复合赋值：aa["key"] ~= value
     * 
     * 用于追加字符串/数组
     */
    void opIndexOpAssign(string op, K, V)(V val, K key)
        if (op == "~")
    {
        import std.traits : isSomeString, isDynamicArray;

        static if (isSomeString!V || isDynamicArray!V)
        {
            auto existing = db_.getSlice(key);
            if (existing.empty())
            {
                db_.put(key, val);
            }
            else
            {
                static if (isSomeString!V)
                {
                    // 优化：使用数组拼接而非字符串 ~ 运算符，避免中间临时对象
                    auto existingBytes = existing.asBytes();
                    auto valSlice = Slice(val);
                    ubyte[] combined;
                    combined.length = existingBytes.length + valSlice.size();
                    combined[0 .. existingBytes.length] = existingBytes;
                    combined[existingBytes.length .. $] = valSlice.asBytes();
                    db_.put(key, Slice(combined.ptr, combined.length));
                }
                else
                {
                    auto combined = existing.asBytes() ~ val;
                    db_.put(key, combined);
                }
            }
        }
        else
        {
            static assert(false, "~= only supported for strings and arrays");
        }
    }

    // ============================================================
    // 属性操作
    // ============================================================

    /**
     * 获取数据库中的键值对数量
     * 
     * 注意：此操作需要遍历整个数据库，对于大型数据库可能较慢
     */
    @property size_t length()
    {
        size_t count = 0;
        auto iter = db_.iterator();
        iter.seekToFirst();
        while (iter.valid())
        {
            count++;
            iter.next();
        }
        return count;
    }

    /**
     * 清空数据库中的所有键值对
     */
    void clear()
    {
        auto batch = new WriteBatch();
        auto iter = db_.iterator();
        iter.seekToFirst();
        while (iter.valid())
        {
            batch.remove(iter.key());
            iter.next();
        }
        db_.write(batch);
    }

    // ============================================================
    // 集合操作
    // ============================================================

    /**
     * 获取所有键的数组
     * 
     * 注意：此操作会分配内存并遍历整个数据库
     */
    @property Slice[] keys()
    {
        Slice[] result;
        auto iter = db_.iterator();
        iter.seekToFirst();
        while (iter.valid())
        {
            auto keyBytes = iter.key().asBytes();
            result ~= Slice(keyBytes.dup);
            iter.next();
        }
        return result;
    }

    /**
     * 获取所有值的数组
     * 
     * 注意：此操作会分配内存并遍历整个数据库
     */
    @property Slice[] values()
    {
        Slice[] result;
        auto iter = db_.iterator();
        iter.seekToFirst();
        while (iter.valid())
        {
            auto valBytes = iter.value().asBytes();
            result ~= Slice(valBytes.dup);
            iter.next();
        }
        return result;
    }

    // ============================================================
    // 迭代操作
    // ============================================================

    /**
     * 返回键的迭代器 Range
     */
    auto byKey()
    {
        auto iter = db_.iterator();
        iter.seekToFirst();
        return .byKeyRange(iter);
    }

    /**
     * 返回值的迭代器 Range
     */
    auto byValue()
    {
        auto iter = db_.iterator();
        iter.seekToFirst();
        return .byValueRange(iter);
    }

    /**
     * 返回键值对的迭代器 Range
     */
    auto byKeyValue()
    {
        auto iter = db_.iterator();
        iter.seekToFirst();
        return IteratorRange(iter);
    }

    // ============================================================
    // 查找操作
    // ============================================================

    /**
     * 获取值或默认值（AA 标准方法）
     * 
     * 如果键存在，返回对应值；否则返回默认值
     */
    V get(K, V)(K key, lazy V defVal)
    {
        V value;
        if (db_.get(key, value))
            return value;
        return defVal;
    }

    /**
     * 如果键不存在则插入值并返回
     * 
     * 如果键存在，返回对应值；否则插入 lazyValue 并返回
     */
    Slice require(K, V)(K key, lazy V val)
    {
        auto existing = db_.getSlice(key);
        if (!existing.empty())
            return existing;
        
        db_.put(key, val);
        return db_.getSlice(key);
    }

    /**
     * 创建或更新值
     * 
     * 如果键不存在，调用 creator 创建值并插入
     * 如果键存在，调用 updater 更新值
     * 
     * 参数：
     *   key - 键
     *   creator - 创建值的委托（键不存在时调用）
     *   updater - 更新值的委托（键存在时调用，接收当前值）
     */
    void update(K, V)(K key, V delegate() creator, void delegate(ref Slice) updater)
    {
        auto existing = db_.getSlice(key);
        if (existing.empty())
        {
            if (creator !is null)
            {
                auto newVal = creator();
                db_.put(key, newVal);
            }
        }
        else
        {
            if (updater !is null)
            {
                auto existingBytes = existing.asBytes();
                // 优化：直接创建新数组而非 .dup，明确生命周期
                ubyte[] mutableVal;
                mutableVal.length = existingBytes.length;
                mutableVal[] = existingBytes[];
                updater(Slice(mutableVal.ptr, mutableVal.length));
                db_.put(key, Slice(mutableVal.ptr, mutableVal.length));
            }
        }
    }

    /**
     * 创建或更新值（返回值版本）
     */
    Slice updateReturn(K, V)(K key, V delegate() creator, void delegate(ref Slice) updater)
    {
        auto existing = db_.getSlice(key);
        if (existing.empty())
        {
            if (creator !is null)
            {
                auto newVal = creator();
                db_.put(key, newVal);
                return db_.getSlice(key);
            }
            return Slice();
        }
        else
        {
            if (updater !is null)
            {
                auto existingBytes = existing.asBytes();
                // 优化：直接创建新数组而非 .dup，明确生命周期
                ubyte[] mutableVal;
                mutableVal.length = existingBytes.length;
                mutableVal[] = existingBytes[];
                updater(Slice(mutableVal.ptr, mutableVal.length));
                db_.put(key, Slice(mutableVal.ptr, mutableVal.length));
            }
            return db_.getSlice(key);
        }
    }

    /**
     * 删除键
     */
    void remove(K)(K key)
    {
        db_.del(key);
    }

    /**
     * 检查键是否存在
     */
    bool contains(K)(K key)
    {
        return !db_.getSlice(key).empty();
    }
}

/// 全局默认读选项（编译时常量，零运行时开销）
enum ReadOptions defaultReadOptions = ReadOptions();

/// 全局默认写选项（编译时常量，零运行时开销）
enum WriteOptions defaultWriteOptions = WriteOptions();

///
unittest
{
    // 关联数组风格操作测试
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_aa_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        auto aa = db.aa;
        
        // 1. aa["key"] = value 语法
        aa["name"] = "dleveldb";
        aa["version"] = "1.0.0";
        
        // 2. aa["key"] 语法
        auto name = aa["name"].asString();
        assert(name == "dleveldb");
        
        // 3. "key" in aa 语法
        assert("name" in aa);
        assert("nonexistent" !in aa);
        
        // 4. aa.contains(key) 方法
        assert(aa.contains("name"));
        assert(!aa.contains("nonexistent"));
        
        // 5. aa.get(key, default) 方法
        auto val1 = aa.get("name", "default");
        assert(val1 == "dleveldb");
        
        // 6. aa.remove(key) 方法
        aa.remove("version");
        assert("version" !in aa);
        
        // 7. aa["key"] ~= value 追加语法
        aa["msg"] = "Hello";
        aa["msg"] ~= " World";
        assert(aa["msg"].asString() == "Hello World");
        
        // 8. 访问不存在的键抛出异常
        bool caught = false;
        try
        {
            auto val3 = aa["nonexistent_key"];
        }
        catch (KeyNotFoundException e)
        {
            caught = true;
            assert(e.key() == "nonexistent_key");
        }
        assert(caught, "访问不存在的键应抛出 KeyNotFoundException");
        
        // 9. aa.length 属性
        assert(aa.length == 2, "aa.length 应为 2");
        
        // 10. aa.keys 属性
        auto allKeys = aa.keys;
        assert(allKeys.length == 2);
        
        // 11. aa.values 属性
        auto allValues = aa.values;
        assert(allValues.length == 2);
        
        // 显式关闭数据库
        db.close();
    }
}

///
unittest
{
    // 并发写入测试 - 验证多线程同时写入的正确性
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.format : format;
    
    version (Posix) {} else version (Windows)
    {
        // Windows 下跳过并发测试（core.thread 在 Windows unittest 中可能不稳定）
        return;
    }
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_concurrent_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 启动 5 个线程，每个线程写入 100 个键值对
        import core.thread : Thread;
        Thread[] threads;
        
        foreach (i; 0 .. 5)
        {
            threads ~= new Thread({
                int threadId = i;
                for (int j = 0; j < 100; j++)
                {
                    string key = format("key_%d_%d", threadId, j);
                    string value = format("value_%d_%d", threadId, j);
                    db.put(Slice(key), Slice(value));
                }
            });
            threads[$-1].start();
        }
        
        // 等待所有线程完成
        foreach (t; threads)
        {
            t.join();
        }
        
        // 验证数据完整性：应该正好有 500 个键值对
        assert(db.aa.length == 500, 
            format("Expected 500 keys, got %d", db.aa.length));
        
        // 随机抽样验证部分键值对
        for (int i = 0; i < 5; i++)
        {
            for (int j = 0; j < 10; j++)  // 只检查前 10 个
            {
                string key = format("key_%d_%d", i, j);
                string expectedValue = format("value_%d_%d", i, j);
                
                assert(key in db.aa, format("Key %s should exist", key));
                auto actualValue = db.aa[key].asString();
                assert(actualValue == expectedValue,
                    format("Value mismatch for key %s: expected %s, got %s",
                           key, expectedValue, actualValue));
            }
        }
        
        // 显式关闭数据库
        db.close();
    }
    
    // 清理测试数据库
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 边界测试：空键和空值
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.range : repeat;
    import std.array : array;
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_boundary_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 空值测试
        db.put(Slice("empty_value"), Slice(""));
        string val;
        assert(db.get(Slice("empty_value"), val));
        assert(val.length == 0);
        
        // 长键测试（适度长度）
        string longKey = "long_key_" ~ text(0);
        foreach (_; 0 .. 100) longKey ~= "_part";
        string longValue = "long_value_data";
        db.put(Slice(longKey), Slice(longValue));
        assert(db.get(Slice(longKey), val));
        assert(val == longValue);
        
        // 二进制键测试
        ubyte[16] binaryKey;
        foreach (i; 0 .. 16)
            binaryKey[i] = cast(ubyte) i;
        db.put(Slice(binaryKey[]), Slice("binary_value"));
        assert(db.get(Slice(binaryKey[]), val));
        assert(val == "binary_value");
        
        db.close();
    }
    
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // WriteBatch测试
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_batch_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 批量写入
        auto batch = new WriteBatch();
        foreach (i; 0 .. 100)
        {
            string key = "batch_key_" ~ text(i);
            string val = "batch_val_" ~ text(i);
            batch.put(Slice(key), Slice(val));
        }
        db.write(batch);
        
        // 验证批量写入
        foreach (i; 0 .. 100)
        {
            string key = "batch_key_" ~ text(i);
            string expectedVal = "batch_val_" ~ text(i);
            string val;
            assert(db.get(Slice(key), val));
            assert(val == expectedVal);
        }
        
        // 批量删除
        auto delBatch = new WriteBatch();
        foreach (i; 0 .. 50)
        {
            string key = "batch_key_" ~ text(i);
            delBatch.remove(Slice(key));
        }
        db.write(delBatch);
        
        // 验证删除
        foreach (i; 0 .. 50)
        {
            string key = "batch_key_" ~ text(i);
            assert(!db.getSlice(Slice(key)).ok());
        }
        foreach (i; 50 .. 100)
        {
            string key = "batch_key_" ~ text(i);
            assert(db.getSlice(Slice(key)).ok());
        }
        
        db.close();
    }
    
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 迭代器测试
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_iter_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 插入有序数据
        foreach (i; 0 .. 100)
        {
            string key = text(i).zfill(3);
            db.put(Slice(key), Slice("val_" ~ key));
        }
        
        // 正向遍历
        auto iter = db.iterator();
        iter.seekToFirst();
        int count = 0;
        const(char)[] prevKey = "";
        while (iter.valid())
        {
            auto key = iter.key().asString();
            assert(key >= prevKey, "Keys should be in ascending order");
            prevKey = key.idup;
            count++;
            iter.next();
        }
        assert(count == 100);
        
        // 反向遍历
        iter.seekToLast();
        count = 0;
        prevKey = "zzz";
        while (iter.valid())
        {
            auto key = iter.key().asString();
            assert(key <= prevKey, "Keys should be in descending order");
            prevKey = key.idup;
            count++;
            iter.prev();
        }
        assert(count == 100);
        
        // Seek测试
        iter.seek(Slice("050"));
        assert(iter.valid());
        assert(iter.key().asString() == "050");
        
        iter.seek(Slice("025"));
        assert(iter.valid());
        assert(iter.key().asString() == "025");
        
        // Seek不存在的键
        iter.seek(Slice("025a"));
        assert(iter.valid());
        assert(iter.key().asString() == "026");
        
        db.close();
    }
    
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 压力测试：大量写入和读取
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    
    string dbPath = buildPath(tempDir().idup, "dleveldb_stress_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 写入10000个键值对
        foreach (i; 0 .. 10_000)
        {
            string key = "stress_key_" ~ text(i);
            string val = "stress_val_" ~ text(i);
            db.put(Slice(key), Slice(val));
        }
        
        // 验证所有键值对
        size_t foundCount = 0;
        foreach (i; 0 .. 10_000)
        {
            string key = "stress_key_" ~ text(i);
            string expectedVal = "stress_val_" ~ text(i);
            string val;
            if (db.get(Slice(key), val) && val == expectedVal)
                foundCount++;
        }
        assert(foundCount == 10_000);
        
        // 更新测试
        foreach (i; 0 .. 1000)
        {
            string key = "stress_key_" ~ text(i);
            string newVal = "updated_val_" ~ text(i);
            db.put(Slice(key), Slice(newVal));
        }
        
        // 验证更新
        foreach (i; 0 .. 1000)
        {
            string key = "stress_key_" ~ text(i);
            string expectedVal = "updated_val_" ~ text(i);
            string val;
            assert(db.get(Slice(key), val));
            assert(val == expectedVal);
        }
        
        // 删除测试
        foreach (i; 0 .. 500)
        {
            string key = "stress_key_" ~ text(i);
            db.del(Slice(key));
        }
        
        // 验证删除
        foreach (i; 0 .. 500)
        {
            string key = "stress_key_" ~ text(i);
            assert(!db.getSlice(Slice(key)).ok());
        }
        foreach (i; 500 .. 10_000)
        {
            string key = "stress_key_" ~ text(i);
            assert(db.getSlice(Slice(key)).ok());
        }
        
        db.close();
    }
    
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 5万条随机字符串键值对测试：写入→验证→关闭→重开→验证→删除
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.random : uniform, Random;
    import std.format : format;

    enum count = 50_000;
    string dbPath = buildPath(tempDir().idup, "dleveldb_50k_string_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }

    // 生成随机数据：key和val都是随机字符串
    string[] keys;
    string[] vals;
    keys.length = count;
    vals.length = count;
    auto rng = Random(12345);
    foreach (i; 0 .. count)
    {
        keys[i] = format("k_%08x_%08x", i, uniform!(uint)(rng));
        vals[i] = format("v_%08x_%08x", i, uniform!(uint)(rng));
    }

    // 步骤1：创建数据库，写入5万条，立即读取验证
    {
        auto db = new LevelDB(dbPath);
        foreach (i; 0 .. count)
        {
            db.put(Slice(keys[i]), Slice(vals[i]));
        }

        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            string v;
            if (db.get(Slice(keys[i]), v) && v == vals[i])
                ok++;
        }
        assert(ok == count, format("string test write-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤2：重新打开数据库，读取验证
    {
        auto db = new LevelDB(dbPath);
        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            string v;
            if (db.get(Slice(keys[i]), v) && v == vals[i])
                ok++;
        }
        assert(ok == count, format("string test reopen-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤3：关闭删除库
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 泛型接口测试
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;

    string dbPath = buildPath(tempDir().idup, "dleveldb_generic_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
    
    {
        auto db = new LevelDB(dbPath);
        
        // 整数类型
        db.put("int_key", 42);
        int intVal;
        assert(db.get("int_key", intVal));
        assert(intVal == 42);
        
        // 长整数类型
        db.put("long_key", 123456789012345L);
        long longVal;
        assert(db.get("long_key", longVal));
        assert(longVal == 123456789012345L);
        
        // 浮点类型
        db.put("double_key", 3.14159);
        double doubleVal;
        assert(db.get("double_key", doubleVal));
        assert(doubleVal == 3.14159);
        
        // 数组类型
        int[] intArr = [1, 2, 3, 4, 5];
        db.put("array_key", intArr);
        int[] recoveredArr;
        assert(db.get("array_key", recoveredArr));
        assert(recoveredArr == intArr);
        
        db.close();
    }
    
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 5万条随机字符串键值对的迭代器测试
    // 流程：写入5万条 → seekToFirst+next正向遍历 → seekToLast+prev反向遍历 → 关闭→重开→再验证
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.random : uniform, Random;
    import std.format : format;
    import std.algorithm.sorting : sort;
    import std.algorithm.comparison : cmp;

    enum count = 50_000;
    string dbPath = buildPath(tempDir().idup, "dleveldb_50k_iter_string_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }

    // 生成随机数据并排序（迭代器应按key有序返回）
    string[] keys;
    string[] vals;
    keys.length = count;
    vals.length = count;
    auto rng = Random(11111);
    foreach (i; 0 .. count)
    {
        keys[i] = format("k_%08x_%08x", i, uniform!(uint)(rng));
        vals[i] = format("v_%08x_%08x", i, uniform!(uint)(rng));
    }
    // 排序以供遍历验证
    string[] sortedKeys = keys.dup;
    string[] sortedVals;
    sortedVals.length = count;
    sort!"a < b"(sortedKeys);
    // 建立排序后的val映射
    ulong[string] keyToIdx;
    foreach (i; 0 .. count)
        keyToIdx[keys[i]] = i;
    foreach (i; 0 .. count)
        sortedVals[i] = vals[keyToIdx[sortedKeys[i]]];

    // 步骤1：创建数据库，写入5万条
    {
        auto db = new LevelDB(dbPath);
        foreach (i; 0 .. count)
            db.put(Slice(keys[i]), Slice(vals[i]));

        // --- seekToFirst + next 正向遍历 ---
        auto iter = db.iterator();
        iter.seekToFirst();
        size_t idx = 0;
        while (iter.valid())
        {
            assert(iter.key() == Slice(sortedKeys[idx]),
                format("iter next key[%d] mismatch", idx));
            assert(iter.value() == Slice(sortedVals[idx]),
                format("iter next val[%d] mismatch", idx));
            iter.next();
            idx++;
        }
        assert(idx == count, format("iter next count: %d != %d", idx, count));

        // --- seekToLast + prev 反向遍历 ---
        iter.seekToLast();
        idx = count - 1;
        while (iter.valid())
        {
            assert(iter.key() == Slice(sortedKeys[idx]),
                format("iter prev key[%d] mismatch", idx));
            assert(iter.value() == Slice(sortedVals[idx]),
                format("iter prev val[%d] mismatch", idx));
            iter.prev();
            if (idx == 0) break; // prev到最后一条之后会invalid
            idx--;
        }
        assert(idx == 0, format("iter prev stopped at idx=%d", idx));

        db.close();
    }

    // 步骤2：重新打开数据库，迭代器验证
    {
        auto db = new LevelDB(dbPath);

        // seekToFirst + next
        auto iter = db.iterator();
        iter.seekToFirst();
        size_t idx = 0;
        while (iter.valid())
        {
            assert(iter.key() == Slice(sortedKeys[idx]),
                format("reopen iter next key[%d] mismatch", idx));
            iter.next();
            idx++;
        }
        assert(idx == count, format("reopen iter next count: %d", idx));

        // seekToLast + prev
        iter.seekToLast();
        idx = count - 1;
        while (iter.valid())
        {
            assert(iter.key() == Slice(sortedKeys[idx]),
                format("reopen iter prev key[%d] mismatch", idx));
            iter.prev();
            if (idx == 0) break;
            idx--;
        }
        assert(idx == 0);

        db.close();
    }

    // 步骤3：关闭删除库
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

string text(T)(T val)
{
    import std.conv : to;
    return to!string(val);
}

string zfill(string s, int width)
{
    import std.format : format;
    import std.algorithm : max;
    import std.range : repeat;
    import std.array : array;
    int padding = max(0, width - cast(int)s.length);
    return "%s%s".format(repeat('0', padding).array, s);
}
