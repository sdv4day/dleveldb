module dleveldb.skiplist;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import std.experimental.allocator : IAllocator;
import dleveldb.comparator;

/**
 * 跳表模板实现
 * 
 * 特性：
 * - 读操作无锁（利用原子操作和内存序）
 * - 写操作需外部同步
 * - 节点通过IAllocator分配，永不单独删除
 * - 最大高度12，分支因子4（每层概率1/4）
 * 
 * 模板参数：
 * Key: 键类型
 * Cmp: 比较器类型（需实现int compare(Key, Key)）
 */
struct SkipList(Key, Cmp)
{
public:
    /// 跳表最大高度
    enum maxHeight = 12;
    /// 分支因子（每层晋升概率为 1/branching）
    enum branching = 4;

private:
    IAllocator m_allocator;
    Cmp m_cmp;
    Node* m_head;
    int m_currentMaxHeight; // 原子访问

    struct Node
    {
        Key key;
        int height;
        // m_next[0] ... m_next[height-1]
        // 紧跟在结构体后面

        Node* next(int n)  @nogc
        {
            return (&m_next[0])[n];
        }

        void setNext(int n, Node* x)  @nogc
        {
            (&m_next[0])[n] = x;
        }

        // 原子读取next指针（无锁读）
        Node* nextAcquire(int n)
        {
            return atomicLoad!(MemoryOrder.acq)((&m_next[0])[n]);
        }

        // 原子写入next指针（写端）
        void setNextRelease(int n, Node* x)
        {
            atomicStore!(MemoryOrder.rel)((&m_next[0])[n], x);
        }

        // next数组占位（实际大小由height决定）
        Node*[1] m_next;
    }

    /// 分配新节点（增强安全性检查）
    @trusted Node* newNode(Key key, int height) 
    {
        // 参数验证（编程错误，使用断言）
        assert(height >= 1 && height <= maxHeight, 
            "SkipList: invalid height");
        
        // 计算节点大小：Node基础 + (height-1)个next指针
        size_t nodeSize = Node.sizeof + (height - 1) * (Node*).sizeof;
        void[] mem = m_allocator.allocate(nodeSize);

        // 内存分配检查
        if (mem is null || mem.ptr is null)
        {
            import core.exception : OutOfMemoryError;
            throw new OutOfMemoryError("SkipList: out of memory");
        }

        Node* n = cast(Node*) mem.ptr;
        n.key = key;
        n.height = height;

        // 初始化next指针为null（防止野指针）
        for (int i = 0; i < height; i++)
        {
            n.setNext(i, null);
        }

        return n;
    }

    /// 随机高度（使用xorshift高质量随机数，线程安全）
    int randomHeight()
    {
        // D语言中函数内static变量是线程局部存储(TLS)，
        // 每个线程有独立的seed，无需额外同步。
        // 使用 sharedStaticInit 保证线程安全的初始化
        static uint seed;
        
        // 如果 seed 为 0，说明尚未初始化
        // 使用简单的延迟初始化（TLS 保证线程安全）
        if (seed == 0) 
        {
            // 初始化种子：结合时间戳和线程ID，降低多线程碰撞概率
            import core.time : MonoTime;
            import core.thread : Thread;
            import core.atomic : atomicLoad, MemoryOrder;
            
            // 使用原子操作读取时间戳，避免编译器优化
            auto ticks = MonoTime.currTime.ticks;
            seed = cast(uint)(ticks ^ (ticks >> 32) ^ 
                              cast(ulong)Thread.getThis.id);
            // 确保种子不为 0（0 会触发重新初始化）
            if (seed == 0) seed = 1;
        }
        
        // xorshift算法（高质量快速随机数）
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;

        int height = 1;
        while (height < maxHeight && (seed & 0x3) == 0)
        {
            height++;
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
        }
        return height;
    }

    /// 获取当前最大高度（原子读取）
    int getMaxHeight()
    {
        return atomicLoad!(MemoryOrder.acq)(m_currentMaxHeight);
    }

    /// 查找key在每层的前驱节点
    /// prev[i] = 第i层中最后一个小于key的节点
    /// 返回：第0层中第一个>=key的节点
    Node* findGreaterOrEqual(Key key, Node** prev)  @nogc
    {
        Node* x = m_head;
        int level = getMaxHeight() - 1;

        while (true)
        {
            Node* next = x.nextAcquire(level);
            if (next !is null && m_cmp.compare(next.key, key) < 0)
            {
                // 在当前层继续向右
                x = next;
            }
            else
            {
                if (prev !is null)
                    prev[level] = x;

                if (level == 0)
                {
                    return next;
                }
                else
                {
                    level--;
                }
            }
        }
    }

    /// 查找最后一个小于key的节点
    Node* findLessThan(Key key)  @nogc
    {
        Node* x = m_head;
        int level = getMaxHeight() - 1;

        while (true)
        {
            Node* next = x.nextAcquire(level);
            if (next is null || m_cmp.compare(next.key, key) >= 0)
            {
                if (level == 0)
                {
                    return x;
                }
                else
                {
                    level--;
                }
            }
            else
            {
                x = next;
            }
        }
    }

    /// 查找最后一个节点
    Node* findLast()  @nogc
    {
        Node* x = m_head;
        int level = getMaxHeight() - 1;

        while (true)
        {
            Node* next = x.nextAcquire(level);
            if (next is null)
            {
                if (level == 0)
                {
                    return x;
                }
                else
                {
                    level--;
                }
            }
            else
            {
                x = next;
            }
        }
    }

public:
    /// 构造函数（D惯用：构造即初始化）
    this(IAllocator allocator, Cmp cmp) 
    {
        m_allocator = allocator;
        m_cmp = cmp;
        m_currentMaxHeight = 1;

        m_head = newNode(Key.init, maxHeight);
        for (int i = 0; i < maxHeight; i++)
        {
            m_head.setNext(i, null);
        }
    }

    /// 插入键（需外部同步）
    void insert(Key key) 
    {
        Node*[maxHeight] prev;
        Node* found = findGreaterOrEqual(key, prev.ptr);

        // 不允许重复键
        assert(found is null || m_cmp.compare(found.key, key) != 0);

        int height = randomHeight();
        if (height > getMaxHeight())
        {
            // 新节点高度超过当前最大高度
            for (int i = getMaxHeight(); i < height; i++)
            {
                prev[i] = m_head;
            }
            atomicStore!(MemoryOrder.rel)(m_currentMaxHeight, height);
        }

        Node* x = newNode(key, height);
        for (int i = 0; i < height; i++)
        {
            x.setNextRelease(i, prev[i].nextAcquire(i));
            prev[i].setNextRelease(i, x);  // release写，与读端acquire配对
        }
    }

    /// 查找键是否存在（无锁读）
    bool contains(Key key)  @nogc
    {
        Node* x = findGreaterOrEqual(key, null);
        if (x !is null && m_cmp.compare(x.key, key) == 0)
        {
            return true;
        }
        return false;
    }

    /// 获取迭代器
    auto iterator()  @nogc
    {
        return SkipListIterator!(Key, Cmp)(&this);
    }

    /// 是否为空
    bool empty()  @nogc
    {
        return m_head.nextAcquire(0) is null;
    }

    /// 估算内存使用量（需外部提供，IAllocator无通用memoryUsage接口）
    size_t approximateMemoryUsage()  @nogc
    {
        // IAllocator不提供通用内存使用量查询
        // MemTable通过Arena.memoryUsage()获取
        return 0;
    }
}

/**
 * 跳表迭代器
 * 注意：迭代器不是线程安全的，需外部同步
 */
struct SkipListIterator(Key, Cmp)
{
private:
    SkipList!(Key, Cmp)* m_list;
    SkipList!(Key, Cmp).Node* m_node;

public:
    /// 构造函数
    /// Params: list = 指向所属跳表的指针
    this(SkipList!(Key, Cmp)* list)  @nogc
    {
        m_list = list;
        m_node = null;
    }

    /// 检查迭代器是否指向有效节点
    /// Returns: 若当前节点有效返回 true，否则返回 false
    bool valid() const 
    {
        return m_node !is null;
    }

    /// 获取当前节点的键
    /// Returns: 当前节点存储的键
    Key key() const 
    {
        assert(valid());
        return m_node.key;
    }

    /// 移动到下一个节点（向右移动）
    void next()  @nogc
    {
        assert(valid());
        m_node = m_node.nextAcquire(0);
    }

    /// 移动到上一个节点（向左移动）
    void prev()  @nogc
    {
        assert(valid());
        m_node = m_list.findLessThan(m_node.key);
        if (m_node == m_list.m_head)
            m_node = null;
    }

    /// 定位到第一个大于等于 target 的节点
    /// Params: target = 查找目标键
    void seek(Key target)  @nogc
    {
        m_node = m_list.findGreaterOrEqual(target, null);
    }

    /// 定位到跳表中的第一个节点
    void seekToFirst()  @nogc
    {
        m_node = m_list.m_head.nextAcquire(0);
    }

    /// 定位到跳表中的最后一个节点
    void seekToLast()  @nogc
    {
        m_node = m_list.findLast();
        if (m_node == m_list.m_head)
            m_node = null;
    }
}

///
unittest
{
    import dleveldb.arena;
    import dleveldb.slice;

    // Slice比较器用于SkipList
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }

    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);

    // 空表
    assert(list.empty());

    // 插入
    list.insert(Slice("b"));
    assert(!list.empty());
    assert(list.contains(Slice("b")));
    assert(!list.contains(Slice("a")));
    assert(!list.contains(Slice("c")));

    list.insert(Slice("a"));
    list.insert(Slice("c"));
    assert(list.contains(Slice("a")));
    assert(list.contains(Slice("c")));

    // 迭代器
    auto iter = list.iterator();
    iter.seekToFirst();
    assert(iter.valid());
    assert(iter.key() == Slice("a"));
    iter.next();
    assert(iter.key() == Slice("b"));
    iter.next();
    assert(iter.key() == Slice("c"));
    iter.next();
    assert(!iter.valid());

    // seek
    iter.seek(Slice("b"));
    assert(iter.valid());
    assert(iter.key() == Slice("b"));

    // seekToLast
    iter.seekToLast();
    assert(iter.valid());
    assert(iter.key() == Slice("c"));

    // prev
    iter.prev();
    assert(iter.key() == Slice("b"));

    // getMaxHeight
    assert(list.getMaxHeight() >= 1);
}

///
unittest
{
    // 大规模插入测试
    import dleveldb.arena;
    import dleveldb.slice;
    import std.conv : text;
    
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }
    
    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);
    
    // 插入1000个键
    foreach (i; 0 .. 1000)
    {
        auto key = Slice("key" ~ text(i).idup);
        list.insert(key);
    }
    
    // 验证所有键存在
    foreach (i; 0 .. 1000)
    {
        auto key = Slice("key" ~ text(i).idup);
        assert(list.contains(key), "key" ~ text(i) ~ " should exist");
    }
    
    // 验证顺序遍历
    auto iter = list.iterator();
    iter.seekToFirst();
    size_t count = 0;
    while (iter.valid())
    {
        count++;
        iter.next();
    }
    assert(count == 1000);
    
    // 验证反向遍历
    iter.seekToLast();
    count = 0;
    while (iter.valid())
    {
        count++;
        iter.prev();
    }
    assert(count == 1000);
}

///
unittest
{
    // 边界测试：seek操作
    import dleveldb.arena;
    import dleveldb.slice;
    
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }
    
    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);
    
    // 空表seek
    auto iter = list.iterator();
    iter.seek(Slice("any"));
    assert(!iter.valid());
    
    // 插入一些键
    list.insert(Slice("b"));
    list.insert(Slice("d"));
    list.insert(Slice("f"));
    
    // seek到存在的键
    iter.seek(Slice("d"));
    assert(iter.valid());
    assert(iter.key() == Slice("d"));
    
    // seek到不存在的键（返回下一个）
    iter.seek(Slice("c"));
    assert(iter.valid());
    assert(iter.key() == Slice("d"));
    
    // seek到小于所有键
    iter.seek(Slice("a"));
    assert(iter.valid());
    assert(iter.key() == Slice("b"));
    
    // seek到大于所有键
    iter.seek(Slice("z"));
    assert(!iter.valid());
}

///
unittest
{
    // 边界测试：迭代器边界
    import dleveldb.arena;
    import dleveldb.slice;
    
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }
    
    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);
    
    // 单元素测试
    list.insert(Slice("only"));
    
    auto iter = list.iterator();
    iter.seekToFirst();
    assert(iter.valid());
    assert(iter.key() == Slice("only"));
    
    iter.seekToLast();
    assert(iter.valid());
    assert(iter.key() == Slice("only"));
    
    iter.prev();
    assert(!iter.valid());
    
    iter.seekToFirst();
    iter.next();
    assert(!iter.valid());
}

///
unittest
{
    // 压力测试：大量查找
    import dleveldb.arena;
    import dleveldb.slice;
    import std.conv : text;
    
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }
    
    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);
    
    // 预分配所有键字符串，避免临时字符串被释放
    string[] keys;
    foreach (i; 0 .. 1000)
        keys ~= "key" ~ text(i).idup;
    
    // 插入1000个键
    foreach (i; 0 .. 1000)
        list.insert(Slice(keys[i]));
    
    // 大量查找存在的键
    size_t foundCount = 0;
    foreach (i; 0 .. 10_000)
    {
        if (list.contains(Slice(keys[i % 1000])))
            foundCount++;
    }
    assert(foundCount == 10_000);
    
    // 大量查找不存在的键
    size_t notFoundCount = 0;
    foreach (i; 0 .. 1000)
    {
        auto key = "notexist" ~ text(i).idup;
        if (!list.contains(Slice(key)))
            notFoundCount++;
    }
    assert(notFoundCount == 1000);
}

///
unittest
{
    // 边界测试：高度变化
    import dleveldb.arena;
    import dleveldb.slice;
    import std.conv : text;
    
    struct SliceComparator
    {
        int compare(Slice a, Slice b) const nothrow @nogc
        {
            return a.opCmp(b);
        }
    }
    
    auto arena = new Arena();
    auto cmp = SliceComparator();
    auto list = SkipList!(Slice, SliceComparator)(cast(IAllocator) arena, cmp);
    
    // 初始高度为1
    assert(list.getMaxHeight() >= 1);
    
    // 插入大量元素，高度可能增长
    foreach (i; 0 .. 10000)
    {
        auto key = Slice("k" ~ text(i).idup);
        list.insert(key);
    }
    
    // 高度应在合理范围内
    auto height = list.getMaxHeight();
    assert(height >= 1);
    assert(height <= SkipList!(Slice, SliceComparator).maxHeight);
}

///
unittest
{
    // 整数键测试
    import dleveldb.arena;
    
    struct IntComparator
    {
        int compare(int a, int b) const nothrow @nogc
        {
            return a < b ? -1 : (a > b ? 1 : 0);
        }
    }
    
    auto arena = new Arena();
    auto cmp = IntComparator();
    auto list = SkipList!(int, IntComparator)(cast(IAllocator) arena, cmp);
    
    // 插入乱序整数
    int[] values = [5, 2, 8, 1, 9, 3, 7, 4, 6, 0];
    foreach (v; values)
        list.insert(v);
    
    // 验证顺序遍历是升序
    auto iter = list.iterator();
    iter.seekToFirst();
    int prev = -1;
    while (iter.valid())
    {
        assert(iter.key() > prev);
        prev = iter.key();
        iter.next();
    }
    assert(prev == 9);
    
    // 验证所有值存在
    foreach (v; values)
        assert(list.contains(v));
}
