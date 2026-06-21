module dleveldb.compression;

import dleveldb.slice;
import dleveldb.status;
import deimos.snappy.snappy;
import std.logger;
import std.format : format;
import deimos.zstd;

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

    /**
     * 压缩数据，返回压缩后的数据
     * 如果压缩率低于12.5%，返回null（调用方应存储原始数据）
     */
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
 * Snappy压缩实现
 */
class SnappyCompressor : Compressor
{
    CompressionType type() const pure nothrow @safe @nogc
    {
        return CompressionType.snappy;
    }

    ubyte[] compress(Slice input) const nothrow
    {
        size_t inputLen = input.size();
        size_t maxOutputLen = snappy_max_compressed_length(inputLen);

        ubyte[] output = new ubyte[maxOutputLen];
        size_t outputLen = maxOutputLen;

        snappy_status status = snappy_compress(
            cast(const(char)*) input.data(),
            inputLen,
            cast(char*) output.ptr,
            &outputLen
        );

        if (status != SNAPPY_OK)
        {
            return null;
        }

        if (outputLen >= inputLen - inputLen / 8)
        {
            return null;
        }

        output.length = outputLen;
        return output;
    }

    Status decompress(Slice compressed, ref ubyte[] output) const
    {
        size_t uncompressedLen;
        snappy_status status = snappy_uncompressed_length(
            cast(const(char)*) compressed.data(),
            compressed.size(),
            &uncompressedLen
        );

        if (status != SNAPPY_OK)
        {
            return statusCorruption("Snappy: invalid compressed data");
        }

        output.length = uncompressedLen;

        status = snappy_uncompress(
            cast(const(char)*) compressed.data(),
            compressed.size(),
            cast(char*) output.ptr,
            &uncompressedLen
        );

        if (status != SNAPPY_OK)
        {
            return statusCorruption("Snappy: decompression failed");
        }

        return Status();
    }
}

/**
 * Zstd压缩实现
 */
class ZstdCompressor : Compressor
{
    /// 默认压缩级别（zstd推荐值为3）
    enum defaultCompressionLevel = 3;

    CompressionType type() const pure nothrow @safe @nogc
    {
        return CompressionType.zstd;
    }

    ubyte[] compress(Slice input) const nothrow
    {
        size_t inputLen = input.size();
        size_t maxOutputLen = ZSTD_compressBound(inputLen);

        ubyte[] output = new ubyte[maxOutputLen];
        size_t compressedSize = ZSTD_compress(
            output.ptr,
            maxOutputLen,
            input.data(),
            inputLen,
            defaultCompressionLevel
        );

        if (ZSTD_isError(compressedSize))
        {
            return null;
        }

        // 检查压缩率：如果压缩后大小 >= 原始大小的 87.5%，则返回null
        if (compressedSize >= inputLen - inputLen / 8)
        {
            return null;
        }

        output.length = compressedSize;
        return output;
    }

    Status decompress(Slice compressed, ref ubyte[] output) const
    {
        // 获取解压缩后的内容大小
        ulong uncompressedLen = ZSTD_getFrameContentSize(
            compressed.data(),
            compressed.size()
        );

        if (uncompressedLen == ZSTD_CONTENTSIZE_ERROR)
        {
            return statusCorruption("Zstd: invalid compressed data");
        }

        if (uncompressedLen == ZSTD_CONTENTSIZE_UNKNOWN)
        {
            return statusCorruption("Zstd: unknown content size");
        }

        output.length = uncompressedLen;

        size_t decompressedSize = ZSTD_decompress(
            output.ptr,
            uncompressedLen,
            compressed.data(),
            compressed.size()
        );

        // 检查解压是否成功
        if (ZSTD_isError(decompressedSize))
        {
            return statusCorruption("Zstd: decompression failed");
        }

        // 验证解压后的大小是否匹配
        if (decompressedSize != uncompressedLen)
        {
            return statusCorruption("Zstd: size mismatch after decompression");
        }

        return Status();
    }
}

/// 创建压缩器
Compressor createCompressor(CompressionType type)
{
    final switch (type)
    {
        case CompressionType.none:
            return new NoneCompressor();
        case CompressionType.snappy:
            return new SnappyCompressor();
        case CompressionType.zstd:
            version (HasZstd)
            {
                return new ZstdCompressor();
            }
            else
            {
                warning("Zstd compression not available (compile with -version=HasZstd), falling back to none.");
                return new NoneCompressor();
            }
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
    assert(nc.compress(Slice("test")) is null);

    ubyte[] input = [0x01, 0x02, 0x03];
    ubyte[] output;
    auto status = nc.decompress(Slice(input), output);
    assert(status.ok());
    assert(output.length == 3);
    assert(output[0] == 0x01 && output[1] == 0x02 && output[2] == 0x03);

    // createCompressor 各类型
    auto c1 = createCompressor(CompressionType.none);
    assert(c1.type() == CompressionType.none);

    auto c2 = createCompressor(CompressionType.snappy);
    assert(c2.type() == CompressionType.snappy);

    auto c3 = createCompressor(CompressionType.zstd);
    assert(c3.type() == CompressionType.none);
}

///
unittest
{
    // SnappyCompressor 测试
    auto sc = new SnappyCompressor();
    assert(sc.type() == CompressionType.snappy);

    // 压缩可压缩数据
    ubyte[] data = new ubyte[1000];
    data[] = 0xAA;
    auto compressed = sc.compress(Slice(data));
    assert(compressed !is null);
    assert(compressed.length < data.length);

    // 解压
    ubyte[] decompressed;
    auto status = sc.decompress(Slice(compressed), decompressed);
    assert(status.ok());
    assert(decompressed.length == data.length);
    assert(decompressed[] == data[]);

    // 压缩不可压缩数据（随机数据）
    ubyte[] randomData = new ubyte[100];
    foreach (i; 0 .. randomData.length)
        randomData[i] = cast(ubyte) i;
    auto compressedRandom = sc.compress(Slice(randomData));
    // 随机数据压缩率低，可能返回null

    // 解压错误数据
    ubyte[] badData = [0x00, 0x01, 0x02];
    ubyte[] badOutput;
    auto badStatus = sc.decompress(Slice(badData), badOutput);
    assert(!badStatus.ok());
    assert(badStatus.isCorruption());
}

///
unittest
{
    // 边界情况测试：空数据
    auto sc = new SnappyCompressor();

    ubyte[] emptyData = [];
    auto compressedEmpty = sc.compress(Slice(emptyData));
    // 空数据压缩后可能返回null或极小数据
    if (compressedEmpty !is null)
    {
        ubyte[] decompressedEmpty;
        auto status = sc.decompress(Slice(compressedEmpty), decompressedEmpty);
        assert(status.ok());
        assert(decompressedEmpty.length == 0);
    }
}

///
unittest
{
    // 边界情况测试：单字节数据
    auto sc = new SnappyCompressor();

    ubyte[] singleByte = [0x42];
    auto compressed = sc.compress(Slice(singleByte));
    // 单字节数据压缩率可能不够，返回null
    if (compressed !is null)
    {
        ubyte[] decompressed;
        auto status = sc.decompress(Slice(compressed), decompressed);
        assert(status.ok());
        assert(decompressed.length == 1);
        assert(decompressed[0] == 0x42);
    }
}

///
unittest
{
    // 大数据压缩测试
    auto sc = new SnappyCompressor();

    // 1MB 重复数据
    size_t dataSize = 1024 * 1024;
    ubyte[] largeData = new ubyte[dataSize];
    foreach (i; 0 .. dataSize)
        largeData[i] = cast(ubyte)(i % 256);

    auto compressed = sc.compress(Slice(largeData));
    if (compressed !is null)
    {
        assert(compressed.length < largeData.length, "压缩后应更小");

        ubyte[] decompressed;
        auto status = sc.decompress(Slice(compressed), decompressed);
        assert(status.ok(), "解压应成功");
        assert(decompressed.length == largeData.length, "长度应一致");

        // 验证数据完整性
        bool match = true;
        foreach (i; 0 .. dataSize)
        {
            if (decompressed[i] != largeData[i])
            {
                match = false;
                break;
            }
        }
        assert(match, "数据应完全一致");
    }
}

///
unittest
{
    // 高压缩率数据测试（全相同字节）
    auto sc = new SnappyCompressor();

    foreach (size; [100, 1000, 10000, 100000])
    {
        ubyte[] uniformData = new ubyte[size];
        uniformData[] = 0x55;  // 全部相同

        auto compressed = sc.compress(Slice(uniformData));
        assert(compressed !is null, format("大小 %d 应可压缩", size));
        assert(compressed.length < uniformData.length / 10,
            format("均匀数据压缩率应很高: 原始 %d, 压缩后 %d", size, compressed.length));

        ubyte[] decompressed;
        auto status = sc.decompress(Slice(compressed), decompressed);
        assert(status.ok());
        assert(decompressed.length == size);
        assert(decompressed[] == uniformData[]);
    }
}

///
unittest
{
    // 压缩率阈值测试（12.5% 阈值）
    auto sc = new SnappyCompressor();

    // 构造刚好在阈值边缘的数据
    // Snappy 对于随机数据压缩效果差，应该返回 null
    ubyte[] randomData = new ubyte[1000];
    import std.random : Xorshift, uniform;
    auto rng = Xorshift(12345);
    foreach (ref b; randomData)
        b = cast(ubyte) uniform(0, 256, rng);

    auto compressed = sc.compress(Slice(randomData));
    // 随机数据压缩率低，预期返回 null
    // 如果返回非 null，验证解压正确性
    if (compressed !is null)
    {
        ubyte[] decompressed;
        auto status = sc.decompress(Slice(compressed), decompressed);
        assert(status.ok());
        assert(decompressed[] == randomData[]);
    }
}

///
unittest
{
    // 多次压缩解压循环测试
    auto sc = new SnappyCompressor();

    ubyte[] original = new ubyte[500];
    foreach (i; 0 .. original.length)
        original[i] = cast(ubyte)(i * 7);

    ubyte[] current = original.dup;

    // 多次压缩解压
    foreach (round; 0 .. 3)
    {
        auto compressed = sc.compress(Slice(current));
        if (compressed is null)
            break;  // 无法进一步压缩

        ubyte[] decompressed;
        auto status = sc.decompress(Slice(compressed), decompressed);
        assert(status.ok(), format("第 %d 轮解压失败", round));
        assert(decompressed[] == current[],
            format("第 %d 轮数据不一致", round));

        current = decompressed;
    }

    // 最终数据应与原始一致
    assert(current[] == original[], "多轮压缩解压后数据应一致");
}

///
unittest
{
    // 文本数据压缩测试
    auto sc = new SnappyCompressor();

    string[] testTexts = [
        "Hello, World! This is a test string for compression.",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "The quick brown fox jumps over the lazy dog. " ~
        "The quick brown fox jumps over the lazy dog. " ~
        "The quick brown fox jumps over the lazy dog.",
        "abcdefghijklmnopqrstuvwxyz0123456789",
    ];

    foreach (text; testTexts)
    {
        auto compressed = sc.compress(Slice(text));
        if (compressed !is null)
        {
            ubyte[] decompressed;
            auto status = sc.decompress(Slice(compressed), decompressed);
            assert(status.ok(), format("文本 '%s' 解压失败", text[0..20]));

            string result = cast(string) decompressed;
            assert(result == text, "解压后文本应一致");
        }
    }
}

///
unittest
{
    // Slice 不同来源的压缩测试
    auto sc = new SnappyCompressor();

    // 从字符串
    auto s1 = Slice("test string data");
    auto c1 = sc.compress(s1);
    if (c1 !is null)
    {
        ubyte[] d1;
        assert(sc.decompress(Slice(c1), d1).ok());
        assert(d1.length == s1.size());
    }

    // 从 ubyte 数组
    ubyte[] bytes = [0x01, 0x02, 0x03, 0x04, 0x05];
    auto s2 = Slice(bytes);
    auto c2 = sc.compress(s2);
    if (c2 !is null)
    {
        ubyte[] d2;
        assert(sc.decompress(Slice(c2), d2).ok());
        assert(d2[] == bytes[]);
    }

    // 从指针和长度
    ubyte[] buffer = [0xAA, 0xBB, 0xCC, 0xDD];
    auto s3 = Slice(buffer.ptr, buffer.length);
    auto c3 = sc.compress(s3);
    if (c3 !is null)
    {
        ubyte[] d3;
        assert(sc.decompress(Slice(c3), d3).ok());
        assert(d3[] == buffer[]);
    }
}

///
unittest
{
    // 错误处理测试：截断的压缩数据
    auto sc = new SnappyCompressor();

    // 先压缩一些数据
    ubyte[] original = new ubyte[100];
    original[] = 0x77;
    auto compressed = sc.compress(Slice(original));
    assert(compressed !is null);

    // 截断压缩数据
    if (compressed.length > 10)
    {
        ubyte[] truncated = compressed[0 .. $ - 10];
        ubyte[] output;
        auto status = sc.decompress(Slice(truncated), output);
        assert(!status.ok(), "截断数据解压应失败");
        assert(status.isCorruption(), "应返回 corruption 状态");
    }
}

///
unittest
{
    // 错误处理测试：完全无效的数据
    auto sc = new SnappyCompressor();

    ubyte[] invalidData = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    ubyte[] output;
    auto status = sc.decompress(Slice(invalidData), output);
    assert(!status.ok(), "无效数据解压应失败");
    assert(status.isCorruption(), "应返回 corruption 状态");
}

///
unittest
{
    // createCompressor 返回类型验证
    auto noneComp = createCompressor(CompressionType.none);
    assert(noneComp !is null);
    assert(noneComp.type() == CompressionType.none);
    assert(cast(NoneCompressor) noneComp !is null);

    auto snappyComp = createCompressor(CompressionType.snappy);
    assert(snappyComp !is null);
    assert(snappyComp.type() == CompressionType.snappy);
    assert(cast(SnappyCompressor) snappyComp !is null);

    version (HasZstd)
    {
        // zstd 启用时应返回 ZstdCompressor
        auto zstdComp = createCompressor(CompressionType.zstd);
        assert(zstdComp !is null);
        assert(zstdComp.type() == CompressionType.zstd);
        assert(cast(ZstdCompressor) zstdComp !is null);
    }
    else
    {
        // zstd 未启用时应降级为 NoneCompressor
        auto zstdComp = createCompressor(CompressionType.zstd);
        assert(zstdComp !is null);
        assert(zstdComp.type() == CompressionType.none);
        assert(cast(NoneCompressor) zstdComp !is null);
    }
}

///
unittest
{
    // NoneCompressor 完整测试
    auto nc = new NoneCompressor();

    // compress 总是返回 null
    assert(nc.compress(Slice("any data")) is null);
    assert(nc.compress(Slice("")) is null);
    assert(nc.compress(Slice(new ubyte[1000])) is null);

    // decompress 直接拷贝
    ubyte[] testData = [0x01, 0x02, 0x03, 0x04, 0x05];
    ubyte[] output;
    auto status = nc.decompress(Slice(testData), output);
    assert(status.ok());
    assert(output.length == testData.length);
    assert(output[] == testData[]);

    // 空数据
    ubyte[] emptyOutput;
    auto emptyStatus = nc.decompress(Slice(new ubyte[0]), emptyOutput);
    assert(emptyStatus.ok());
    assert(emptyOutput.length == 0);
}

version (HasZstd)
{
    ///
    unittest
    {
        // ZstdCompressor 基本测试
        auto zc = new ZstdCompressor();
        assert(zc.type() == CompressionType.zstd);

        // 压缩可压缩数据
        ubyte[] data = new ubyte[1000];
        data[] = 0xAA;
        auto compressed = zc.compress(Slice(data));
        assert(compressed !is null);
        assert(compressed.length < data.length);

        // 解压
        ubyte[] decompressed;
        auto status = zc.decompress(Slice(compressed), decompressed);
        assert(status.ok());
        assert(decompressed.length == data.length);
        assert(decompressed[] == data[]);
    }

    ///
    unittest
    {
        // ZstdCompressor 高压缩率数据测试
        auto zc = new ZstdCompressor();

        foreach (size; [100, 1000, 10000, 100000])
        {
            ubyte[] uniformData = new ubyte[size];
            uniformData[] = 0x55;  // 全部相同

            auto compressed = zc.compress(Slice(uniformData));
            assert(compressed !is null, format("大小 %d 应可压缩", size));
            assert(compressed.length < uniformData.length / 10,
                format("均匀数据压缩率应很高: 原始 %d, 压缩后 %d", size, compressed.length));

            ubyte[] decompressed;
            auto status = zc.decompress(Slice(compressed), decompressed);
            assert(status.ok());
            assert(decompressed.length == size);
            assert(decompressed[] == uniformData[]);
        }
    }

    ///
    unittest
    {
        // ZstdCompressor 文本数据压缩测试
        auto zc = new ZstdCompressor();

        string[] testTexts = [
            "Hello, World! This is a test string for compression.",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "The quick brown fox jumps over the lazy dog. " ~
            "The quick brown fox jumps over the lazy dog. " ~
            "The quick brown fox jumps over the lazy dog.",
            "abcdefghijklmnopqrstuvwxyz0123456789",
        ];

        foreach (text; testTexts)
        {
            auto compressed = zc.compress(Slice(text));
            if (compressed !is null)
            {
                ubyte[] decompressed;
                auto status = zc.decompress(Slice(compressed), decompressed);
                assert(status.ok(), format("文本 '%s' 解压失败", text[0..20]));

                string result = cast(string) decompressed;
                assert(result == text, "解压后文本应一致");
            }
        }
    }

    ///
    unittest
    {
        // ZstdCompressor 错误处理测试
        auto zc = new ZstdCompressor();

        // 无效数据解压
        ubyte[] invalidData = [
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];

        ubyte[] output;
        auto status = zc.decompress(Slice(invalidData), output);
        assert(!status.ok(), "无效数据解压应失败");
        assert(status.isCorruption(), "应返回 corruption 状态");
    }

    ///
    unittest
    {
        // ZstdCompressor 截断数据测试
        auto zc = new ZstdCompressor();

        // 先压缩一些数据
        ubyte[] original = new ubyte[100];
        original[] = 0x77;
        auto compressed = zc.compress(Slice(original));
        assert(compressed !is null);

        // 截断压缩数据
        if (compressed.length > 10)
        {
            ubyte[] truncated = compressed[0 .. $ - 10];
            ubyte[] output;
            auto status = zc.decompress(Slice(truncated), output);
            assert(!status.ok(), "截断数据解压应失败");
            assert(status.isCorruption(), "应返回 corruption 状态");
        }
    }

    ///
    unittest
    {
        // ZstdCompressor 大数据测试
        auto zc = new ZstdCompressor();

        // 1MB 重复数据
        size_t dataSize = 1024 * 1024;
        ubyte[] largeData = new ubyte[dataSize];
        foreach (i; 0 .. dataSize)
            largeData[i] = cast(ubyte)(i % 256);

        auto compressed = zc.compress(Slice(largeData));
        if (compressed !is null)
        {
            assert(compressed.length < largeData.length, "压缩后应更小");

            ubyte[] decompressed;
            auto status = zc.decompress(Slice(compressed), decompressed);
            assert(status.ok(), "解压应成功");
            assert(decompressed.length == largeData.length, "长度应一致");

            // 验证数据完整性
            bool match = true;
            foreach (i; 0 .. dataSize)
            {
                if (decompressed[i] != largeData[i])
                {
                    match = false;
                    break;
                }
            }
            assert(match, "数据应完全一致");
        }
    }
}
