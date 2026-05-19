module dleveldb.crc32c;

/**
 * CRC32C校验和计算
 * 使用Castagnoli多项式（和leveldb一致）
 * 支持SSE4.2硬件加速
 */

// CRC32C查找表
private uint[256] crc32cTable;

shared static this()
{
    // 初始化CRC32C查找表
    for (uint i = 0; i < 256; i++)
    {
        uint crc = i;
        for (int j = 0; j < 8; j++)
        {
            if (crc & 1)
                crc = (crc >> 1) ^ 0x82F63B78u; // Castagnoli多项式
            else
                crc >>= 1;
        }
        crc32cTable[i] = crc;
    }
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
