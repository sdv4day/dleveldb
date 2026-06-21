module dleveldb.dbformat;

import dleveldb.slice;
import dleveldb.comparator;
import dleveldb.coding;

/**
 * 值类型
 */
enum ValueType : ubyte
{
    /// 删除类型
    deletion = 0,
    /// 值类型
    value = 1,
}

/// 最大序列号（56位）
enum ulong maxSequenceNumber = (1UL << 56) - 1;

/// packed tag 中值类型的位宽
private enum tagTypeBits = ubyte.sizeof * 8;

/// 提取packed tag中的序列号
ulong unpackSequence(ulong packedTag) pure nothrow @safe @nogc
{
    return packedTag >> tagTypeBits;
}

/// 提取packed tag中的值类型
ValueType unpackValueType(ulong packedTag) pure nothrow @safe @nogc
{
    return cast(ValueType) (packedTag & 0xff);
}

/// 打包序列号和值类型
ulong packSequenceAndType(ulong seq, ValueType type) pure nothrow @safe @nogc
{
    return (seq << tagTypeBits) | cast(ulong) type;
}

/**
 * 解析后的内部键
 */
struct ParsedInternalKey
{
    Slice userKey;
    ulong sequence;
    ValueType type;

    /// 返回调试用的字符串表示
    /// Returns: 格式为 "'userKey' @ sequence : TYPE" 的字符串
    string debugString() const
    {
        import std.conv : text;
        string typeStr = (type == ValueType.deletion) ? "DEL" : "VAL";
        return text("'", userKey.asString(), "' @ ", sequence, " : ", typeStr);
    }
}

/**
 * 内部键比较器
 * 比较顺序：先按userKey升序，再按sequence降序（新版本优先）
 */
class InternalKeyComparator : Comparator
{
private:
    Comparator userComparator_;

public:
    this(Comparator userCmp)
    {
        userComparator_ = userCmp;
    }

    /// 比较器名称（用于MANIFEST持久化）
    override string name() const
    {
        return userComparator_ is null ? "" : userComparator_.name();
    }

    /// 比较两个内部键的大小
    /// Params: a = 第一个内部键
    ///         b = 第二个内部键
    /// Returns: 小于0表示a<b，等于0表示a==b，大于0表示a>b
    override int compare(Slice a, Slice b) const nothrow @nogc
    {
        // 比较内部键：先比较userKey，再比较packedTag（降序）
        size_t aLen = a.size();
        size_t bLen = b.size();
        assert(aLen >= ulong.sizeof && bLen >= ulong.sizeof);

        // 比较userKey部分
        Slice aUserKey = Slice(a.data(), aLen - ulong.sizeof);
        Slice bUserKey = Slice(b.data(), bLen - ulong.sizeof);
        int r = userComparator_.compare(aUserKey, bUserKey);
        if (r != 0)
            return r;

        // 比较packedTag（降序：数值大的排在前面）
        ulong aTag = decodeFixed64(a.data() + aLen - ulong.sizeof);
        ulong bTag = decodeFixed64(b.data() + bLen - ulong.sizeof);
        if (aTag > bTag)
            return -1;
        else if (aTag < bTag)
            return 1;
        return 0;
    }

    /// 获取用户比较器
    Comparator userComparator() const nothrow @nogc { return cast(Comparator) userComparator_; }

    /// 比较InternalKey结构体
    int compareInternalKeys(ParsedInternalKey a, ParsedInternalKey b) const
    {
        int r = userComparator_.compare(a.userKey, b.userKey);
        if (r != 0)
            return r;
        if (a.sequence > b.sequence)
            return -1;
        else if (a.sequence < b.sequence)
            return 1;
        if (a.type > b.type)
            return -1;
        else if (a.type < b.type)
            return 1;
        return 0;
    }

    /// 查找短分隔符（用于SSTable索引块）
    override void findShortestSeparator(ref Slice start, Slice limit) const
    {
        size_t startLen = start.size();
        size_t limitLen = limit.size();
        assert(startLen >= ulong.sizeof && limitLen >= ulong.sizeof);

        Slice userStart = Slice(start.data(), startLen - ulong.sizeof);
        Slice userLimit = Slice(limit.data(), limitLen - ulong.sizeof);
        userComparator_.findShortestSeparator(userStart, userLimit);

        // 如果 userStart 被缩短，需要重新构建完整的 InternalKey
        // 因为索引键必须是有效的 InternalKey 格式
        if (userStart.size() < startLen - ulong.sizeof)
        {
            // 不缩短，保持原始键
            // 因为缩短后的键不是有效的 InternalKey
        }
    }

    /// 查找短后继键（用于SSTable索引块）
    override void findShortSuccessor(ref Slice key) const
    {
        size_t keyLen = key.size();
        assert(keyLen >= ulong.sizeof);

        Slice userKey = Slice(key.data(), keyLen - ulong.sizeof);
        userComparator_.findShortSuccessor(userKey);

        // 如果 userKey 被缩短，需要重新构建完整的 InternalKey
        // 因为索引键必须是有效的 InternalKey 格式
        if (userKey.size() < keyLen - ulong.sizeof)
        {
            // 不缩短，保持原始键
            // 因为缩短后的键不是有效的 InternalKey
        }
    }
}

/**
 * 内部键（编码后的字节序列）
 * 格式：user_key + uint64(seq<<8|type)
 */
struct InternalKey
{
    ubyte[] m_rep;

    /// 构造内部键
    /// Params: userKey = 用户键
    ///         seq = 序列号
    ///         type = 值类型
    this(Slice userKey, ulong seq, ValueType type)
    {
        m_rep.length = userKey.size() + ulong.sizeof;
        // 拷贝userKey
        m_rep[0 .. userKey.size()] = userKey.asBytes();
        // 编码packedTag
        encodeFixed64(m_rep.ptr + userKey.size(), packSequenceAndType(seq, type));
    }

    /// 编码为字节切片
    /// Returns: 内部键的字节表示
    Slice encode() const nothrow @nogc
    {
        return Slice(m_rep.ptr, m_rep.length);
    }

    /// 获取用户键部分
    /// Returns: 去除尾部packed tag后的用户键切片
    Slice userKey() const nothrow @nogc
    {
        assert(m_rep.length >= ulong.sizeof);
        return Slice(m_rep.ptr, m_rep.length - ulong.sizeof);
    }

    /// 从Slice设置内部键内容
    /// Params: s = 包含完整内部键编码的切片
    void setFrom(Slice s) nothrow
    {
        m_rep.length = s.size();
        m_rep[] = s.asBytes()[];
    }

    /// 检查内部键是否有效（长度至少包含一个packed tag）
    /// Returns: 有效返回true，否则false
    bool valid() const pure nothrow @safe @nogc
    {
        return m_rep.length >= ulong.sizeof;
    }

    /// 解析内部键，提取用户键、序列号和值类型
    /// Returns: 解析后的ParsedInternalKey
    ParsedInternalKey parse() const nothrow
    {
        assert(valid());
        ParsedInternalKey result;
        result.userKey = Slice(m_rep.ptr, m_rep.length - ulong.sizeof);
        ulong tag = decodeFixed64(m_rep.ptr + m_rep.length - ulong.sizeof);
        result.sequence = unpackSequence(tag);
        result.type = unpackValueType(tag);
        return result;
    }
}

/**
 * 查找键，用于MemTable查找
 * 格式：varint32(klength) + userkey + packedTag
 */
struct LookupKey
{
private:
    ubyte[] m_rep;
    size_t m_start;     // memtable_key起始位置
    size_t m_kstart;    // internal_key起始位置
    size_t m_end;       // 结束位置

public:
    /// 构造查找键
    /// Params: userKey = 用户键
    ///         sequence = 序列号
    this(Slice userKey, ulong sequence)
    {
        // 计算大小
        size_t internalKeySize = userKey.size() + ulong.sizeof;
        int varintLen = varintLength(cast(uint) internalKeySize);
        size_t totalSize = varintLen + internalKeySize;

        m_rep.length = totalSize;
        m_start = 0;
        m_kstart = varintLen;
        m_end = totalSize;

        // 编码varint32长度
        encodeVarint32(m_rep.ptr, cast(uint) internalKeySize);

        // 拷贝userKey
        m_rep[varintLen .. varintLen + userKey.size()] = userKey.asBytes();

        // 编码packedTag
        encodeFixed64(m_rep.ptr + varintLen + userKey.size(),
            packSequenceAndType(sequence, ValueType.value));
    }

    /// MemTable查找用的完整key
    Slice memtableKey() const nothrow @nogc
    {
        return Slice(m_rep.ptr + m_start, m_end - m_start);
    }

    /// 内部键部分
    Slice internalKey() const nothrow @nogc
    {
        return Slice(m_rep.ptr + m_kstart, m_end - m_kstart);
    }

    /// 用户键部分
    Slice userKey() const nothrow @nogc
    {
        return Slice(m_rep.ptr + m_kstart, m_end - m_kstart - ulong.sizeof);
    }
}

/**
 * 提取内部键中的用户键
 */
Slice extractUserKey(Slice internalKey) pure nothrow @safe @nogc
{
    assert(internalKey.size() >= ulong.sizeof);
    return Slice(internalKey.data(), internalKey.size() - ulong.sizeof);
}

/**
 * 提取内部键中的packed tag
 */
ulong extractPackedTag(Slice internalKey) nothrow @trusted @nogc
{
    assert(internalKey.size() >= ulong.sizeof);
    return decodeFixed64(internalKey.data() + internalKey.size() - ulong.sizeof);
}

/**
 * 配置常量
 * LSM树的层数
 */
enum int numLevels = 7;
/// L0层触发压缩的文件数阈值
enum int l0CompactionTrigger = 4;

/// L0层写入减速的文件数阈值
enum int l0SlowdownWritesTrigger = 8;

/// L0层停止写入的文件数阈值
enum int l0StopWritesTrigger = 12;

/// 内存压缩的最大层级
enum int maxMemCompactLevel = 2;

/// 读取字节数统计周期（1MB）
enum size_t readBytesPeriod = 1048576; // 1MB

///
unittest
{
    // packSequenceAndType / unpack 往返
    ulong seq = 100;
    auto vtype = ValueType.value;
    auto packed = packSequenceAndType(seq, vtype);
    assert(unpackSequence(packed) == seq);
    assert(unpackValueType(packed) == vtype);

    // deletion 类型
    auto packedDel = packSequenceAndType(200, ValueType.deletion);
    assert(unpackSequence(packedDel) == 200);
    assert(unpackValueType(packedDel) == ValueType.deletion);

    // 序列号0
    auto packed0 = packSequenceAndType(0, ValueType.value);
    assert(unpackSequence(packed0) == 0);

    // maxSequenceNumber
    auto packedMax = packSequenceAndType(maxSequenceNumber, ValueType.value);
    assert(unpackSequence(packedMax) == maxSequenceNumber);

    // InternalKey 构造与解析
    auto ikey = InternalKey(Slice("hello"), 10, ValueType.value);
    assert(ikey.valid());
    assert(ikey.userKey() == Slice("hello"));
    auto parsed = ikey.parse();
    assert(parsed.userKey == Slice("hello"));
    assert(parsed.sequence == 10);
    assert(parsed.type == ValueType.value);

    // InternalKey 删除标记
    auto ikeyDel = InternalKey(Slice("del_key"), 20, ValueType.deletion);
    auto parsedDel = ikeyDel.parse();
    assert(parsedDel.type == ValueType.deletion);
    assert(parsedDel.sequence == 20);

    // extractUserKey / extractPackedTag
    auto encoded = ikey.encode();
    assert(extractUserKey(encoded) == Slice("hello"));
    auto tag = extractPackedTag(encoded);
    assert(unpackSequence(tag) == 10);

    // LookupKey 构造
    auto lkey = LookupKey(Slice("mykey"), 5);
    assert(lkey.userKey() == Slice("mykey"));

    // InternalKeyComparator
    auto icmp = new InternalKeyComparator(defaultComparator());
    auto ik1 = InternalKey(Slice("a"), 1, ValueType.value).encode();
    auto ik2 = InternalKey(Slice("b"), 1, ValueType.value).encode();
    assert(icmp.compare(ik1, ik2) < 0);
    assert(icmp.compare(ik2, ik1) > 0);

    // 相同userKey不同seq：seq大的排在前面（降序）
    auto ik3 = InternalKey(Slice("a"), 2, ValueType.value).encode();
    auto ik4 = InternalKey(Slice("a"), 1, ValueType.value).encode();
    assert(icmp.compare(ik3, ik4) < 0); // seq=2排在seq=1前面

    // ParsedInternalKey debugString
    auto pik = ParsedInternalKey(Slice("test"), 5, ValueType.value);
    assert(pik.debugString().length > 0);

    // setFrom
    auto ikey2 = InternalKey(Slice("x"), 1, ValueType.value);
    ikey2.setFrom(ikey.encode());
    assert(ikey2.userKey() == Slice("hello"));
}
