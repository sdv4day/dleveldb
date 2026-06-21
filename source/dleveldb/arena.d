module dleveldb.arena;

import std.experimental.allocator;
import std.experimental.allocator.mallocator : Mallocator;
import std.typecons : Ternary;
import core.exception : OutOfMemoryError;

/**
 * Arena内存池分配器
 * 按块分配内存，支持批量释放
 * 用于MemTable的SkipList节点分配
 * 实现IAllocator标准接口，底层分配器可参数化
 */
class Arena : IAllocator
{
private:
    IAllocator m_backend;    // 底层分配器（用于分配大块内存）
    ubyte[][] m_blocks;      // 已分配的内存块
    size_t m_allocPtr;       // 当前块中已分配的偏移
    size_t m_allocBytesRemain; // 当前块剩余字节数
    size_t m_memoryUsage;    // 总内存使用量
    size_t m_blocksMemory;   // 所有块的总内存（不含指针数组开销）

    enum blockSize = 4096; // 默认块大小4KB

public:
    /**
     * 构造Arena内存池分配器
     * Params: backend = 底层分配器，为null时使用Mallocator
     */
    this(IAllocator backend = null)
    {
        m_backend = backend;
        m_memoryUsage = 0;
        m_blocksMemory = 0;
        m_allocPtr = 0;
        m_allocBytesRemain = 0;
    }

    /// 析构函数，释放所有已分配的内存块
    ~this() nothrow
    {
        // 不在析构函数中调用deallocateAll(),避免GC回收时访问无效内存
        // 调用者应显式调用deallocateAll()
    }

    // === IAllocator 接口实现 ===

    override @property uint alignment() nothrow
    {
        return cast(uint)(void*).sizeof;
    }

    override size_t goodAllocSize(size_t s) nothrow
    {
        // 根据大小选择对齐策略，返回对齐后的大小
        size_t a = (s >= (void*).sizeof * 8) ? (void*).sizeof * 8 : (s >= (void*).sizeof * 2) ? (void*).sizeof * 2 : (void*).sizeof;
        return (s + a - 1) & ~(a - 1);
    }

    override void[] allocate(size_t bytes, TypeInfo ti = null) nothrow
    {
        if (bytes == 0) return null;

        // 根据大小选择对齐策略
        size_t a = (bytes >= (void*).sizeof * 8) ? (void*).sizeof * 8 : (bytes >= (void*).sizeof * 2) ? (void*).sizeof * 2 : (void*).sizeof;
        size_t alignedBytes = (bytes + a - 1) & ~(a - 1);

        if (alignedBytes <= m_allocBytesRemain)
        {
            // 当前块有足够空间
            void* result = m_blocks[$ - 1].ptr + m_allocPtr;
            m_allocPtr += alignedBytes;
            m_allocBytesRemain -= alignedBytes;
            return result[0 .. bytes];
        }

        return allocateFallback(alignedBytes, bytes);
    }

    override void[] alignedAllocate(size_t n, uint a) nothrow
    {
        if (n == 0) return null;

        // 确保指针对齐到a
        size_t currentMod = 0;

        if (m_blocks.length > 0)
        {
            currentMod = cast(size_t) (m_blocks[$ - 1].ptr + m_allocPtr) & (a - 1);
        }

        size_t slop = (currentMod == 0) ? 0 : a - currentMod;
        size_t needed = n + slop;

        void* result;
        if (needed <= m_allocBytesRemain)
        {
            result = m_blocks[$ - 1].ptr + m_allocPtr + slop;
            m_allocPtr += needed;
            m_allocBytesRemain -= needed;
        }
        else
        {
            auto mem = allocateFallback(n, n);
            return mem;
        }

        return result[0 .. n];
    }

    override void[] allocateAll() nothrow
    {
        // Arena不支持分配所有剩余内存
        return null;
    }

    override bool expand(ref void[] b, size_t size) nothrow
    {
        // Arena不支持原地扩展
        return false;
    }

    override bool reallocate(ref void[] b, size_t size) nothrow
    {
        // Arena不支持重新分配
        return false;
    }

    override bool alignedReallocate(ref void[] b, size_t size, uint a) nothrow
    {
        // Arena不支持对齐重新分配
        return false;
    }

    override Ternary owns(void[] b) nothrow
    {
        // 检查内存块是否属于Arena
        if (b.ptr is null) return Ternary.no;
        foreach (block; m_blocks)
        {
            if (b.ptr >= block.ptr && b.ptr < block.ptr + block.length)
            {
                return Ternary.yes;
            }
        }
        return Ternary.no;
    }

    override Ternary resolveInternalPointer(const void* p, ref void[] result) nothrow
    {
        // 查找指针所属的内存块
        foreach (block; m_blocks)
        {
            if (p >= block.ptr && p < block.ptr + block.length)
            {
                result = block;
                return Ternary.yes;
            }
        }
        return Ternary.unknown;
    }

    override bool deallocate(void[] b) nothrow
    {
        // Arena不支持单块释放，所有内存通过deallocateAll()批量释放
        return false;
    }

    override bool deallocateAll() nothrow
    {
        if (m_blocks is null) return true;

        foreach (block; m_blocks)
        {
            if (block.ptr !is null)
            {
                if (m_backend !is null)
                {
                    m_backend.deallocate(block);
                }
                else
                {
                    Mallocator.instance.deallocate(block);
                }
            }
        }
        m_blocks = null;
        m_allocPtr = 0;
        m_allocBytesRemain = 0;
        m_blocksMemory = 0;
        m_memoryUsage = 0;
        return true;
    }

    override Ternary empty() nothrow
    {
        return m_blocks.length == 0 ? Ternary.yes : Ternary.no;
    }

    override void incRef() nothrow @nogc @safe pure
    {
        // Arena是GC管理对象，引用计数由GC处理
    }

    override bool decRef() nothrow @nogc @safe pure
    {
        // Arena是GC管理对象，始终返回true（不自我销毁）
        return true;
    }

    // === Arena特有方法（向后兼容） ===

    /// 分配指定大小的内存，返回void*（向后兼容接口）
    void* allocatePtr(size_t bytes) nothrow
    {
        auto result = allocate(bytes);
        return result.ptr;
    }

    /// 分配对齐的内存，返回void*（向后兼容接口）
    void* allocateAlignedPtr(size_t bytes) nothrow
    {
        auto result = alignedAllocate(bytes, cast(uint)(void*).sizeof);
        return result.ptr;
    }

    /// 获取总内存使用量
    size_t memoryUsage() const nothrow @nogc
    {
        return m_memoryUsage;
    }

private:
    /// 获取底层分配器
    IAllocator getBackend() nothrow
    {
        if (m_backend !is null) return m_backend;
        // 使用Mallocator的IAllocator包装作为默认后端
        // 由于Mallocator.instance是shared struct，不能直接作为IAllocator
        // 此处返回null，由allocateFallback直接使用Mallocator
        return null;
    }

    /// 分配回退：分配新块或直接分配大块
    void[] allocateFallback(size_t alignedBytes, size_t originalBytes) nothrow
    {
        if (alignedBytes > blockSize / 4)
        {
            // 大块直接分配
            void[] mem;
            if (m_backend !is null)
            {
                mem = m_backend.allocate(alignedBytes);
            }
            else
            {
                mem = Mallocator.instance.allocate(alignedBytes);
            }

            if (mem.length == 0)
                throw new OutOfMemoryError("Arena::allocate: out of memory");

            auto block = cast(ubyte[]) mem;
            m_blocks ~= block;
            m_blocksMemory += alignedBytes;
            m_memoryUsage = m_blocksMemory + m_blocks.length * (void*).sizeof;
            return mem.ptr[0 .. originalBytes];
        }

        // 分配新块
        m_allocPtr = 0;
        m_allocBytesRemain = blockSize;

        void[] newBlock;
        if (m_backend !is null)
        {
            newBlock = m_backend.allocate(blockSize);
        }
        else
        {
            newBlock = Mallocator.instance.allocate(blockSize);
        }

        if (newBlock.length == 0)
            throw new OutOfMemoryError("Arena::allocate: out of memory");

        auto block = cast(ubyte[]) newBlock;
        m_blocks ~= block;
        m_blocksMemory += blockSize;
        m_memoryUsage = m_blocksMemory + m_blocks.length * (void*).sizeof;

        void* result = newBlock.ptr;
        m_allocPtr = alignedBytes;
        m_allocBytesRemain -= alignedBytes;
        return result[0 .. originalBytes];
    }
}

///
unittest
{
    import std.experimental.allocator : IAllocator;

    auto arena = new Arena();

    // 基本分配
    auto mem1 = arena.allocate(100);
    assert(mem1.ptr !is null);
    assert(mem1.length == 100);

    // 分配零字节
    auto mem0 = arena.allocate(0);
    assert(mem0 is null);

    // 多次分配
    auto mem2 = arena.allocate(200);
    auto mem3 = arena.allocate(300);
    assert(mem2.ptr !is null);
    assert(mem3.ptr !is null);
    assert(mem2.length == 200);
    assert(mem3.length == 300);

    // allocatePtr
    auto ptr1 = arena.allocatePtr(64);
    assert(ptr1 !is null);

    // memoryUsage 随分配增长
    auto usageBefore = arena.memoryUsage();
    arena.allocate(500);
    auto usageAfter = arena.memoryUsage();
    assert(usageAfter >= usageBefore);

    // owns 检查
    import std.typecons : Ternary;
    assert(arena.owns(mem1) == Ternary.yes);
    void[] foreign;
    assert(arena.owns(foreign) == Ternary.no);

    // deallocateAll
    assert(arena.deallocateAll());

    // empty
    assert(arena.empty() == Ternary.yes);
    arena.allocate(10);
    assert(arena.empty() == Ternary.no);

    // 大块分配（超过kBlockSize/4）
    auto bigMem = arena.allocate(4096);
    assert(bigMem.ptr !is null);
    assert(bigMem.length == 4096);

    // 新 Arena 测试 allocateAlignedPtr
    auto arena2 = new Arena();
    auto aptr = arena2.allocateAlignedPtr(32);
    assert(aptr !is null);
}

///
unittest
{
    // 内存压力测试：大量小对象分配
    auto arena = new Arena();
    size_t allocCount = 10_000;
    void[][] ptrs;
    ptrs.length = allocCount;
    
    foreach (i; 0 .. allocCount)
    {
        ptrs[i] = arena.allocate(64);
        assert(ptrs[i].ptr !is null);
        assert(ptrs[i].length == 64);
    }
    
    // 验证所有指针有效
    foreach (i; 0 .. allocCount)
    {
        assert(arena.owns(ptrs[i]) == Ternary.yes);
    }
    
    // 内存使用量应合理
    auto usage = arena.memoryUsage();
    assert(usage >= allocCount * 64);
    
    arena.deallocateAll();
    assert(arena.memoryUsage() == 0);
}

///
unittest
{
    // 边界测试：大块分配
    auto arena = new Arena();
    
    // 分配超过blockSize/4的大块
    auto big1 = arena.allocate(2000);
    assert(big1.ptr !is null);
    assert(big1.length == 2000);
    
    auto big2 = arena.allocate(5000);
    assert(big2.ptr !is null);
    assert(big2.length == 5000);
    
    auto big3 = arena.allocate(10000);
    assert(big3.ptr !is null);
    assert(big3.length == 10000);
    
    // 验证owns
    assert(arena.owns(big1) == Ternary.yes);
    assert(arena.owns(big2) == Ternary.yes);
    assert(arena.owns(big3) == Ternary.yes);
}

///
unittest
{
    // 边界测试：对齐分配
    auto arena = new Arena();
    
    // 不同对齐要求
    auto mem8 = arena.alignedAllocate(100, 8);
    assert(mem8.ptr !is null);
    assert((cast(size_t) mem8.ptr % 8) == 0);
    
    auto mem16 = arena.alignedAllocate(100, 16);
    assert(mem16.ptr !is null);
    assert((cast(size_t) mem16.ptr % 16) == 0);
    
    auto mem32 = arena.alignedAllocate(100, 32);
    assert(mem32.ptr !is null);
    assert((cast(size_t) mem32.ptr % 32) == 0);
    
    auto mem64 = arena.alignedAllocate(100, 64);
    assert(mem64.ptr !is null);
    assert((cast(size_t) mem64.ptr % 64) == 0);
}

///
unittest
{
    // 边界测试：goodAllocSize
    auto arena = new Arena();
    
    // 小对象对齐
    auto s1 = arena.goodAllocSize(1);
    assert(s1 >= 1);
    
    // 中等对象对齐
    auto s2 = arena.goodAllocSize(100);
    assert(s2 >= 100);
    
    // 大对象对齐
    auto s3 = arena.goodAllocSize(1000);
    assert(s3 >= 1000);
}

///
unittest
{
    // 边界测试：resolveInternalPointer
    auto arena = new Arena();
    
    auto mem = arena.allocate(1000);
    assert(mem.ptr !is null);
    
    // 内部指针解析
    void[] result;
    auto t = arena.resolveInternalPointer(mem.ptr, result);
    assert(t == Ternary.yes);
    assert(result.ptr !is null);
    
    // 指向中间的指针
    auto midPtr = mem.ptr + 500;
    t = arena.resolveInternalPointer(midPtr, result);
    assert(t == Ternary.yes);
    
    // 外部指针
    ubyte[100] externalBuf;
    t = arena.resolveInternalPointer(externalBuf.ptr, result);
    assert(t != Ternary.yes);
}

///
unittest
{
    // 边界测试：不支持的操作
    auto arena = new Arena();
    
    // expand不支持
    auto mem = arena.allocate(100);
    assert(!arena.expand(mem, 200));
    
    // reallocate不支持
    assert(!arena.reallocate(mem, 200));
    
    // alignedReallocate不支持
    assert(!arena.alignedReallocate(mem, 200, 8));
    
    // deallocate不支持（单块释放）
    assert(!arena.deallocate(mem));
    
    // allocateAll不支持
    auto all = arena.allocateAll();
    assert(all is null);
}

///
unittest
{
    // 混合大小分配测试
    auto arena = new Arena();
    
    // 交替分配大小对象
    void[][] smallPtrs;
    void[][] largePtrs;
    
    foreach (i; 0 .. 100)
    {
        auto small = arena.allocate(32);
        smallPtrs ~= small;
        assert(small.ptr !is null);
        
        if (i % 10 == 0)
        {
            auto large = arena.allocate(5000);
            largePtrs ~= large;
            assert(large.ptr !is null);
        }
    }
    
    // 验证所有分配有效
    foreach (p; smallPtrs)
        assert(arena.owns(p) == Ternary.yes);
    foreach (p; largePtrs)
        assert(arena.owns(p) == Ternary.yes);
    
    // 清理
    arena.deallocateAll();
    assert(arena.empty() == Ternary.yes);
}

///
unittest
{
    // 内存使用统计测试
    auto arena = new Arena();
    
    auto initialUsage = arena.memoryUsage();
    assert(initialUsage == 0);
    
    // 分配后内存增长
    arena.allocate(100);
    auto usage1 = arena.memoryUsage();
    assert(usage1 > 0);
    
    // 继续分配
    arena.allocate(1000);
    auto usage2 = arena.memoryUsage();
    assert(usage2 >= usage1);
    
    // 大块分配
    arena.allocate(10000);
    auto usage3 = arena.memoryUsage();
    assert(usage3 >= usage2);
    
    // 清理后归零
    arena.deallocateAll();
    assert(arena.memoryUsage() == 0);
}
