module dleveldb.hash;

import dleveldb.slice;

/**
 * 哈希函数，类似leveldb的类MurmurHash
 * 用于布隆过滤器和缓存分片
 */
uint hash(Slice key, uint seed = 0xbc9f1d34) nothrow @trusted @nogc
{
    // 类似MurmurHash3的32位哈希
    uint h = seed ^ cast(uint) key.size();
    const(ubyte)* data = key.data();
    size_t n = key.size();

    // 处理4字节块
    size_t i = 0;
    for (; i + uint.sizeof <= n; i += uint.sizeof)
    {
        uint k = cast(uint) data[i] |
                 (cast(uint) data[i + 1] << 8) |
                 (cast(uint) data[i + 2] << 16) |
                 (cast(uint) data[i + 3] << 24);
        k *= 0xcc9e2d51;
        k = (k << 15) | (k >> 17);
        k *= 0x1b873593;
        h ^= k;
        h = (h << 13) | (h >> 19);
        h = h * 5 + 0xe6546b64;
    }

    // 处理剩余字节
    uint k = 0;
    if (i + 3 <= n)
        k ^= cast(uint) data[i + 3] << 16;
    if (i + 2 <= n)
        k ^= cast(uint) data[i + 2] << 8;
    if (i + 1 <= n)
    {
        k ^= cast(uint) data[i + 1];
        k *= 0xcc9e2d51;
        k = (k << 15) | (k >> 17);
        k *= 0x1b873593;
        h ^= k;
    }

    // 最终混合
    h ^= cast(uint) n;
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;

    return h;
}

/// 对字节数组的哈希
uint hashBytes(const(ubyte)[] data, uint seed = 0xbc9f1d34) nothrow @trusted @nogc
{
    return hash(Slice(data.ptr, data.length), seed);
}
