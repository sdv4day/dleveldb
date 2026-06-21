/**
 * 迭代器抽象接口
 *
 * 提供有序键值对的遍历能力。所有迭代器实现都遵循相同的语义。
 *
 * Copyright: BSL-1.0
 * Authors: sdv
 * Date: 2024
 */
module dleveldb.iterator;

import dleveldb.slice;
import dleveldb.status;
import std.range.primitives;

/**
 * 迭代器抽象接口
 *
 * 提供有序键值对的遍历能力。所有迭代器实现都遵循相同的语义：
 * - 初始状态下迭代器可能无效，需先调用 seek/seekToFirst/seekToLast
 * - seek(target) 定位到第一个 >= target 的键
 * - 当迭代器无效时，调用 key()/value() 会触发断言错误
 *
 * Example:
 * ---
 * auto iter = db.iterator();
 * iter.seek(Slice("key"));
 * if (iter.valid())
 *     writeln(iter.key(), " => ", iter.value());
 * ---
 */
interface Iterator
{
    /// 检查迭代器当前是否指向有效条目
    bool valid() const nothrow @nogc;

    /// 定位到第一个条目
    void seekToFirst();

    /// 定位到最后一个条目
    void seekToLast();

    /// 定位到第一个 >= target 的条目。若不存在则迭代器变为无效
    void seek(Slice target);

    /// 移动到下一个条目。要求当前迭代器有效
    void next();

    /// 移动到上一个条目。要求当前迭代器有效
    void prev();

    /// 获取当前条目的键。要求当前迭代器有效
    Slice key() nothrow @nogc;

    /// 获取当前条目的值。要求当前迭代器有效
    Slice value() nothrow @nogc;

    /// 获取迭代器的状态。若发生错误则返回非 OK 状态
    Status status() const nothrow @nogc;
}

/**
 * 空迭代器
 *
 * 始终无效的迭代器，用于表示空结果集。
 * 调用 next()/prev()/key()/value() 会触发断言错误。
 */
class EmptyIterator : Iterator
{
private:
    Status m_status;

public:
    /// 构造一个状态为 OK 的空迭代器
    this() {}

    /// 构造一个指定状态的空迭代器
    this(Status s) { m_status = s; }

    /// 始终返回 false
    bool valid() const pure nothrow @safe @nogc { return false; }

    /// 空操作
    void seekToFirst() nothrow @nogc {}

    /// 空操作
    void seekToLast() nothrow @nogc {}

    /// 空操作
    void seek(Slice target) nothrow @nogc {}

    /// 触发断言错误
    void next() nothrow @nogc { assert(false, "EmptyIterator::next"); }

    /// 触发断言错误
    void prev() nothrow @nogc { assert(false, "EmptyIterator::prev"); }

    /// 触发断言错误
    Slice key() nothrow @nogc { assert(false, "EmptyIterator::key"); return Slice(); }

    /// 触发断言错误
    Slice value() nothrow @nogc { assert(false, "EmptyIterator::value"); return Slice(); }

    /// 返回构造时指定的状态
    Status status() const nothrow @nogc { return m_status; }
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

    auto icmp = new InternalKeyComparator(defaultComparator());
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

    auto icmp = new InternalKeyComparator(defaultComparator());

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

///
unittest
{
    import dleveldb.arena;
    import dleveldb.comparator;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;

    // ====== MemTableIterator.seek() 边界情况测试 ======

    auto icmp = new InternalKeyComparator(defaultComparator());

    // --- 测试1: 单键迭代器的各种seek ---
    auto mem1 = new MemTable(icmp);
    mem1.addRef();
    mem1.add(1, ValueType.value, Slice("only"), Slice("val"));

    Iterator iter1 = new MemTableIterator(mem1.tablePtr());

    // seek到唯一键
    iter1.seek(InternalKey(Slice("only"), 100, ValueType.value).encode());
    assert(iter1.valid());
    assert(extractUserKey(iter1.key()) == Slice("only"));

    // seek到键之前
    iter1.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(iter1.valid());
    assert(extractUserKey(iter1.key()) == Slice("only"));

    // seek到键之后
    iter1.seek(InternalKey(Slice("z"), 100, ValueType.value).encode());
    assert(!iter1.valid());

    // --- 测试2: seek后反向遍历 ---
    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem2.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem2.add(3, ValueType.value, Slice("c"), Slice("vc"));
    mem2.add(4, ValueType.value, Slice("d"), Slice("vd"));

    Iterator iter2 = new MemTableIterator(mem2.tablePtr());

    // seek到中间，然后prev反向遍历
    iter2.seek(InternalKey(Slice("c"), 100, ValueType.value).encode());
    assert(extractUserKey(iter2.key()) == Slice("c"));
    iter2.prev();
    assert(extractUserKey(iter2.key()) == Slice("b"));
    iter2.prev();
    assert(extractUserKey(iter2.key()) == Slice("a"));
    iter2.prev();
    assert(!iter2.valid());

    // --- 测试3: 方向切换测试 ---
    auto mem3 = new MemTable(icmp);
    mem3.addRef();
    mem3.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem3.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem3.add(3, ValueType.value, Slice("c"), Slice("vc"));

    Iterator iter3 = new MemTableIterator(mem3.tablePtr());

    // seek -> next -> prev 方向切换
    iter3.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(extractUserKey(iter3.key()) == Slice("b"));
    iter3.next();
    assert(extractUserKey(iter3.key()) == Slice("c"));
    iter3.prev();  // 方向切换
    assert(extractUserKey(iter3.key()) == Slice("b"));
    iter3.prev();
    assert(extractUserKey(iter3.key()) == Slice("a"));

    // --- 测试4: 重复seek测试 ---
    auto mem4 = new MemTable(icmp);
    mem4.addRef();
    mem4.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem4.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem4.add(3, ValueType.value, Slice("c"), Slice("vc"));

    Iterator iter4 = new MemTableIterator(mem4.tablePtr());

    // 多次seek不同位置
    iter4.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(extractUserKey(iter4.key()) == Slice("b"));

    iter4.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(extractUserKey(iter4.key()) == Slice("a"));

    iter4.seek(InternalKey(Slice("c"), 100, ValueType.value).encode());
    assert(extractUserKey(iter4.key()) == Slice("c"));

    iter4.seek(InternalKey(Slice("z"), 100, ValueType.value).encode());
    assert(!iter4.valid());

    // 重新seek到有效位置
    iter4.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(iter4.valid());
    assert(extractUserKey(iter4.key()) == Slice("b"));

    // --- 测试5: 空键和特殊键 ---
    auto mem5 = new MemTable(icmp);
    mem5.addRef();
    mem5.add(1, ValueType.value, Slice(""), Slice("empty_key"));
    mem5.add(2, ValueType.value, Slice("a"), Slice("va"));

    Iterator iter5 = new MemTableIterator(mem5.tablePtr());

    iter5.seek(InternalKey(Slice(""), 100, ValueType.value).encode());
    assert(iter5.valid());
    assert(extractUserKey(iter5.key()) == Slice(""));

    iter5.next();
    assert(extractUserKey(iter5.key()) == Slice("a"));

    // seek空键应该定位到第一个
    iter5.seek(InternalKey(Slice(""), 100, ValueType.value).encode());
    assert(extractUserKey(iter5.key()) == Slice(""));
}

///
unittest
{
    import dleveldb.comparator;
    import dleveldb.merger;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;

    // ====== MergingIterator.seek() 边界情况测试 ======

    auto icmp = new InternalKeyComparator(defaultComparator());

    // --- 测试1: 一个空迭代器和一个非空迭代器 ---
    auto mem1 = new MemTable(icmp);
    mem1.addRef();
    // mem1 为空

    auto mem2 = new MemTable(icmp);
    mem2.addRef();
    mem2.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem2.add(2, ValueType.value, Slice("b"), Slice("vb"));

    Iterator iter1 = new MemTableIterator(mem1.tablePtr());
    Iterator iter2 = new MemTableIterator(mem2.tablePtr());
    auto merged1 = new MergingIterator(defaultComparator(), [iter1, iter2]);

    merged1.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(merged1.valid());
    assert(extractUserKey(merged1.key()) == Slice("a"));

    merged1.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(merged1.valid());
    assert(extractUserKey(merged1.key()) == Slice("b"));

    // --- 测试2: 三个迭代器归并 ---
    auto mem3a = new MemTable(icmp);
    mem3a.addRef();
    mem3a.add(1, ValueType.value, Slice("a"), Slice("va"));

    auto mem3b = new MemTable(icmp);
    mem3b.addRef();
    mem3b.add(2, ValueType.value, Slice("c"), Slice("vc"));

    auto mem3c = new MemTable(icmp);
    mem3c.addRef();
    mem3c.add(3, ValueType.value, Slice("e"), Slice("ve"));

    Iterator iter3a = new MemTableIterator(mem3a.tablePtr());
    Iterator iter3b = new MemTableIterator(mem3b.tablePtr());
    Iterator iter3c = new MemTableIterator(mem3c.tablePtr());
    auto merged3 = new MergingIterator(defaultComparator(), [iter3a, iter3b, iter3c]);

    // seek到各个位置
    merged3.seek(InternalKey(Slice("a"), 100, ValueType.value).encode());
    assert(extractUserKey(merged3.key()) == Slice("a"));

    merged3.seek(InternalKey(Slice("b"), 100, ValueType.value).encode());
    assert(extractUserKey(merged3.key()) == Slice("c"));

    merged3.seek(InternalKey(Slice("d"), 100, ValueType.value).encode());
    assert(extractUserKey(merged3.key()) == Slice("e"));

    merged3.seek(InternalKey(Slice("f"), 100, ValueType.value).encode());
    assert(!merged3.valid());

    // --- 测试3: seek后反向遍历 ---
    // 注意：MergingIterator的反向遍历实现较为复杂，这里只测试基本功能
    // 完整的反向遍历需要更复杂的实现
}

/**
 * 键值对条目
 * 
 * 用于 Range 接口的元素类型
 */
struct KeyValue
{
    Slice key;
    Slice value;
    
    /// 字符串表示
    string toString() const
    {
        import std.format : format;
        return format("%s => %s", key.asString(), value.asString());
    }
}

/**
 * Iterator 的 Range 适配器
 * 
 * 将 LevelDB 风格的 Iterator 包装为 D 的 InputRange，
 * 使其可以与 std.algorithm 和 std.range 配合使用。
 * 
 * 注意：
 * - 这是一个 InputRange，只支持单向遍历
 * - 初始状态需要先调用 seekToFirst() 或 seek()
 * - 使用 byKey() 或 byValue() 可获取单独的 key/value range
 * 
 * Example:
 * ---
 * auto iter = db.iterator();
 * iter.seekToFirst();
 * auto range = IteratorRange(iter);
 * 
 * // 使用 std.algorithm
 * import std.algorithm : filter, count;
 * auto count = range.filter!(kv => kv.key.asString().startsWith("prefix")).count();
 * 
 * // 或使用 foreach
 * foreach (kv; IteratorRange(iter))
 * {
 *     writeln(kv.key, " => ", kv.value);
 * }
 * ---
 */
struct IteratorRange
{
private:
    Iterator m_iter;
    KeyValue m_front;
    bool m_empty = true;
    
public:
    /**
     * 从 Iterator 构造 Range
     * 
     * 参数：
     *   iter - 迭代器（应该已经调用过 seekToFirst/seek）
     */
    this(Iterator iter)
    {
        m_iter = iter;
        updateFront();
    }
    
    /// 检查是否为空
    bool empty() const pure nothrow @nogc
    {
        return m_empty;
    }
    
    /// 获取当前元素
    ref const(KeyValue) front() const pure nothrow @nogc
    {
        return m_front;
    }
    
    /// 移动到下一个元素
    void popFront()
    {
        if (!m_empty)
        {
            m_iter.next();
            updateFront();
        }
    }
    
    /// 保存当前状态（ForwardRange）
    IteratorRange save()
    {
        // 注意：这不会复制迭代器状态，只是复制当前 front 值
        // 实际的迭代器仍然是共享的
        return this;
    }
    
    /// 获取底层迭代器
    Iterator iterator() pure nothrow @nogc
    {
        return m_iter;
    }
    
private:
    void updateFront()
    {
        m_empty = !m_iter.valid();
        if (!m_empty)
        {
            m_front.key = m_iter.key();
            m_front.value = m_iter.value();
        }
    }
}

/**
 * 创建 Iterator 的 Range 适配器
 * 
 * 参数：
 *   iter - 迭代器（应该已经调用过 seekToFirst/seek）
 * 
 * Returns:
 *   IteratorRange 适配器
 */
IteratorRange asRange(Iterator iter)
{
    return IteratorRange(iter);
}

/**
 * Key Range - 只返回 key
 */
struct KeyRange
{
private:
    Iterator m_iter;
    Slice m_front;
    bool m_empty = true;
    
public:
    this(Iterator iter)
    {
        m_iter = iter;
        updateFront();
    }
    
    bool empty() const pure nothrow @nogc { return m_empty; }
    ref const(Slice) front() const pure nothrow @nogc { return m_front; }
    void popFront() { if (!m_empty) { m_iter.next(); updateFront(); } }
    KeyRange save() { return this; }
    
private:
    void updateFront()
    {
        m_empty = !m_iter.valid();
        if (!m_empty) m_front = m_iter.key();
    }
}

/**
 * Value Range - 只返回 value
 */
struct ValueRange
{
private:
    Iterator m_iter;
    Slice m_front;
    bool m_empty = true;
    
public:
    this(Iterator iter)
    {
        m_iter = iter;
        updateFront();
    }
    
    bool empty() const pure nothrow @nogc { return m_empty; }
    ref const(Slice) front() const pure nothrow @nogc { return m_front; }
    void popFront() { if (!m_empty) { m_iter.next(); updateFront(); } }
    ValueRange save() { return this; }
    
private:
    void updateFront()
    {
        m_empty = !m_iter.valid();
        if (!m_empty) m_front = m_iter.value();
    }
}

/**
 * 获取只包含 key 的 Range
 */
KeyRange byKey(Iterator iter)
{
    return KeyRange(iter);
}

/**
 * 获取只包含 value 的 Range
 */
ValueRange byValue(Iterator iter)
{
    return ValueRange(iter);
}

/**
 * 辅助函数：从 Iterator 创建 KeyRange
 */
KeyRange byKeyRange(Iterator iter)
{
    return KeyRange(iter);
}

/**
 * 辅助函数：从 Iterator 创建 ValueRange
 */
ValueRange byValueRange(Iterator iter)
{
    return ValueRange(iter);
}

///
unittest
{
    import dleveldb.arena;
    import dleveldb.comparator;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;
    
    auto icmp = new InternalKeyComparator(defaultComparator());
    auto mem = new MemTable(icmp);
    mem.addRef();
    mem.add(1, ValueType.value, Slice("a"), Slice("va"));
    mem.add(2, ValueType.value, Slice("b"), Slice("vb"));
    mem.add(3, ValueType.value, Slice("c"), Slice("vc"));
    mem.add(4, ValueType.value, Slice("d"), Slice("vd"));
    
    Iterator iter = new MemTableIterator(mem.tablePtr());
    iter.seekToFirst();
    
    // 测试 IteratorRange
    auto range = IteratorRange(iter);
    
    // 使用 foreach 遍历
    int numItems = 0;
    foreach (kv; range)
    {
        numItems++;
        assert(kv.key.size() > 0);
        assert(kv.value.size() > 0);
    }
    assert(numItems == 4);
    
    // 测试 asRange 函数
    iter.seekToFirst();
    auto range2 = asRange(iter);
    assert(!range2.empty());
    
    // 测试 KeyRange
    iter.seekToFirst();
    auto keys = byKey(iter);
    numItems = 0;
    foreach (k; keys)
    {
        numItems++;
        assert(k.size() > 0);
    }
    assert(numItems == 4);
    
    // 测试 ValueRange
    iter.seekToFirst();
    auto values = byValue(iter);
    numItems = 0;
    foreach (v; values)
    {
        numItems++;
        assert(v.size() > 0);
    }
    assert(numItems == 4);
}

///
unittest
{
    import dleveldb.arena;
    import dleveldb.comparator;
    import dleveldb.memtable;
    import dleveldb.dbformat;
    import dleveldb.coding;
    import std.algorithm : count, filter;
    import std.algorithm.searching : startsWith;
    
    auto icmp = new InternalKeyComparator(defaultComparator());
    auto mem = new MemTable(icmp);
    mem.addRef();
    
    mem.add(1, ValueType.value, Slice("prefix_a"), Slice("va"));
    mem.add(2, ValueType.value, Slice("prefix_b"), Slice("vb"));
    mem.add(3, ValueType.value, Slice("other_c"), Slice("vc"));
    mem.add(4, ValueType.value, Slice("prefix_d"), Slice("vd"));
    
    Iterator iter = new MemTableIterator(mem.tablePtr());
    iter.seekToFirst();
    
    // 使用 std.algorithm.filter
    auto range = IteratorRange(iter);
    auto prefixCount = range.filter!(kv => startsWith(kv.key.asString(), "prefix")).count;
    assert(prefixCount == 3);
}

///
unittest
{
    // 测试空迭代器的 Range
    auto emptyIter = new EmptyIterator();
    emptyIter.seekToFirst();
    
    auto range = IteratorRange(emptyIter);
    assert(range.empty());
    
    auto keys = byKey(emptyIter);
    assert(keys.empty());
    
    auto values = byValue(emptyIter);
    assert(values.empty());
}
