module dleveldb.memtable;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.dbformat;
import dleveldb.arena;
import dleveldb.skiplist;
import dleveldb.coding;
import dleveldb.comparator;
import dleveldb.iterator;
import std.experimental.allocator : IAllocator;
import core.atomic : atomicFetchAdd, atomicFetchSub;

/**
 * MemTable键比较器
 * 比较MemTable中存储的键格式：varint32(key_length+8) + user_key + packed_tag
 */
struct MemTableKeyComparator
{
    InternalKeyComparator icmp;

    int compare(const(char)* a, const(char)* b) const nothrow @nogc
    {
        // 优化：内联varint32解码，减少函数调用开销
        const(ubyte)* ap = cast(const(ubyte)*) a;
        const(ubyte)* bp = cast(const(ubyte)*) b;
        
        // 快速路径：单字节varint（最常见情况）
        uint aLen, bLen;
        const(ubyte)* aStart = ap;
        const(ubyte)* bStart = bp;
        
        // 解码a的varint32
        if ((*ap & 0x80) == 0)
        {
            // 单字节varint
            aLen = *ap;
            aStart = ap + 1;
        }
        else
        {
            // 多字节varint，回退到标准解码
            const(ubyte)* tmp = ap;
            if (!decodeVarint32(tmp, tmp + 10, aLen))
            {
                // 解码失败，按空键处理
                aLen = 0;
                aStart = tmp;
            }
        }
        
        // 解码b的varint32
        if ((*bp & 0x80) == 0)
        {
            // 单字节varint
            bLen = *bp;
            bStart = bp + 1;
        }
        else
        {
            // 多字节varint，回退到标准解码
            const(ubyte)* tmp = bp;
            if (!decodeVarint32(tmp, tmp + 10, bLen))
            {
                // 解码失败，按空键处理
                bLen = 0;
                bStart = tmp;
            }
        }
        
        // 直接比较内部键
        Slice aKey = Slice(aStart, aLen);
        Slice bKey = Slice(bStart, bLen);
        
        return icmp.compare(aKey, bKey);
    }
}

/**
 * MemTable：内存中的有序键值表
 * 基于SkipList实现，引用计数管理生命周期
 * 读操作无锁，写操作需外部同步
 */
class MemTable
{
private:
    Arena arena_;           // Arena内存池（同时作为IAllocator）
    IAllocator allocator_;  // 分配器接口引用
    SkipList!(const(char)*, MemTableKeyComparator) table_;
    MemTableKeyComparator cmp_;
    int refs_;

public:
    this(InternalKeyComparator icmp, IAllocator allocator = null)
    {
        arena_ = new Arena(allocator);
        allocator_ = cast(IAllocator) arena_;
        cmp_ = MemTableKeyComparator(icmp);
        table_ = SkipList!(const(char)*, MemTableKeyComparator)(allocator_, cmp_);
        refs_ = 1;
    }

    ~this()
    {
        // 引用计数不为0时由GC回收,跳过断言
        // 正常路径应通过unref()释放
    }

    /// 增加引用（原子操作）
    void addRef()  @nogc nothrow
    {
        atomicFetchAdd(refs_, 1);
    }

    /// 减少引用，返回是否已销毁（原子操作）
    bool unref() nothrow
    {
        auto prev = atomicFetchSub(refs_, 1);
        assert(prev > 0);
        return prev == 1;
    }

    /// 添加键值对
    /// seq: 序列号
    /// type: 值类型（kTypeValue或kTypeDeletion）
    /// key: 用户键
    /// value: 值
    @trusted void add(ulong seq, ValueType type, Slice key, Slice value) 
    {
        // 编码格式：varint32(key_size+8) + user_key + packed_tag + varint32(val_size) + value
        size_t keySize = key.size();
        size_t valSize = value.size();
        size_t internalKeySize = keySize + ulong.sizeof;
        
        // 快速路径：大多数 internalKeySize 和 valSize 都很小（< 128），直接判断为单字节
        int varintKeyLen = (internalKeySize < 128) ? 1 : varintLength(cast(uint) internalKeySize);
        int varintValLen = (valSize < 128) ? 1 : varintLength(cast(uint) valSize);
        size_t encodedLen = varintKeyLen + internalKeySize + varintValLen + valSize;

        // 通过IAllocator分配内存
        char* buf = cast(char*) allocator_.allocate(encodedLen).ptr;
        char* p = buf;

        // 编码varint32(internal_key_size) - 快速路径
        if (internalKeySize < 128)
        {
            *cast(ubyte*)p = cast(ubyte)internalKeySize;
            p += 1;
        }
        else
        {
            p += encodeVarint32(cast(ubyte*) p, cast(uint) internalKeySize);
        }

        // 拷贝user_key（使用D标准数组切片拷贝）
        (cast(ubyte*) p)[0 .. keySize] = key.asBytes();
        p += keySize;

        // 编码packed_tag
        encodeFixed64(cast(ubyte*) p, packSequenceAndType(seq, type));
        p += ulong.sizeof;

        // 编码varint32(val_size) - 快速路径
        if (valSize < 128)
        {
            *cast(ubyte*)p = cast(ubyte)valSize;
            p += 1;
        }
        else
        {
            p += encodeVarint32(cast(ubyte*) p, cast(uint) valSize);
        }

        // 拷贝value（使用D标准数组切片拷贝）
        if (valSize > 0)
        {
            (cast(ubyte*) p)[0 .. valSize] = value.asBytes();
        }

        // 插入SkipList
        table_.insert(buf);
    }

    /// 查找键
    /// 返回true表示找到（包括删除标记）
    bool get(LookupKey key, ref ubyte[] value, ref Status status)
    {
        Slice memKey = key.memtableKey();
        // 在SkipList中查找>=memKey的条目
        // 由于SkipList的findGreaterOrEqual是内部方法，
        // 我们使用迭代器来查找

        auto iter = table_.iterator();
        iter.seek(memKey.asString().ptr);

        if (iter.valid())
        {
            // 检查是否匹配
            const(char)* entry = iter.key();
            const(ubyte)* entryPtr = cast(const(ubyte)*) entry;

            // 解码varint32获取internal_key长度
            uint internalKeyLen;
            if (!decodeVarint32(entryPtr, entryPtr + 10, internalKeyLen))
                return false;

            // 比较user_key
            size_t userKeyLen = internalKeyLen - ulong.sizeof;
            Slice entryUserKey = Slice(entryPtr, userKeyLen);
            if (entryUserKey == key.userKey())
            {
                // 匹配！检查类型
                ulong packedTag = decodeFixed64(entryPtr + userKeyLen);
                ValueType vtype = unpackValueType(packedTag);

                if (vtype == ValueType.deletion)
                {
                    // 删除标记
                    status = statusNotFound("");
                    return true;
                }
                else
                {
                    // 值类型，解码value
                    const(ubyte)* valStart = entryPtr + internalKeyLen;
                    uint valLen;
                    if (decodeVarint32(valStart, valStart + 10, valLen))
                    {
                        value.length = valLen;
                        value[] = valStart[0 .. valLen];
                        status = Status();
                        return true;
                    }
                }
            }
        }

        return false;
    }

    /// 获取迭代器
    auto iterator()  @nogc
    {
        return table_.iterator();
    }

    /// 估算内存使用量
    size_t approximateMemoryUsage()  @nogc
    {
        return arena_.memoryUsage();
    }

    /// 获取内部键比较器
    const(InternalKeyComparator) internalKeyComparator() const nothrow @nogc
    {
        return cmp_.icmp;
    }

    /// 获取SkipList的指针（用于创建迭代器）
    auto tablePtr()  @nogc
    {
        return &table_;
    }
}

/**
 * MemTable迭代器
 * 将SkipList迭代器包装为内部键迭代器
 */
class MemTableIterator : Iterator
{
private:
    SkipListIterator!(const(char)*, MemTableKeyComparator) iter_;
    bool valid_;
    ubyte[] encodeBuf_;  // seek时构造varint32前缀的临时缓冲区

public:
    /// 构造 MemTable 迭代器
    this(SkipList!(const(char)*, MemTableKeyComparator)* list)
    {
        iter_ = list.iterator();
        valid_ = false;
    }

    /// 检查当前是否指向有效条目
    bool valid() const nothrow @nogc { return iter_.valid(); }

    /// 定位到第一个条目
    void seekToFirst()  @nogc { iter_.seekToFirst(); }

    /// 定位到最后一个条目
    void seekToLast()  @nogc { iter_.seekToLast(); }

    /// seek到>=target的首条（target为internal key格式）
    /// 需要添加varint32长度前缀以匹配SkipList中存储的memtable key格式
    void seek(Slice target)
    {
        // EncodeKey: varint32(target.size()) + target
        // 与C++ leveldb的EncodeKey()一致
        size_t targetSize = target.size();
        int varintLen = varintLength(cast(uint) targetSize);
        encodeBuf_.length = varintLen + targetSize;
        encodeVarint32(encodeBuf_.ptr, cast(uint) targetSize);
        if (targetSize > 0)
        {
            encodeBuf_[varintLen .. varintLen + targetSize] = target.asBytes();
        }
        iter_.seek(cast(const(char)*) encodeBuf_.ptr);
    }

    /// 移动到下一个条目
    void next()  @nogc { iter_.next(); }

    /// 移动到上一个条目
    void prev()  @nogc { iter_.prev(); }

    /// 获取当前条目的内部键（跳过varint32长度前缀）
    Slice key() nothrow @nogc
    {
        // 返回内部键部分（跳过varint32长度前缀）
        const(char)* entry = iter_.key();
        const(ubyte)* p = cast(const(ubyte)*) entry;
        uint len;
        if (decodeVarint32(p, p + 10, len))
        {
            return Slice(p, len);
        }
        return Slice();
    }

    /// 获取当前条目的值
    Slice value() nothrow @nogc
    {
        // 返回值部分
        const(char)* entry = iter_.key();
        const(ubyte)* p = cast(const(ubyte)*) entry;
        uint internalKeyLen;
        if (decodeVarint32(p, p + 10, internalKeyLen))
        {
            const(ubyte)* valStart = p + internalKeyLen;
            uint valLen;
            if (decodeVarint32(valStart, valStart + 10, valLen))
            {
                return Slice(valStart, valLen);
            }
        }
        return Slice();
    }

    /// 获取迭代器状态（始终返回 OK）
    Status status() const nothrow @nogc
    {
        return Status();
    }
}
