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
        for (size_t i = 0; i < compressed.size(); i++)
            output[i] = compressed.data()[i];
        return Status();
    }
}

/**
 * Snappy压缩实现（条件编译）
 */
version (HaveSnappy)
{
    // 如果有snappy库，可以实现SnappyCompressor
}

/**
 * Zstd压缩实现（条件编译）
 */
version (HaveZstd)
{
    // 如果有zstd库，可以实现ZstdCompressor
}

/// 创建压缩器
Compressor newCompressor(CompressionType type)
{
    final switch (type)
    {
        case CompressionType.none:
            return new NoneCompressor();
        case CompressionType.snappy:
            version (HaveSnappy)
            {
                // return new SnappyCompressor();
            }
            else
            {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "Warning: Snappy compression not available"
                    ~ " (compile with -version=HaveSnappy), falling back to none.\n");
            }
            return new NoneCompressor(); // 降级为无压缩
        case CompressionType.zstd:
            version (HaveZstd)
            {
                // return new ZstdCompressor();
            }
            else
            {
                import core.stdc.stdio : fprintf, stderr;
                fprintf(stderr, "Warning: Zstd compression not available"
                    ~ " (compile with -version=HaveZstd), falling back to none.\n");
            }
            return new NoneCompressor(); // 降级为无压缩
    }
}
