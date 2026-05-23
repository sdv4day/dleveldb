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
    for (int i = 0; i < ulong.sizeof; i++)
    {
        dst[i] = cast(ubyte) ((value >> (i * 8)) & 0xff);
    }
}

/// 解码uint64（小端序）
ulong decodeFixed64(const(ubyte)* ptr) pure nothrow @trusted @nogc
{
    ulong result = 0;
    for (int i = 0; i < ulong.sizeof; i++)
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
        if (shift >= uint.sizeof * 8)
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
        if (shift >= ulong.sizeof * 8)
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

///
unittest
{
    // 测试定长编解码
    ubyte[4] buf4;
    encodeFixed32(buf4.ptr, 0xDEADBEEF);
    assert(decodeFixed32(buf4.ptr) == 0xDEADBEEF);
    encodeFixed32(buf4.ptr, 0);
    assert(decodeFixed32(buf4.ptr) == 0);
    encodeFixed32(buf4.ptr, 0xFFFFFFFF);
    assert(decodeFixed32(buf4.ptr) == 0xFFFFFFFF);

    ubyte[8] buf8;
    encodeFixed64(buf8.ptr, 0xDEADBEEFCAFEBABE);
    assert(decodeFixed64(buf8.ptr) == 0xDEADBEEFCAFEBABE);
    encodeFixed64(buf8.ptr, 0);
    assert(decodeFixed64(buf8.ptr) == 0);

    // 测试varint32编解码
    ubyte[10] varBuf;
    uint[] testVals = [0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 0xFFFFFFFF];
    foreach (v; testVals)
    {
        auto n = encodeVarint32(varBuf.ptr, v);
        const(ubyte)* ptr = varBuf.ptr;
        const(ubyte)* limit = ptr + n;
        uint decoded;
        assert(decodeVarint32(ptr, limit, decoded));
        assert(decoded == v);
    }

    // 测试varint64编解码
    ulong[] testVals64 = [0, 1, 127, 128, 16383, 16384, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF];
    foreach (v; testVals64)
    {
        auto n = encodeVarint64(varBuf.ptr, v);
        const(ubyte)* ptr = varBuf.ptr;
        const(ubyte)* limit = ptr + n;
        ulong decoded;
        assert(decodeVarint64(ptr, limit, decoded));
        assert(decoded == v);
    }

    // 测试长度前缀Slice
    ubyte[] data = [5, 0x48, 0x65, 0x6C, 0x6C, 0x6F]; // varint(5) + "Hello"
    const(ubyte)* ptr = data.ptr;
    Slice result;
    assert(getLengthPrefixedSlice(ptr, ptr + data.length, result));
    assert(result.asString() == "Hello");
}

///
unittest
{
    // varintLength 测试
    assert(varintLength(0) == 1);
    assert(varintLength(127) == 1);
    assert(varintLength(128) == 2);
    assert(varintLength(16383) == 2);
    assert(varintLength(16384) == 3);

    // varintLength64 测试
    assert(varintLength64(0) == 1);
    assert(varintLength64(127) == 1);
    assert(varintLength64(128) == 2);
    assert(varintLength64(ulong.max) == 10);

    // encodeFixed32 字节序验证（小端序）
    ubyte[4] buf32;
    encodeFixed32(buf32.ptr, 1);
    assert(buf32[0] == 1 && buf32[1] == 0 && buf32[2] == 0 && buf32[3] == 0);
    encodeFixed32(buf32.ptr, 256);
    assert(buf32[0] == 0 && buf32[1] == 1 && buf32[2] == 0 && buf32[3] == 0);

    // encodeFixed64 字节序验证（小端序）
    ubyte[8] buf64;
    encodeFixed64(buf64.ptr, 1);
    assert(buf64[0] == 1);
    encodeFixed64(buf64.ptr, 256);
    assert(buf64[0] == 0 && buf64[1] == 1);

    // varint32 边界值往返
    uint[] edgeVals = [1, 127, 128, 255, 256, 0x7FFF, 0x8000, 0xFFFF, 0x10000];
    ubyte[10] vb;
    foreach (v; edgeVals)
    {
        auto n = encodeVarint32(vb.ptr, v);
        const(ubyte)* p = vb.ptr;
        uint decoded;
        assert(decodeVarint32(p, p + n, decoded));
        assert(decoded == v);
    }

    // varint64 边界值往返
    ulong[] edgeVals64 = [1, 127, 128, 0xFFFF, 0xFFFFFFFF, 0x100000000UL, 0xFFFFFFFFFFFFUL];
    ubyte[10] vb64;
    foreach (v; edgeVals64)
    {
        auto n = encodeVarint64(vb64.ptr, v);
        const(ubyte)* p = vb64.ptr;
        ulong decoded;
        assert(decodeVarint64(p, p + n, decoded));
        assert(decoded == v);
    }

    // decodeVarint32 数据不足返回false
    ubyte[2] shortBuf = [0x80, 0x80]; // 需要更多字节
    const(ubyte)* sp = shortBuf.ptr;
    uint dv;
    assert(!decodeVarint32(sp, sp + 2, dv));

    // putLengthPrefixedSlice + getLengthPrefixedSlice 往返
    ubyte[] lpsBuf;
    putLengthPrefixedSlice(lpsBuf, Slice("key1"));
    putLengthPrefixedSlice(lpsBuf, Slice("value1"));
    const(ubyte)* lp = lpsBuf.ptr;
    const(ubyte)* lpLimit = lp + lpsBuf.length;
    Slice k, v;
    assert(getLengthPrefixedSlice(lp, lpLimit, k));
    assert(getLengthPrefixedSlice(lp, lpLimit, v));
    assert(k.asString() == "key1");
    assert(v.asString() == "value1");

    // 长度前缀空Slice
    ubyte[] emptyBuf;
    putLengthPrefixedSlice(emptyBuf, Slice());
    const(ubyte)* ep = emptyBuf.ptr;
    Slice emptyResult;
    assert(getLengthPrefixedSlice(ep, ep + emptyBuf.length, emptyResult));
    assert(emptyResult.empty());
}
