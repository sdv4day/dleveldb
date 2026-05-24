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
    DBImpl impl_;
    bool isOpen_ = false;
    LevelDBAA aa_;

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
        if (isOpen_)
            close();

        impl_ = new DBImpl(opt, dbpath);
        Status s = impl_.open();
        if (!s.ok())
            throw new LeveldbException(s);
        isOpen_ = true;
    }

    /// 判断数据库是否打开
    @property bool isOpen() const pure nothrow @safe @nogc { return isOpen_; }

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
        if (aa_ is null)
            aa_ = new LevelDBAA(this);
        return aa_;
    }

    /// 关闭数据库
    void close()
    {
        if (isOpen_ && impl_ !is null)
        {
            impl_.close();
            impl_ = null;
            isOpen_ = false;
            aa_ = null;
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
        auto s = impl_.put(opt, toSliceKey(key), toSlice(value));
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
        auto s = impl_.get(opt, toSliceKey(key), buf);
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
        auto s = impl_.remove(opt, toSliceKey(key));
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
        auto s = impl_.get(opt, toSliceKey(key), buf);
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
        auto s = impl_.write(opt, cast(WriteBatch) batch);
        if (!s.ok())
            throw new LeveldbException(s);
    }

    /// 获取快照
    @property const(Snapshot) snapshot()
    {
        checkOpen();
        return impl_.getSnapshot();
    }

    /// 释放快照
    void releaseSnapshot(const(Snapshot) snap)
    {
        checkOpen();
        impl_.releaseSnapshot(snap);
    }

    /// 创建迭代器
    Iterator iterator(const(ReadOptions) opt = ReadOptions())
    {
        checkOpen();
        return impl_.newIterator(opt);
    }

    /// 压缩指定范围
    void compactRange(Slice begin, Slice end)
    {
        checkOpen();
        impl_.compactRange(begin, end);
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
        if (!isOpen_)
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
            return Slice(cast(const(void*)) val, T.sizeof);
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
        else
        {
            if (V.sizeof > s.size())
                throw new LeveldbException("Assignment size is larger than slice data size");
            V result;
            const(ubyte)* src = s.data();
            () @trusted { import core.stdc.string : memcpy; memcpy(&result, src, V.sizeof); } ();
            return result;
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
                    string combined = (existing.asString() ~ val).idup;
                    db_.put(key, combined);
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
                Slice mutableVal = Slice(existingBytes.dup);
                updater(mutableVal);
                db_.put(key, mutableVal);
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
                Slice mutableVal = Slice(existingBytes.dup);
                updater(mutableVal);
                db_.put(key, mutableVal);
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
    if (dbPath.exists) dbPath.rmdirRecurse();
    
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
