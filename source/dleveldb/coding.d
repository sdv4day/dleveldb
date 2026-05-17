module dleveldb.coding;

import dleveldb.slice;

/**
 * 定长编码（小端序）
 * 所有涉及指针操作的函数使用@trusted
 */

/// 编码uint32（小端序）
void encodeFixed32(ubyte* dst, uint value) pure nothrow @trusted @nogc
{
    dst[0] = cast(ubyte) (value & 0xff);
    dst[1] = cast(ubyte) ((value >> 8) & 0xff);
    dst[2] = cast(ubyte) ((value >> 16) & 0xff);
    dst[3] = cast(ubyte) ((value >> 24) & 0xff);
}

/// 解码uint32（小端序）
uint decodeFixed32(const(ubyte)* ptr) pure nothrow @trusted @nogc
{
    return (cast(uint) ptr[0]) |
           (cast(uint) ptr[1] << 8) |
           (cast(uint) ptr[2] << 16) |
           (cast(uint) ptr[3] << 24);
}

/// 编码uint64（小端序）
void encodeFixed64(ubyte* dst, ulong value) pure nothrow @trusted @nogc
{
    for (int i = 0; i < 8; i++)
    {
        dst[i] = cast(ubyte) ((value >> (i * 8)) & 0xff);
    }
}

/// 解码uint64（小端序）
ulong decodeFixed64(const(ubyte)* ptr) pure nothrow @trusted @nogc
{
    ulong result = 0;
    for (int i = 0; i < 8; i++)
    {
        result |= cast(ulong) ptr[i] << (i * 8);
    }
    return result;
}

/**
 * 变长编码（Varint，兼容Protocol Buffers）
 */

/// 编码varint32，返回编码后的字节数
int encodeVarint32(ubyte* dst, uint value) pure nothrow @trusted @nogc
{
    ubyte* ptr = dst;
    while (value > 0x7f)
    {
        *ptr = cast(ubyte) ((value & 0x7f) | 0x80);
        ptr++;
        value >>= 7;
    }
    *ptr = cast(ubyte) value;
    ptr++;
    return cast(int) (ptr - dst);
}

/// 解码varint32，返回解码后的值和是否成功
bool decodeVarint32(ref const(ubyte)* ptr, const(ubyte)* limit, ref uint result) pure nothrow @trusted @nogc
{
    result = 0;
    uint shift = 0;
    while (ptr < limit)
    {
        ubyte b = *ptr;
        ptr++;
        if (b & 0x80)
        {
            result |= cast(uint) ((b & 0x7f)) << shift;
        }
        else
        {
            result |= cast(uint) b << shift;
            return true;
        }
        shift += 7;
        if (shift >= 32)
            return false;
    }
    return false;
}

/// 编码varint64，返回编码后的字节数
int encodeVarint64(ubyte* dst, ulong value) pure nothrow @trusted @nogc
{
    ubyte* ptr = dst;
    while (value > 0x7f)
    {
        *ptr = cast(ubyte) ((value & 0x7f) | 0x80);
        ptr++;
        value >>= 7;
    }
    *ptr = cast(ubyte) value;
    ptr++;
    return cast(int) (ptr - dst);
}

/// 解码varint64，返回是否成功
bool decodeVarint64(ref const(ubyte)* ptr, const(ubyte)* limit, ref ulong result) pure nothrow @trusted @nogc
{
    result = 0;
    uint shift = 0;
    while (ptr < limit)
    {
        ubyte b = *ptr;
        ptr++;
        if (b & 0x80)
        {
            result |= cast(ulong) (b & 0x7f) << shift;
        }
        else
        {
            result |= cast(ulong) b << shift;
            return true;
        }
        shift += 7;
        if (shift >= 64)
            return false;
    }
    return false;
}

/// 计算varint32编码长度
int varintLength(uint v) pure nothrow @safe @nogc
{
    int len = 1;
    while (v > 0x7f)
    {
        v >>= 7;
        len++;
    }
    return len;
}

/// 计算varint64编码长度
int varintLength64(ulong v) pure nothrow @safe @nogc
{
    int len = 1;
    while (v > 0x7f)
    {
        v >>= 7;
        len++;
    }
    return len;
}

/**
 * 长度前缀字符串编解码
 */

/// 编码长度前缀Slice到缓冲区
void putLengthPrefixedSlice(ref ubyte[] dst, Slice value)
{
    // 先写varint32长度
    size_t oldLen = dst.length;
    dst.length = oldLen + varintLength(cast(uint) value.size()) + value.size();
    int varintLen = encodeVarint32(dst.ptr + oldLen, cast(uint) value.size());
    if (value.size() > 0)
    {
        // 使用D标准数组切片拷贝替代memcpy
        dst[oldLen + varintLen .. oldLen + varintLen + value.size()] = value.asBytes();
    }
    // 调整长度（varintLen可能不等于varintLength预估）
    dst.length = oldLen + varintLen + value.size();
}

/// 解码长度前缀Slice，返回是否成功
bool getLengthPrefixedSlice(ref const(ubyte)* ptr, const(ubyte)* limit, ref Slice result) nothrow @trusted @nogc
{
    uint len;
    if (!decodeVarint32(ptr, limit, len))
        return false;
    if (ptr + len > limit)
        return false;
    result = Slice(ptr, len);
    ptr += len;
    return true;
}
