module dleveldb.ext;

import dleveldb.db;
import dleveldb.options;
import dleveldb.slice;
import dleveldb.comparator;
import dleveldb.exceptions;
import dleveldb.iterator;

/**
 * UlongDB：以 ulong 为键的 LevelDB 封装
 * 
 * 内部使用 ComparatorUlong 比较器
 * 提供类型安全的 ulong 键操作
 */
final class UlongDB
{
private:
    LevelDB db_;

public:
    this(Options opt, string dbpath)
    {
        auto ulongOpt = opt;
        ulongOpt.comparator = new ComparatorUlong();
        db_ = new LevelDB(ulongOpt, dbpath);
    }

    this(string dbpath)
    {
        auto opt = Options();
        opt.comparator = new ComparatorUlong();
        db_ = new LevelDB(opt, dbpath);
    }

    ~this()
    {
        if (db_ !is null && db_.isOpen)
            db_.close();
    }

    /// 写入
    void put(V)(in ulong key, in V val, const(WriteOptions) opt = DefaultWriteOptions)
    {
        db_.put(Slice.Ref(key), val, opt);
    }

    /// 读取
    bool get(V)(in ulong key, out V val, const(ReadOptions) opt = DefaultReadOptions)
    {
        return db_.get(Slice.Ref(key), val, opt);
    }

    /// 删除
    void del(in ulong key, const(WriteOptions) opt = DefaultWriteOptions)
    {
        db_.del(Slice.Ref(key), opt);
    }

    /// 查找，不存在返回默认值
    V find(V)(in ulong key, V def, const(ReadOptions) opt = DefaultReadOptions)
    {
        return db_.find(Slice.Ref(key), def, opt);
    }

    /// 获取 Slice
    auto getSlice(in ulong key, const(ReadOptions) opt = DefaultReadOptions)
    {
        return db_.getSlice(Slice.Ref(key), opt);
    }

    /// 创建迭代器
    Iterator iterator(const(ReadOptions) opt = DefaultReadOptions)
    {
        return db_.iterator(opt);
    }

    /// 是否打开
    @property bool isOpen() const { return db_ !is null && db_.isOpen; }

    /// 关闭
    @property void close() { if (db_ !is null) db_.close(); }
}

/**
 * ulong 比较器
 * 将 Slice 数据解释为 64 位无符号整型进行比较
 */
final class ComparatorUlong : Comparator
{
    string name() const
    {
        return "dleveldb.ComparatorUlong";
    }

    int compare(Slice a, Slice b) const nothrow @nogc
    {
        if (a.size() < ulong.sizeof || b.size() < ulong.sizeof)
            return a.opCmp(b);

        ulong va = *(cast(ulong*) a.data());
        ulong vb = *(cast(ulong*) b.data());
        if (va < vb) return -1;
        if (va > vb) return 1;
        return 0;
    }

    void findShortestSeparator(ref Slice start, Slice limit) const
    {
        // 简化实现：不做修改
    }

    void findShortSuccessor(ref Slice key) const
    {
        // 简化实现：不做修改
    }
}
