module dleveldb.ext;

import dleveldb.db;
import dleveldb.options;
import dleveldb.slice;
import dleveldb.comparator;
import dleveldb.coding;
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
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    /// 写入
    void put(V)(in ulong key, in V val, const(WriteOptions) opt = defaultWriteOptions)
    {
        db_.put(Slice.owned(key), val, opt);
    }

    /// 读取
    bool get(V)(in ulong key, out V val, const(ReadOptions) opt = defaultReadOptions)
    {
        return db_.get(Slice.owned(key), val, opt);
    }

    /// 删除
    void del(in ulong key, const(WriteOptions) opt = defaultWriteOptions)
    {
        db_.del(Slice.owned(key), opt);
    }

    /// 查找，不存在返回默认值
    V find(V)(in ulong key, V def, const(ReadOptions) opt = defaultReadOptions)
    {
        return db_.find(Slice.owned(key), def, opt);
    }

    /// 获取 Slice
    auto getSlice(in ulong key, const(ReadOptions) opt = defaultReadOptions)
    {
        return db_.getSlice(Slice.owned(key), opt);
    }

    /// 创建迭代器
    Iterator iterator(const(ReadOptions) opt = defaultReadOptions)
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

        ulong va = decodeFixed64(cast(const(ubyte)*) a.data());
        ulong vb = decodeFixed64(cast(const(ubyte)*) b.data());
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

///
unittest
{
    // 5万条随机ulong键值对测试：写入→验证→关闭→重开→验证→删除
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.random : uniform, Random;
    import std.format : format;

    enum count = 50_000;
    string dbPath = buildPath(tempDir().idup, "dleveldb_50k_ulong_rnd_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }

    // 生成随机数据：ulong key 和 ulong val 各自独立随机
    ulong[] keys;
    ulong[] vals;
    keys.length = count;
    vals.length = count;
    auto rng = Random(54321);
    foreach (i; 0 .. count)
    {
        keys[i] = cast(ulong)(i) * 1_000_000_003 + uniform!(uint)(rng);
        vals[i] = cast(ulong)(i) * 1_000_000_007 + uniform!(uint)(rng);
    }

    // 步骤1：创建数据库，写入5万条，立即读取验证
    {
        auto db = new UlongDB(dbPath);
        foreach (i; 0 .. count)
        {
            db.put(keys[i], vals[i]);
        }

        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            ulong v;
            if (db.get(keys[i], v) && v == vals[i])
                ok++;
        }
        assert(ok == count, format("ulong random test write-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤2：重新打开数据库，读取验证
    {
        auto db = new UlongDB(dbPath);
        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            ulong v;
            if (db.get(keys[i], v) && v == vals[i])
                ok++;
        }
        assert(ok == count, format("ulong random test reopen-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤3：关闭删除库
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 5万条ulong键值对测试（key=val）：写入→验证→关闭→重开→验证→删除
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.random : uniform, Random;
    import std.format : format;

    enum count = 50_000;
    string dbPath = buildPath(tempDir().idup, "dleveldb_50k_ulong_eq_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }

    // 生成随机数据：key == val
    ulong[] keys;
    keys.length = count;
    auto rng = Random(67890);
    foreach (i; 0 .. count)
    {
        keys[i] = cast(ulong)(i) * 1_000_000_009 + uniform!(uint)(rng);
    }

    // 步骤1：创建数据库，写入5万条（key==val），立即读取验证
    {
        auto db = new UlongDB(dbPath);
        foreach (i; 0 .. count)
        {
            db.put(keys[i], keys[i]);
        }

        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            ulong v;
            if (db.get(keys[i], v) && v == keys[i])
                ok++;
        }
        assert(ok == count, format("ulong key=val test write-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤2：重新打开数据库，读取验证
    {
        auto db = new UlongDB(dbPath);
        size_t ok = 0;
        foreach (i; 0 .. count)
        {
            ulong v;
            if (db.get(keys[i], v) && v == keys[i])
                ok++;
        }
        assert(ok == count, format("ulong key=val test reopen-verify: %d/%d", ok, count));
        db.close();
    }

    // 步骤3：关闭删除库
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }
}

///
unittest
{
    // 5万条随机ulong键值对的迭代器测试
    // 流程：写入5万条 → seekToFirst+next正向遍历 → seekToLast+prev反向遍历 → 关闭→重开→再验证
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.random : uniform, Random;
    import std.format : format;
    import std.algorithm.sorting : sort;

    enum count = 50_000;
    string dbPath = buildPath(tempDir().idup, "dleveldb_50k_iter_ulong_test");
    if (dbPath.exists) { try { dbPath.rmdirRecurse(); } catch (Exception) {} }

    // 生成随机数据
    ulong[] keys;
    ulong[] vals;
    keys.length = count;
    vals.length = count;
    auto rng = Random(22222);
    foreach (i; 0 .. count)
    {
        keys[i] = cast(ulong)(i) * 1_000_000_011 + uniform!(uint)(rng);
        vals[i] = cast(ulong)(i) * 1_000_000_013 + uniform!(uint)(rng);
    }

    // 排序以供遍历验证（迭代器按ComparatorUlong顺序返回）
    ulong[] sortedKeys = keys.dup;
    ulong[] sortedVals;
    sortedVals.length = count;
    sort!"a < b"(sortedKeys);
    // 建立排序后的val映射
    ulong[ulong] keyToVal;
    foreach (i; 0 .. count)
        keyToVal[keys[i]] = vals[i];
    foreach (i; 0 .. count)
        sortedVals[i] = keyToVal[sortedKeys[i]];

    // 步骤1：创建数据库，写入5万条
    {
        auto db = new UlongDB(dbPath);
        foreach (i; 0 .. count)
            db.put(keys[i], vals[i]);

        // --- seekToFirst + next 正向遍历 ---
        auto iter = db.iterator();
        iter.seekToFirst();
        size_t idx = 0;
        while (iter.valid())
        {
            ulong k = iter.key().as!ulong;
            ulong v = iter.value().as!ulong;
            assert(k == sortedKeys[idx],
                format("ulong iter next key[%d] mismatch: %d != %d", idx, k, sortedKeys[idx]));
            assert(v == sortedVals[idx],
                format("ulong iter next val[%d] mismatch", idx));
            iter.next();
            idx++;
        }
        assert(idx == count, format("ulong iter next count: %d != %d", idx, count));

        // --- seekToLast + prev 反向遍历 ---
        iter.seekToLast();
        idx = count - 1;
        while (iter.valid())
        {
            ulong k = iter.key().as!ulong;
            ulong v = iter.value().as!ulong;
            assert(k == sortedKeys[idx],
                format("ulong iter prev key[%d] mismatch", idx));
            assert(v == sortedVals[idx],
                format("ulong iter prev val[%d] mismatch", idx));
            iter.prev();
            if (idx == 0) break;
            idx--;
        }
        assert(idx == 0, format("ulong iter prev stopped at idx=%d", idx));

        db.close();
    }

    // 步骤2：重新打开数据库，迭代器验证
    {
        auto db = new UlongDB(dbPath);

        // seekToFirst + next
        auto iter = db.iterator();
        iter.seekToFirst();
        size_t idx = 0;
        while (iter.valid())
        {
            ulong k = iter.key().as!ulong;
            assert(k == sortedKeys[idx],
                format("reopen ulong iter next key[%d] mismatch", idx));
            iter.next();
            idx++;
        }
        assert(idx == count, format("reopen ulong iter next count: %d", idx));

        // seekToLast + prev
        iter.seekToLast();
        idx = count - 1;
        while (iter.valid())
        {
            ulong k = iter.key().as!ulong;
            assert(k == sortedKeys[idx],
                format("reopen ulong iter prev key[%d] mismatch", idx));
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
