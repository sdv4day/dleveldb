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
    enum kMaxHeight = 12;
    enum kBranching = 4;

private:
    IAllocator allocator_;
    Cmp cmp_;
    Node* head_;
    int maxHeight_; // 原子访问

    struct Node
    {
        Key key;
        int height;
        // next_[0] ... next_[height-1]
        // 紧跟在结构体后面

        Node* next(int n)  @nogc
        {
            return (&next_[0])[n];
        }

        void setNext(int n, Node* x)  @nogc
        {
            (&next_[0])[n] = x;
        }

        // 原子读取next指针（无锁读）
        Node* nextAcquire(int n)
        {
            return atomicLoad!(MemoryOrder.acq)((&next_[0])[n]);
        }

        // 原子写入next指针（写端）
        void setNextRelease(int n, Node* x)
        {
            atomicStore!(MemoryOrder.rel)((&next_[0])[n], x);
        }

        // next数组占位（实际大小由height决定）
        Node*[1] next_;
    }

    /// 分配新节点（增强安全性检查）
    Node* newNode(Key key, int height) 
    {
        // 参数验证
        if (height < 1 || height > kMaxHeight)
        {
            assert(0, "SkipList: invalid height");
        }
        
        // 计算节点大小：Node基础 + (height-1)个next指针
        size_t nodeSize = Node.sizeof + (height - 1) * (Node*).sizeof;
        void[] mem = allocator_.allocate(nodeSize);

        // 内存分配检查
        if (mem is null || mem.ptr is null)
        {
            assert(0, "SkipList: out of memory");
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

    /// 随机高度（使用xorshift高质量随机数）
    int randomHeight()
    {
        // 使用函数级静态变量的xorshift128+随机数生成器
        // 比LCG质量更高，分布更均匀
        // 注意：static局部变量是函数级静态，非TLS；写操作在mutex_下串行化，安全
        static uint seed;
        if (seed == 0) 
        {
            // 初始化种子（使用D标准MonotonicTime替代core.stdc.time）
            import core.time : MonoTime;
            seed = cast(uint) MonoTime.currTime.ticks;
        }
        
        // xorshift算法（高质量快速随机数）
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;

        int height = 1;
        while (height < kMaxHeight && (seed & 0x3) == 0)
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
        return atomicLoad!(MemoryOrder.acq)(maxHeight_);
    }

    /// 查找key在每层的前驱节点
    /// prev[i] = 第i层中最后一个小于key的节点
    /// 返回：第0层中第一个>=key的节点
    Node* findGreaterOrEqual(Key key, Node** prev)  @nogc
    {
        Node* x = head_;
        int level = getMaxHeight() - 1;

        while (true)
        {
            Node* next = x.nextAcquire(level);
            if (next !is null && cmp_.compare(next.key, key) < 0)
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
        Node* x = head_;
        int level = getMaxHeight() - 1;

        while (true)
        {
            Node* next = x.nextAcquire(level);
            if (next is null || cmp_.compare(next.key, key) >= 0)
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
        Node* x = head_;
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
    /// 初始化（需手动调用，因为这是struct）
    void initialize(IAllocator allocator, Cmp cmp) 
    {
        allocator_ = allocator;
        cmp_ = cmp;
        maxHeight_ = 1;

        head_ = newNode(Key.init, kMaxHeight);
        for (int i = 0; i < kMaxHeight; i++)
        {
            head_.setNext(i, null);
        }
    }

    /// 插入键（需外部同步）
    void insert(Key key) 
    {
        Node*[kMaxHeight] prev;
        Node* found = findGreaterOrEqual(key, prev.ptr);

        // 不允许重复键
        assert(found is null || cmp_.compare(found.key, key) != 0);

        int height = randomHeight();
        if (height > getMaxHeight())
        {
            // 新节点高度超过当前最大高度
            for (int i = getMaxHeight(); i < height; i++)
            {
                prev[i] = head_;
            }
            atomicStore!(MemoryOrder.rel)(maxHeight_, height);
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
        if (x !is null && cmp_.compare(x.key, key) == 0)
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
        return head_.nextAcquire(0) is null;
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
    SkipList!(Key, Cmp)* list_;
    SkipList!(Key, Cmp).Node* node_;

public:
    this(SkipList!(Key, Cmp)* list)  @nogc
    {
        list_ = list;
        node_ = null;
    }

    bool valid() const 
    {
        return node_ !is null;
    }

    Key key() const 
    {
        assert(valid());
        return node_.key;
    }

    void next()  @nogc
    {
        assert(valid());
        node_ = node_.nextAcquire(0);
    }

    void prev()  @nogc
    {
        assert(valid());
        node_ = list_.findLessThan(node_.key);
    }

    void seek(Key target)  @nogc
    {
        node_ = list_.findGreaterOrEqual(target, null);
    }

    void seekToFirst()  @nogc
    {
        node_ = list_.head_.nextAcquire(0);
    }

    void seekToLast()  @nogc
    {
        node_ = list_.findLast();
        if (node_ == list_.head_)
            node_ = null;
    }
}
