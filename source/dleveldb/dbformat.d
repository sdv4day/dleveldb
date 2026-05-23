module dleveldb.dbformat;

import dleveldb.slice;
import dleveldb.comparator;
import dleveldb.coding;

/**
 * 值类型
 */
enum ValueType : ubyte
{
    deletion = 0,
    value = 1,
}

/// 最大序列号（56位）
enum ulong kMaxSequenceNumber = (1UL << 56) - 1;

/// packed tag 中值类型的位宽
private enum kTagTypeBits = ubyte.sizeof * 8;

/// 提取packed tag中的序列号
ulong unpackSequence(ulong packedTag) pure nothrow @safe @nogc
{
    return packedTag >> kTagTypeBits;
}

/// 提取packed tag中的值类型
ValueType unpackValueType(ulong packedTag) pure nothrow @safe @nogc
{
    return cast(ValueType) (packedTag & 0xff);
}

/// 打包序列号和值类型
ulong packSequenceAndType(ulong seq, ValueType type) pure nothrow @safe @nogc
{
    return (seq << kTagTypeBits) | cast(ulong) type;
}

/**
 * 解析后的内部键
 */
struct ParsedInternalKey
{
    Slice userKey;
    ulong sequence;
    ValueType type;

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
struct InternalKeyComparator
{
    Comparator userComparator;

    int compare(Slice a, Slice b) const nothrow @nogc
    {
        // 比较内部键：先比较userKey，再比较packedTag（降序）
        size_t aLen = a.size();
        size_t bLen = b.size();
        assert(aLen >= ulong.sizeof && bLen >= ulong.sizeof);

        // 比较userKey部分
        Slice aUserKey = Slice(a.data(), aLen - ulong.sizeof);
        Slice bUserKey = Slice(b.data(), bLen - ulong.sizeof);
        int r = userComparator.compare(aUserKey, bUserKey);
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

    /// 比较InternalKey结构体
    int compareInternalKeys(ParsedInternalKey a, ParsedInternalKey b) const
    {
        int r = userComparator.compare(a.userKey, b.userKey);
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
    void findShortestSeparator(ref Slice start, Slice limit) const
    {
        size_t startLen = start.size();
        size_t limitLen = limit.size();
        assert(startLen >= ulong.sizeof && limitLen >= ulong.sizeof);

        Slice userStart = Slice(start.data(), startLen - ulong.sizeof);
        Slice userLimit = Slice(limit.data(), limitLen - ulong.sizeof);
        userComparator.findShortestSeparator(userStart, userLimit);

        if (userStart.size() < startLen - ulong.sizeof)
        {
            start = userStart;
        }
    }

    /// 查找短后继键（用于SSTable索引块）
    void findShortSuccessor(ref Slice key) const
    {
        size_t keyLen = key.size();
        assert(keyLen >= ulong.sizeof);

        Slice userKey = Slice(key.data(), keyLen - ulong.sizeof);
        userComparator.findShortSuccessor(userKey);

        if (userKey.size() < keyLen - ulong.sizeof)
        {
            key = userKey;
        }
    }
}

/**
 * 内部键（编码后的字节序列）
 * 格式：user_key + uint64(seq<<8|type)
 */
struct InternalKey
{
    ubyte[] rep_;

    this(Slice userKey, ulong seq, ValueType type)
    {
        rep_.length = userKey.size() + ulong.sizeof;
        // 拷贝userKey
        for (size_t i = 0; i < userKey.size(); i++)
            rep_[i] = userKey.data()[i];
        // 编码packedTag
        encodeFixed64(rep_.ptr + userKey.size(), packSequenceAndType(seq, type));
    }

    Slice encode() const nothrow @nogc
    {
        return Slice(rep_.ptr, rep_.length);
    }

    Slice userKey() const nothrow @nogc
    {
        assert(rep_.length >= ulong.sizeof);
        return Slice(rep_.ptr, rep_.length - ulong.sizeof);
    }

    void setFrom(Slice s) nothrow
    {
        rep_.length = s.size();
        rep_[] = s.asBytes()[];
    }

    bool valid() const pure nothrow @safe @nogc
    {
        return rep_.length >= ulong.sizeof;
    }

    ParsedInternalKey parse() const nothrow
    {
        assert(valid());
        ParsedInternalKey result;
        result.userKey = Slice(rep_.ptr, rep_.length - ulong.sizeof);
        ulong tag = decodeFixed64(rep_.ptr + rep_.length - ulong.sizeof);
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
    ubyte[] rep_;
    size_t start_;     // memtable_key起始位置
    size_t kstart_;    // internal_key起始位置
    size_t end_;       // 结束位置

public:
    this(Slice userKey, ulong sequence)
    {
        // 计算大小
        size_t internalKeySize = userKey.size() + ulong.sizeof;
        int varintLen = varintLength(cast(uint) internalKeySize);
        size_t totalSize = varintLen + internalKeySize;

        rep_.length = totalSize;
        start_ = 0;
        kstart_ = varintLen;
        end_ = totalSize;

        // 编码varint32长度
        encodeVarint32(rep_.ptr, cast(uint) internalKeySize);

        // 拷贝userKey
        for (size_t i = 0; i < userKey.size(); i++)
            rep_[varintLen + i] = userKey.data()[i];

        // 编码packedTag
        encodeFixed64(rep_.ptr + varintLen + userKey.size(),
            packSequenceAndType(sequence, ValueType.value));
    }

    /// MemTable查找用的完整key
    Slice memtableKey() const nothrow @nogc
    {
        return Slice(rep_.ptr + start_, end_ - start_);
    }

    /// 内部键部分
    Slice internalKey() const nothrow @nogc
    {
        return Slice(rep_.ptr + kstart_, end_ - kstart_);
    }

    /// 用户键部分
    Slice userKey() const nothrow @nogc
    {
        return Slice(rep_.ptr + kstart_, end_ - kstart_ - ulong.sizeof);
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

/// 配置常量
enum int kNumLevels = 7;
enum int kL0_CompactionTrigger = 4;
enum int kL0_SlowdownWritesTrigger = 8;
enum int kL0_StopWritesTrigger = 12;
enum int kMaxMemCompactLevel = 2;
enum size_t kReadBytesPeriod = 1048576; // 1MB

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

    // kMaxSequenceNumber
    auto packedMax = packSequenceAndType(kMaxSequenceNumber, ValueType.value);
    assert(unpackSequence(packedMax) == kMaxSequenceNumber);

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
    auto icmp = InternalKeyComparator(defaultComparator());
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
