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

/// 提取packed tag中的序列号
ulong unpackSequence(ulong packedTag) pure nothrow @safe @nogc
{
    return packedTag >> 8;
}

/// 提取packed tag中的值类型
ValueType unpackValueType(ulong packedTag) pure nothrow @safe @nogc
{
    return cast(ValueType) (packedTag & 0xff);
}

/// 打包序列号和值类型
ulong packSequenceAndType(ulong seq, ValueType type) pure nothrow @safe @nogc
{
    return (seq << 8) | cast(ulong) type;
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
        assert(aLen >= 8 && bLen >= 8);

        // 比较userKey部分
        Slice aUserKey = Slice(a.data(), aLen - 8);
        Slice bUserKey = Slice(b.data(), bLen - 8);
        int r = userComparator.compare(aUserKey, bUserKey);
        if (r != 0)
            return r;

        // 比较packedTag（降序：数值大的排在前面）
        ulong aTag = decodeFixed64(a.data() + aLen - 8);
        ulong bTag = decodeFixed64(b.data() + bLen - 8);
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
        rep_.length = userKey.size() + 8;
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
        assert(rep_.length >= 8);
        return Slice(rep_.ptr, rep_.length - 8);
    }

    void setFrom(Slice s) nothrow
    {
        rep_.length = s.size();
        rep_[] = s.asBytes()[];
    }

    bool valid() const pure nothrow @safe @nogc
    {
        return rep_.length >= 8;
    }

    ParsedInternalKey parse() const nothrow
    {
        assert(valid());
        ParsedInternalKey result;
        result.userKey = Slice(rep_.ptr, rep_.length - 8);
        ulong tag = decodeFixed64(rep_.ptr + rep_.length - 8);
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
        size_t internalKeySize = userKey.size() + 8;
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
        return Slice(rep_.ptr + kstart_, end_ - kstart_ - 8);
    }
}

/**
 * 提取内部键中的用户键
 */
Slice extractUserKey(Slice internalKey) pure nothrow @safe @nogc
{
    assert(internalKey.size() >= 8);
    return Slice(internalKey.data(), internalKey.size() - 8);
}

/**
 * 提取内部键中的packed tag
 */
ulong extractPackedTag(Slice internalKey) nothrow @trusted @nogc
{
    assert(internalKey.size() >= 8);
    return decodeFixed64(internalKey.data() + internalKey.size() - 8);
}

/// 配置常量
enum int kNumLevels = 7;
enum int kL0_CompactionTrigger = 4;
enum int kL0_SlowdownWritesTrigger = 8;
enum int kL0_StopWritesTrigger = 12;
enum int kMaxMemCompactLevel = 2;
enum size_t kReadBytesPeriod = 1048576; // 1MB
