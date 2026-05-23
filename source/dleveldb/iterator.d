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
    // 构建含多条数据的MemTable，通过MemTableIterator测试各种seek场景
    // 注意：MemTableIterator.seek 需要传入 memtable key 格式的 Slice
    //       即 LookupKey 格式：varint32(internalKeyLen) + userKey + packedTag

    auto icmp = InternalKeyComparator(defaultComparator());
    auto mem = new MemTable(icmp);
    mem.addRef();

    // 写入: a->va, b->vb, c->vc, d->vd
    mem.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem.add(3, ValueType.value, Slice("c"), Slice("vc"));
    mem.add(4, ValueType.value, Slice("d"), Slice("vd"));

    Iterator iter = new MemTableIterator(mem.tablePtr());

    // --- seek精确匹配（通过LookupKey构造memtable key格式） ---
    auto lkB = LookupKey(Slice("b"), 2);
    iter.seek(lkB.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("b"));

    auto lkA = LookupKey(Slice("a"), 1);
    iter.seek(lkA.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    auto lkD = LookupKey(Slice("d"), 4);
    iter.seek(lkD.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("d"));

    // --- seek到中间位置（匹配 >= target 的首条） ---
    // seek("b0") 应定位到 c（字节序 "b0" > "b"，下一个是 "c"）
    auto lkB0 = LookupKey(Slice("b0"), 5);
    iter.seek(lkB0.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("c"));

    // --- seek到最前之前 → 定位到首条 ---
    auto lk0 = LookupKey(Slice("0"), 5);
    iter.seek(lk0.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    // --- seek到最后之后 → 无效 ---
    auto lkZ = LookupKey(Slice("z"), 5);
    iter.seek(lkZ.memtableKey());
    assert(!iter.valid());

    // --- seek空键 → 定位到首条 ---
    auto lkEmpty = LookupKey(Slice(""), 5);
    iter.seek(lkEmpty.memtableKey());
    assert(iter.valid());
    assert(extractUserKey(iter.key()) == Slice("a"));

    // --- seek后再次seek验证可重入 ---
    auto lkB2 = LookupKey(Slice("b"), 5);
    iter.seek(lkB2.memtableKey());
    assert(iter.valid());

    auto lkC = LookupKey(Slice("c"), 5);
    iter.seek(lkC.memtableKey());
    assert(iter.valid());

    // --- 同键多版本seek（最新版本优先） ---
    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(1, ValueType.value, Slice("x"), Slice("old"));
    mem2.add(2, ValueType.value, Slice("x"), Slice("new"));

    Iterator iter2 = new MemTableIterator(mem2.tablePtr());
    auto lkX = LookupKey(Slice("x"), 2);
    iter2.seek(lkX.memtableKey());
    assert(iter2.valid());
    // 序列号2（更大）排在前面
    assert(extractUserKey(iter2.key()) == Slice("x"));

    // --- 删除标记seek ---
    auto mem3 = new MemTable(icmp);
    mem3.addRef();
    mem3.add(1, ValueType.value, Slice("k"), Slice("val"));
    mem3.add(2, ValueType.deletion, Slice("k"), Slice());

    Iterator iter3 = new MemTableIterator(mem3.tablePtr());
    auto lkK = LookupKey(Slice("k"), 2);
    iter3.seek(lkK.memtableKey());
    assert(iter3.valid());
    // 删除标记（seq=2）排在值（seq=1）前面
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
    auto mlkB = LookupKey(Slice("b"), 3);
    merged.seek(mlkB.memtableKey());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("b"));

    // seek "a" → 定位到 a
    auto mlkA = LookupKey(Slice("a"), 1);
    merged.seek(mlkA.memtableKey());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("a"));

    // seek "b0" → 字节序在b和c之间，应定位到c
    auto mlkB0 = LookupKey(Slice("b0"), 5);
    merged.seek(mlkB0.memtableKey());
    assert(merged.valid());
    assert(extractUserKey(merged.key()) == Slice("c"));

    // seek "z" → 超出所有键，无效
    auto mlkZ = LookupKey(Slice("z"), 5);
    merged.seek(mlkZ.memtableKey());
    assert(!merged.valid());

    // seek后完整遍历验证有序性（通过seekToFirst+next）
    merged.seekToFirst();
    assert(extractUserKey(merged.key()) == Slice("a"));
    merged.next();
    // MergingIterator.next 后找最小
    assert(merged.valid());
    merged.next();
    assert(merged.valid());
    merged.next();
    assert(merged.valid());
    merged.next();
    assert(!merged.valid());
}
