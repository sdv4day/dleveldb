module dleveldb.compression;

import dleveldb.slice;
import dleveldb.status;

/**
 * 压缩类型
 */
enum CompressionType : ubyte
{
    none = 0,
    snappy = 1,
    zstd = 2,
}

/**
 * 压缩接口
 */
interface Compressor
{
    /// 压缩类型
    CompressionType type() const;

    /// 压缩数据，返回压缩后的数据
    /// 如果压缩率低于12.5%，返回null（调用方应存储原始数据）
    ubyte[] compress(Slice input) const;

    /// 解压数据
    Status decompress(Slice compressed, ref ubyte[] output) const;
}

/**
 * 无压缩实现
 */
class NoneCompressor : Compressor
{
    CompressionType type() const pure nothrow @safe @nogc
    {
        return CompressionType.none;
    }

    ubyte[] compress(Slice input) const nothrow
    {
        // 无压缩，直接返回null表示应存储原始数据
        return null;
    }

    Status decompress(Slice compressed, ref ubyte[] output) const nothrow
    {
        // 无压缩，直接拷贝
        output.length = compressed.size();
        output[] = compressed.asBytes();
        return Status();
    }
}

/**
 * Snappy压缩实现（条件编译）
 */
version (HasSnappy)
{
    // 如果有snappy库，可以实现SnappyCompressor
}

/**
 * Zstd压缩实现（条件编译）
 */
version (HasZstd)
{
    // 如果有zstd库，可以实现ZstdCompressor
}

/// 创建压缩器
Compressor createCompressor(CompressionType type)
{
    final switch (type)
    {
        case CompressionType.none:
            return new NoneCompressor();
        case CompressionType.snappy:
            version (HasSnappy)
            {
                // return new SnappyCompressor();
            }
            else
            {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "Warning: Snappy compression not available"
                    ~ " (compile with -version=HasSnappy), falling back to none.\n");
            }
            return new NoneCompressor(); // 降级为无压缩
        case CompressionType.zstd:
            version (HasZstd)
            {
                // return new ZstdCompressor();
            }
            else
            {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "Warning: Zstd compression not available"
                    ~ " (compile with -version=HasZstd), falling back to none.\n");
            }
            return new NoneCompressor(); // 降级为无压缩
    }
}

///
unittest
{
    // CompressionType 枚举值
    assert(CompressionType.none == 0);
    assert(CompressionType.snappy == 1);
    assert(CompressionType.zstd == 2);

    // NoneCompressor
    auto nc = new NoneCompressor();
    assert(nc.type() == CompressionType.none);
    assert(nc.compress(Slice("test")) is null); // 无压缩返回null

    // decompress 拷贝数据
    ubyte[] input = [0x01, 0x02, 0x03];
    ubyte[] output;
    auto status = nc.decompress(Slice(input), output);
    assert(status.ok());
    assert(output.length == 3);
    assert(output[0] == 0x01 && output[1] == 0x02 && output[2] == 0x03);

    // createCompressor 各类型
    auto c1 = createCompressor(CompressionType.none);
    assert(c1.type() == CompressionType.none);

    // snappy/zstd 降级为 none（无对应库时）
    auto c2 = createCompressor(CompressionType.snappy);
    assert(c2.type() == CompressionType.none);
    auto c3 = createCompressor(CompressionType.zstd);
    assert(c3.type() == CompressionType.none);
}
