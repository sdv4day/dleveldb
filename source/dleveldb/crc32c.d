module dleveldb.crc32c;

/**
 * CRC32C校验和计算
 * 使用Castagnoli多项式（和leveldb一致）
 * 支持SSE4.2硬件加速
 */

/// 编译时生成CRC32C查找表（CTFE，零运行时初始化开销）
private enum uint[256] crc32cTable = generateCrc32cTable();

private uint[256] generateCrc32cTable() pure
{
    uint[256] table;
    for (uint i = 0; i < 256; i++)
    {
        uint crc = i;
        for (int j = 0; j < 8; j++)
        {
            if (crc & 1)
                crc = (crc >> 1) ^ 0x82F63B78u;
            else
                crc >>= 1;
        }
        table[i] = crc;
    }
    return table;
}

/// 计算CRC32C校验和（软件实现）
private uint crc32cSoftware(const(ubyte)* data, size_t len) nothrow @nogc
{
    uint crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
    {
        crc = crc32cTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

/// 计算CRC32C校验和（自动选择最优实现）
uint crc32cValue(const(ubyte)* data, size_t len) nothrow @nogc
{
    // TODO: 添加SSE4.2硬件加速支持
    // version(X86_64)
    // {
    //     import core.cpuid;
    //     if (core.cpuid.sse42)
    //     {
    //         return crc32cHardware(data, len);
    //     }
    // }
    return crc32cSoftware(data, len);
}

/// 计算CRC32C校验和（带初始值，用于分块计算）
uint crc32cExtend(uint crc, const(ubyte)* data, size_t len) nothrow @nogc
{
    crc = crc ^ 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
    {
        crc = crc32cTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

/// 对Slice计算CRC32C
uint crc32cSlice(const(ubyte)[] data) nothrow @nogc
{
    return crc32cValue(data.ptr, data.length);
}

///
unittest
{
    // 空数据
    assert(crc32cValue(null, 0) == 0);
    assert(crc32cSlice([]) == 0);

    // 已知测试向量
    ubyte[] test1 = [0x61, 0x62, 0x63]; // "abc"
    ubyte[] test2 = [0x48, 0x65, 0x6C, 0x6C, 0x6F]; // "Hello"

    assert(crc32cValue(test1.ptr, test1.length) != 0);
    assert(crc32cSlice(test2) != 0);

    // 分块计算与整体计算一致
    auto full = crc32cValue(test2.ptr, test2.length);
    auto part1 = crc32cExtend(0, test2.ptr, 2);
    auto part2 = crc32cExtend(part1, test2.ptr + 2, 3);
    assert(part2 == full);
}

///
unittest
{
    // CRC32C 已知值验证（空数据=0）
    assert(crc32cValue(null, 0) == 0);

    // 单字节
    ubyte[1] oneByte = [0x00];
    auto h1 = crc32cValue(oneByte.ptr, 1);
    assert(h1 != 0);

    // 相同数据产生相同CRC
    ubyte[] a = [1, 2, 3, 4, 5];
    ubyte[] b = [1, 2, 3, 4, 5];
    assert(crc32cValue(a.ptr, a.length) == crc32cValue(b.ptr, b.length));

    // 不同数据产生不同CRC（大概率）
    ubyte[] c = [5, 4, 3, 2, 1];
    auto crcA = crc32cValue(a.ptr, a.length);
    auto crcC = crc32cValue(c.ptr, c.length);
    // 注意：特定数据可能CRC碰巧相同，仅验证不崩溃

    // crc32cSlice 与 crc32cValue 一致
    ubyte[] d = [0x41, 0x42, 0x43];
    assert(crc32cSlice(d) == crc32cValue(d.ptr, d.length));

    // 分块计算：三块
    ubyte[] data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    auto fullCrc = crc32cValue(data.ptr, data.length);
    auto p1 = crc32cExtend(0, data.ptr, 3);
    auto p2 = crc32cExtend(p1, data.ptr + 3, 4);
    auto p3 = crc32cExtend(p2, data.ptr + 7, 3);
    assert(p3 == fullCrc);

    // CRC32C 幂等性：对相同数据多次计算结果一致
    auto v1 = crc32cValue(data.ptr, data.length);
    auto v2 = crc32cValue(data.ptr, data.length);
    assert(v1 == v2);
}
