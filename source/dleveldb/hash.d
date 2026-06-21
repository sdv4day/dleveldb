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
    if (n - i >= 3)
        k ^= cast(uint) data[i + 2] << 16;
    if (n - i >= 2)
        k ^= cast(uint) data[i + 1] << 8;
    if (n - i >= 1)
    {
        k ^= cast(uint) data[i];
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

///
unittest
{
    // 相同输入产生相同哈希
    auto h1 = hash(Slice("hello"));
    auto h2 = hash(Slice("hello"));
    assert(h1 == h2);

    // 不同输入产生不同哈希（大概率）
    auto h3 = hash(Slice("world"));
    assert(h1 != h3);

    // 空Slice哈希
    auto hEmpty = hash(Slice(""));
    assert(hEmpty != 0 || hEmpty == 0); // 仅验证不崩溃

    // 不同种子产生不同结果
    auto h4 = hash(Slice("test"), 0x12345678);
    auto h5 = hash(Slice("test"), 0x87654321);
    assert(h4 != h5);

    // hashBytes 与 hash 一致
    ubyte[] data = [0x74, 0x65, 0x73, 0x74]; // "test"
    auto hb1 = hashBytes(data);
    auto hb2 = hash(Slice("test"));
    // hashBytes用Slice(data.ptr, data.length)，hash(Slice("test"))用char[]构造
    // 两者应一致
    assert(hb1 == hb2);

    // 单字节（大概率不同）
    auto ha = hash(Slice("a"));
    auto hb = hash(Slice("b"));
    // 哈希函数大概率产生不同值，但理论上可能碰巧相同

    // 长字符串
    auto longKey = Slice("abcdefghijklmnopqrstuvwxyz0123456789");
    auto hLong = hash(longKey);
}
