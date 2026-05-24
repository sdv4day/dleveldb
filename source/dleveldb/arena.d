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
    IAllocator backend_;    // 底层分配器（用于分配大块内存）
    ubyte[][] blocks_;      // 已分配的内存块
    size_t allocPtr_;       // 当前块中已分配的偏移
    size_t allocBytesRemain_; // 当前块剩余字节数
    size_t memoryUsage_;    // 总内存使用量

    enum kBlockSize = 4096; // 默认块大小4KB

public:
    /// 构造Arena内存池分配器
    /// Params: backend = 底层分配器，为null时使用Mallocator
    this(IAllocator backend = null)
    {
        backend_ = backend;
        memoryUsage_ = 0;
        allocPtr_ = 0;
        allocBytesRemain_ = 0;
    }

    /// 析构函数，释放所有已分配的内存块
    ~this() nothrow
    {
        // MemTable持有对Arena的引用(arena_字段)，GC会跟随引用链，
        // 因此不会在MemTable之前回收Arena。
        // 显式释放所有分配的内存块。
        deallocateAll();
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

        

        if (alignedBytes <= allocBytesRemain_)
        {
            // 当前块有足够空间
            void* result = blocks_[$ - 1].ptr + allocPtr_;
            allocPtr_ += alignedBytes;
            allocBytesRemain_ -= alignedBytes;
            return result[0 .. bytes];
        }

        return allocateFallback(alignedBytes, bytes);
    }

    override void[] alignedAllocate(size_t n, uint a) nothrow
    {
        if (n == 0) return null;

        // 确保指针对齐到a
        size_t currentMod = 0;

        if (blocks_.length > 0)
        {
            currentMod = cast(size_t) (blocks_[$ - 1].ptr + allocPtr_) & (a - 1);
        }

        size_t slop = (currentMod == 0) ? 0 : a - currentMod;
        size_t needed = n + slop;

        void* result;
        if (needed <= allocBytesRemain_)
        {
            result = blocks_[$ - 1].ptr + allocPtr_ + slop;
            allocPtr_ += needed;
            allocBytesRemain_ -= needed;
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
        foreach (block; blocks_)
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
        foreach (block; blocks_)
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
        if (blocks_ is null) return true;

        foreach (block; blocks_)
        {
            if (block.ptr !is null)
            {
                if (backend_ !is null)
                {
                    backend_.deallocate(block);
                }
                else
                {
                    Mallocator.instance.deallocate(block);
                }
            }
        }
        blocks_ = null;
        allocPtr_ = 0;
        allocBytesRemain_ = 0;
        memoryUsage_ = 0;
        return true;
    }

    override Ternary empty() nothrow
    {
        return blocks_.length == 0 ? Ternary.yes : Ternary.no;
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
        return memoryUsage_;
    }

private:
    /// 获取底层分配器
    IAllocator getBackend() nothrow
    {
        if (backend_ !is null) return backend_;
        // 使用Mallocator的IAllocator包装作为默认后端
        // 由于Mallocator.instance是shared struct，不能直接作为IAllocator
        // 此处返回null，由allocateFallback直接使用Mallocator
        return null;
    }

    /// 分配回退：分配新块或直接分配大块
    void[] allocateFallback(size_t alignedBytes, size_t originalBytes) nothrow
    {
        if (alignedBytes > kBlockSize / 4)
        {
            // 大块直接分配
            void[] mem;
            if (backend_ !is null)
            {
                mem = backend_.allocate(alignedBytes);
            }
            else
            {
                mem = Mallocator.instance.allocate(alignedBytes);
            }

            if (mem.length == 0)
                throw new OutOfMemoryError("Arena::allocate: out of memory");

            auto block = cast(ubyte[]) mem;
            blocks_ ~= block;
            memoryUsage_ += alignedBytes + blocks_.length * (void*).sizeof;
            return mem.ptr[0 .. originalBytes];
        }

        // 分配新块
        allocPtr_ = 0;
        allocBytesRemain_ = kBlockSize;

        void[] newBlock;
        if (backend_ !is null)
        {
            newBlock = backend_.allocate(kBlockSize);
        }
        else
        {
            newBlock = Mallocator.instance.allocate(kBlockSize);
        }

        if (newBlock.length == 0)
            throw new OutOfMemoryError("Arena::allocate: out of memory");

        auto block = cast(ubyte[]) newBlock;
        blocks_ ~= block;
        memoryUsage_ += kBlockSize + blocks_.length * (void*).sizeof;

        void* result = newBlock.ptr;
        allocPtr_ = alignedBytes;
        allocBytesRemain_ -= alignedBytes;
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
