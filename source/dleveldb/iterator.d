module dleveldb.iterator;

import dleveldb.slice;
import dleveldb.status;

/**
 * 迭代器抽象接口
 */
interface Iterator
{
    bool valid() const nothrow @nogc;
    void seekToFirst();
    void seekToLast();
    void seek(Slice target);
    void next();
    void prev();
    Slice key() nothrow @nogc;
    Slice value() nothrow @nogc;
    Status status() const nothrow @nogc;
}

/**
 * 空迭代器
 */
class EmptyIterator : Iterator
{
private:
    Status status_;

public:
    this() {}
    this(Status s) { status_ = s; }

    bool valid() const pure nothrow @safe @nogc { return false; }
    void seekToFirst() nothrow @nogc {}
    void seekToLast() nothrow @nogc {}
    void seek(Slice target) nothrow @nogc {}
    void next() nothrow @nogc { assert(false, "EmptyIterator::next"); }
    void prev() nothrow @nogc { assert(false, "EmptyIterator::prev"); }
    Slice key() nothrow @nogc { assert(false, "EmptyIterator::key"); return Slice(); }
    Slice value() nothrow @nogc { assert(false, "EmptyIterator::value"); return Slice(); }
    Status status() const nothrow @nogc { return status_; }
}

///
unittest
{
    // ====== EmptyIterator.seek() 测试 ======

    // 空迭代器 seek 后始终无效
    auto emptyIter = new EmptyIterator();
    emptyIter.seek(Slice("any"));
    assert(!emptyIter.valid());
    emptyIter.seek(Slice());
    assert(!emptyIter.valid());
    assert(emptyIter.status().ok());
}

///
unittest
{
    import dleveldb.arena;
    import dleveldb.comparator;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;

    // ====== MemTableIterator.seek() 测试 ======
    // MemTableIterator.seek(target) 接收 internal key 格式的 target
    // （即 userKey + packedTag），内部自动添加 varint32 长度前缀

    auto icmp = InternalKeyComparator(defaultComparator());
    auto mem = new MemTable(icmp);
    mem.addRef();

    // 写入: a->va, b->vb, c->vc, d->vd
    mem.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem.add(3, ValueType.value, Slice("c"), Slice("vc"));
    mem.add(4, ValueType.value, Slice("d"), Slice("vd"));

    Iterator iter = new MemTableIterator(mem.tablePtr());

    // --- seek精确匹配 ---
    iter.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("b"));

    iter.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    iter.seek(InternalKey(Slice("d"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("d"));

    // --- seek到中间位置（匹配 >= target 的首条） ---
    // seek("b0") 应定位到 c（字节序 "b0" > "b"，下一个是 "c"）
    iter.seek(InternalKey(Slice("b0"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("c"));

    // --- seek到最前之前 → 定位到首条 ---
    iter.seek(InternalKey(Slice("0"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    // --- seek到最后之后 → 无效 ---
    iter.seek(InternalKey(Slice("z"), 100, ValueType.value).encode());
    assert(!iter.valid());

    // --- seek空键 → 定位到首条 ---
    iter.seek(InternalKey(Slice(""), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    // --- seek后遍历验证 ---
    iter.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("b"));
    iter.next();
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("c"));
    iter.next();
    assert(extractUserKey(iter.key()) == Slice("d"));
    iter.next();
    assert(!iter.valid());

    // --- seekToFirst + next 全遍历 ---
    iter.seekToFirst();
    assert(extractUserKey(iter.key()) == Slice("a"));
    iter.next();
    assert(extractUserKey(iter.key()) == Slice("b"));
    iter.next();
    assert(extractUserKey(iter.key()) == Slice("c"));
    iter.next();
    assert(extractUserKey(iter.key()) == Slice("d"));
    iter.next();
    assert(!iter.valid());

    // --- seek与seekToFirst/seekToLast一致性 ---
    iter.seekToFirst();
    auto firstKey = extractUserKey(iter.key());
    iter.seek(InternalKey(firstKey, 100, ValueType.value).encode());
    assert(extractUserKey(iter.key()) == firstKey);

    iter.seekToLast();
    auto lastKey = extractUserKey(iter.key());
    iter.seek(InternalKey(lastKey, 100, ValueType.value).encode());
    assert(extractUserKey(iter.key()) == lastKey);

    // --- 同键多版本seek ---
    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(1, ValueType.value, Slice("x"), Slice("old"));
    mem2.add(2, ValueType.value, Slice("x"), Slice("new"));

    Iterator iter2 = new MemTableIterator(mem2.tablePtr());
    iter2.seek(InternalKey(Slice("x"), 100, ValueType.value).encode());
    assert(iter2.valid());
    assert(extractUserKey(iter2.key()) == Slice("x"));

    // --- 删除标记seek ---
    auto mem3 = new MemTable(icmp);
    mem3.addRef();
    mem3.add(1, ValueType.value, Slice("k"), Slice("val"));
    mem3.add(2, ValueType.deletion, Slice("k"), Slice());

    Iterator iter3 = new MemTableIterator(mem3.tablePtr());
    iter3.seek(InternalKey(Slice("k"), 100, ValueType.value).encode());
    assert(iter3.valid());
    assert(extractUserKey(iter3.key()) == Slice("k"));
}

///
unittest
{
    import dleveldb.comparator;
    import dleveldb.merger;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;

    // ====== MergingIterator.seek() 测试 ======
    // 两个MemTable归并，验证seek定位到所有子迭代器中的最小>=target

    auto icmp = InternalKeyComparator(defaultComparator());

    // MemTable1: a->va, c->vc
    auto mem1 = new MemTable(icmp);
    mem1.addRef();
    mem1.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem1.add(2, ValueType.value, Slice("c"), Slice("vc"));

    // MemTable2: b->vb, d->vd
    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(3, ValueType.value, Slice("b"), Slice("vb"));
    mem2.add(4, ValueType.value, Slice("d"), Slice("vd"));

    Iterator iter1 = new MemTableIterator(mem1.tablePtr());
    Iterator iter2 = new MemTableIterator(mem2.tablePtr());
    auto merged = new MergingIterator(defaultComparator(), [iter1, iter2]);

    // seek "b" → 应定位到 b
    merged.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("b"));

    // seek "a" → 定位到 a
    merged.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("a"));

    // seek "b0" → 字节序在b和c之间，应定位到c
    merged.seek(InternalKey(Slice("b0"), 100, ValueType.value).encode());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("c"));

    // seek "z" → 超出所有键，无效
    merged.seek(InternalKey(Slice("z"), 100, ValueType.value).encode());
    assert(!merged.valid());

    // seekToFirst后完整遍历验证有序性
    merged.seekToFirst();
    assert(extractUserKey(merged.key()) == Slice("a"));
    merged.next();
    assert(extractUserKey(merged.key()) == Slice("b"));
    merged.next();
    assert(extractUserKey(merged.key()) == Slice("c"));
    merged.next();
    assert(extractUserKey(merged.key()) == Slice("d"));
    merged.next();
    assert(!merged.valid());
}
