module dleveldb.db_iter;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.iterator;
import dleveldb.dbformat;
import dleveldb.comparator;
import dleveldb.coding;

/**
 * 数据库级迭代器
 * 将内部键迭代器转换为用户键迭代器
 * 处理删除标记和序列号覆盖
 */
class DBIter : Iterator
{
private:
    Comparator userComparator_;
    Iterator internalIter_;
    ulong sequence_;
    Slice savedKey_;     // 保存的内部键
    ubyte[] savedValue_; // 保存的值
    Status status_;
    bool valid_;
    Direction direction_;

    enum Direction : ubyte
    {
        forward = 0,
        reverse = 1,
    }

public:
    this(Comparator userCmp, Iterator internalIter, ulong sequence)
    {
        userComparator_ = userCmp;
        internalIter_ = internalIter;
        sequence_ = sequence;
        valid_ = false;
        direction_ = Direction.forward;
    }

    bool valid() const nothrow @nogc { return valid_; }

    void seekToFirst()
    {
        internalIter_.seekToFirst();
        direction_ = Direction.forward;
        findNextUserEntry(false, Slice());
    }

    void seekToLast()
    {
        internalIter_.seekToLast();
        direction_ = Direction.reverse;
        findPrevUserEntry();
    }

    void seek(Slice target)
    {
        InternalKey ikey = InternalKey(target, sequence_, ValueType.value);
        internalIter_.seek(ikey.encode());
        direction_ = Direction.forward;
        findNextUserEntry(false, Slice());
    }

    void next()
    {
        assert(valid());
        if (direction_ != Direction.forward)
        {
            // 切换方向
            InternalKey ikey = InternalKey(savedKey_, sequence_, ValueType.value);
            internalIter_.seek(ikey.encode());
            direction_ = Direction.forward;
            if (!internalIter_.valid())
            {
                internalIter_.seekToFirst();
            }
            else
            {
                internalIter_.next();
            }
        }
        findNextUserEntry(true, savedKey_);
    }

    void prev()
    {
        assert(valid());
        if (direction_ != Direction.reverse)
        {
            // 切换方向
            InternalKey ikey = InternalKey(savedKey_, sequence_, ValueType.value);
            internalIter_.seek(ikey.encode());
            direction_ = Direction.reverse;
        }
        findPrevUserEntry();
    }

    Slice key()
    {
        assert(valid());
        return savedKey_;
    }

    Slice value()
    {
        assert(valid());
        return Slice(savedValue_.ptr, savedValue_.length);
    }

    Status status() const nothrow @nogc { return status_; }

private:
    /// 向前查找下一个用户键
    /// skip: 是否跳过当前键
    /// savedKey: 当前用户键（用于跳过同键的其他版本）
    void findNextUserEntry(bool skip, Slice savedKey)
    {
        // 重新实现简化版本
        while (internalIter_.valid())
        {
            Slice ikey = internalIter_.key();
            ParsedInternalKey parsed;
            if (!parseInternalKey(ikey, parsed))
            {
                status_ = statusCorruption("bad internal key");
                valid_ = false;
                return;
            }

            if (parsed.sequence <= sequence_)
            {
                if (parsed.type == ValueType.deletion)
                {
                    // 删除标记，跳过所有同键条目
                    Slice userKey = extractUserKey(ikey);
                    skip = true;
                    savedKey_ = userKey;
                }
                else if (parsed.type == ValueType.value)
                {
                    if (skip && userComparator_.compare(extractUserKey(ikey), savedKey_) <= 0)
                    {
                        // 跳过同键的旧版本
                    }
                    else
                    {
                        // 找到有效值
                        valid_ = true;
                        savedKey_ = extractUserKey(ikey);
                        Slice val = internalIter_.value();
                        savedValue_ = val.data()[0 .. val.size()].dup;
                        return;
                    }
                }
            }
            internalIter_.next();
        }
        valid_ = false;
    }

    /// 向后查找前一个用户键
    void findPrevUserEntry()
    {
        ValueType lastType = ValueType.value;
        Slice lastKey;

        while (internalIter_.valid())
        {
            Slice ikey = internalIter_.key();
            ParsedInternalKey parsed;
            if (!parseInternalKey(ikey, parsed))
            {
                status_ = statusCorruption("bad internal key");
                valid_ = false;
                return;
            }

            if (parsed.sequence <= sequence_)
            {
                Slice userKey = extractUserKey(ikey);
                if (userComparator_.compare(userKey, lastKey) != 0)
                {
                    // 新的用户键
                    if (lastType == ValueType.value)
                    {
                        valid_ = true;
                        savedKey_ = lastKey;
                        return;
                    }
                    lastType = ValueType.deletion;
                }
                lastKey = userKey;
                lastType = parsed.type;
            }
            internalIter_.prev();
        }

        // 检查最后一个键
        if (lastType == ValueType.value)
        {
            valid_ = true;
            savedKey_ = lastKey;
        }
        else
        {
            valid_ = false;
        }
    }

    /// 解析内部键
    bool parseInternalKey(Slice ikey, ref ParsedInternalKey parsed) nothrow @nogc
    {
        if (ikey.size() < ulong.sizeof)
            return false;
        parsed.userKey = Slice(ikey.data(), ikey.size() - ulong.sizeof);
        ulong tag = decodeFixed64(ikey.data() + ikey.size() - ulong.sizeof);
        parsed.sequence = unpackSequence(tag);
        parsed.type = unpackValueType(tag);
        return true;
    }
}

/// 创建数据库级迭代器
Iterator newDBIterator(Comparator userCmp, Iterator internalIter, ulong sequence)
{
    return new DBIter(userCmp, internalIter, sequence);
}

///
unittest
{
    import dleveldb.arena;
    import dleveldb.memtable;
    import dleveldb.comparator;

    // ====== DBIter.seek() 测试 ======
    // DBIter 包装内部键迭代器，处理删除标记和序列号覆盖

    auto icmp = InternalKeyComparator(defaultComparator());

    // --- 测试1: 基本seek定位 ---
    auto mem1 = new MemTable(icmp);
    mem1.addRef();
    mem1.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem1.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem1.add(3, ValueType.value, Slice("c"), Slice("vc"));

    Iterator internal1 = new MemTableIterator(mem1.tablePtr());
    // sequence=100 允许所有条目
    auto dbIter1 = new DBIter(defaultComparator(), internal1, 100);

    dbIter1.seek(Slice("b"));
    assert(dbIter1.valid());
    assert(dbIter1.key() == Slice("b"));
    assert(dbIter1.value() == Slice("vb"));

    dbIter1.seek(Slice("a"));
    assert(dbIter1.valid());
    assert(dbIter1.key() == Slice("a"));

    dbIter1.seek(Slice("c"));
    assert(dbIter1.valid());
    assert(dbIter1.key() == Slice("c"));

    // seek到不存在的键，定位到下一个
    dbIter1.seek(Slice("b0"));
    assert(dbIter1.valid());
    assert(dbIter1.key() == Slice("c"));

    // seek超出范围
    dbIter1.seek(Slice("z"));
    assert(!dbIter1.valid());

    // --- 测试2: 删除标记过滤 ---
    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem2.add(2, ValueType.deletion, Slice("b"), Slice());  // b被删除
    mem2.add(3, ValueType.value, Slice("c"), Slice("vc"));

    Iterator internal2 = new MemTableIterator(mem2.tablePtr());
    auto dbIter2 = new DBIter(defaultComparator(), internal2, 100);

    // seek "b" → 被删除，应跳到 "c"
    dbIter2.seek(Slice("b"));
    assert(dbIter2.valid());
    assert(dbIter2.key() == Slice("c"));

    // seek "a" → 正常
    dbIter2.seek(Slice("a"));
    assert(dbIter2.valid());
    assert(dbIter2.key() == Slice("a"));

    // seekToFirst 验证：a可见，b被删，c可见
    dbIter2.seekToFirst();
    assert(dbIter2.key() == Slice("a"));
    dbIter2.next();
    assert(dbIter2.key() == Slice("c"));
    dbIter2.next();
    assert(!dbIter2.valid());

    // --- 测试3: 序列号覆盖（新版本覆盖旧版本） ---
    auto mem3 = new MemTable(icmp);
    mem3.addRef();
    mem3.add(1, ValueType.value, Slice("x"), Slice("old"));  // seq=1 旧值
    mem3.add(2, ValueType.value, Slice("x"), Slice("new"));  // seq=2 新值

    Iterator internal3 = new MemTableIterator(mem3.tablePtr());
    auto dbIter3 = new DBIter(defaultComparator(), internal3, 100);

    dbIter3.seek(Slice("x"));
    assert(dbIter3.valid());
    assert(dbIter3.key() == Slice("x"));
    assert(dbIter3.value() == Slice("new"));  // 新版本覆盖旧版本

    // sequence=1 只能看到seq<=1的条目
    auto mem3b = new MemTable(icmp);
    mem3b.addRef();
    mem3b.add(1, ValueType.value, Slice("x"), Slice("old"));
    mem3b.add(2, ValueType.value, Slice("x"), Slice("new"));

    Iterator internal3b = new MemTableIterator(mem3b.tablePtr());
    auto dbIter3b = new DBIter(defaultComparator(), internal3b, 1);

    dbIter3b.seek(Slice("x"));
    assert(dbIter3b.valid());
    assert(dbIter3b.key() == Slice("x"));
    assert(dbIter3b.value() == Slice("old"));  // seq=2不可见，只能看到seq=1

    // --- 测试4: 先删后写（同键先deletion后value） ---
    auto mem4 = new MemTable(icmp);
    mem4.addRef();
    mem4.add(1, ValueType.deletion, Slice("k"), Slice());   // seq=1 删除
    mem4.add(2, ValueType.value, Slice("k"), Slice("val")); // seq=2 重新写入

    Iterator internal4 = new MemTableIterator(mem4.tablePtr());
    auto dbIter4 = new DBIter(defaultComparator(), internal4, 100);

    dbIter4.seek(Slice("k"));
    assert(dbIter4.valid());
    assert(dbIter4.key() == Slice("k"));
    assert(dbIter4.value() == Slice("val"));  // 新值覆盖删除

    // --- 测试5: seek后next遍历 ---
    auto mem5 = new MemTable(icmp);
    mem5.addRef();
    mem5.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem5.add(2, ValueType.deletion, Slice("b"), Slice());
    mem5.add(3, ValueType.value, Slice("c"), Slice("vc"));
    mem5.add(4, ValueType.value, Slice("d"), Slice("vd"));

    Iterator internal5 = new MemTableIterator(mem5.tablePtr());
    auto dbIter5 = new DBIter(defaultComparator(), internal5, 100);

    dbIter5.seek(Slice("a"));
    assert(dbIter5.key() == Slice("a"));
    dbIter5.next();
    assert(dbIter5.key() == Slice("c"));  // b被删，跳过
    dbIter5.next();
    assert(dbIter5.key() == Slice("d"));
    dbIter5.next();
    assert(!dbIter5.valid());

    // --- 测试6: 全部被删除 ---
    auto mem6 = new MemTable(icmp);
    mem6.addRef();
    mem6.add(1, ValueType.deletion, Slice("only"), Slice());

    Iterator internal6 = new MemTableIterator(mem6.tablePtr());
    auto dbIter6 = new DBIter(defaultComparator(), internal6, 100);

    dbIter6.seek(Slice("only"));
    assert(!dbIter6.valid());

    dbIter6.seekToFirst();
    assert(!dbIter6.valid());
}
