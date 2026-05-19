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
 */
final class LevelDB
{
private:
    DBImpl impl_;
    bool isOpen_ = false;

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
        if (isOpen_)
            close();
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

    /// 关闭数据库
    @property void close()
    {
        if (isOpen_ && impl_ !is null)
        {
            impl_.close();
            impl_ = null;
            isOpen_ = false;
        }
    }

    /**
     * 写入键值对（泛型）
     * 
     * 支持任意可序列化为 Slice 的类型
     * 示例：
     *   db.put("key", "value");
     *   db.put("key", 42);
     *   db.put(Slice("key"), Slice.Ref(3.14));
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
        if (buf.length == 0)
            return false;

        value = fromSlice!V(Slice(cast(const(ubyte)*) buf.ptr, buf.length));
        return true;
    }

    /**
     * 删除键（泛型）
     */
    void del(K)(in K key, const(WriteOptions) opt = WriteOptions())
    {
        checkOpen();
        auto s = impl_.delete_(opt, toSliceKey(key));
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

    /// 重载 db[key]
    Slice opIndex(K)(K key)
    {
        return getSlice(key);
    }

    /// 重载 db[key] = val
    void opIndexAssign(K, V)(V val, K key)
    {
        put(key, val);
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
    static Slice toSlice(T)(in T val)
    {
        static if (is(T == Slice))
        {
            return val;
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
            // 基本类型和POD结构体：使用Slice.Ref存储到TLS缓冲区
            return Slice.Ref(val);
        }
    }
    
    /// 将任意类型转换为 Slice（使用独立的TLS缓冲区，用于key）
    /// 与toSlice使用不同的缓冲区，避免put(key,value)时覆盖
    static Slice toSliceKey(T)(in T val)
    {
        static if (is(T == Slice))
        {
            return val;
        }
        else static if (isSomeString!T || isDynamicArray!T || isPointer!T)
        {
            return toSlice(val);
        }
        else
        {
            // 使用独立的TLS缓冲区存储key
            import std.traits : Unqual;
            static Unqual!T keyStorage;
            keyStorage = cast(Unqual!T) val;
            return Slice(cast(const(void*)) &keyStorage, Unqual!T.sizeof);
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
            return *(cast(V*) s.data());
        }
    }
}

/// 全局默认读选项
__gshared ReadOptions DefaultReadOptions;

/// 全局默认写选项
__gshared WriteOptions DefaultWriteOptions;

shared static this()
{
    DefaultReadOptions = ReadOptions();
    DefaultWriteOptions = WriteOptions();
}
