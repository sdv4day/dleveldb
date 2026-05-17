module dleveldb.options;

import dleveldb.comparator;
import dleveldb.filter_policy;
import dleveldb.key_filter;
import dleveldb.compression_filter;
import dleveldb.compression;
import dleveldb.env;
import std.experimental.allocator : IAllocator;

/**
 * 数据库配置选项
 */
struct Options
{
    /// 键比较器
    Comparator comparator = null;

    /// 数据库不存在时是否创建
    bool createIfMissing = false;

    /// 数据库已存在时是否报错
    bool errorIfExists = false;

    /// 是否启用激进校验
    bool paranoidChecks = false;

    /// 环境抽象
    Env env = null;

    /// MemTable大小阈值（默认4MB）
    size_t writeBufferSize = 4 * 1024 * 1024;

    /// 最大打开文件数
    int maxOpenFiles = 1000;

    /// 块缓存容量（默认8MB）
    size_t blockCacheCapacity = 8 * 1024 * 1024;

    /// SSTable数据块大小（默认4KB）
    size_t blockSize = 4 * 1024;

    /// 块内重启点间隔
    int blockRestartInterval = 16;

    /// SSTable文件最大大小（默认2MB）
    size_t maxFileSize = 2 * 1024 * 1024;

    /// 压缩算法
    CompressionType compression = CompressionType.snappy;

    /// 过滤器策略（默认布隆过滤器）
    FilterPolicy filterPolicy = null;

    /// 键过滤器（默认不过滤）
    KeyFilter keyFilter = null;

    /// 压缩过滤器（默认不过滤）
    CompressionFilter compressionFilter = null;

    /// 是否重用日志文件（实验性）
    bool reuseLogs = false;

    /// 内存分配器（默认null，使用Arena+Mallocator）
    IAllocator allocator = null;
}

/// 读取选项
struct ReadOptions
{
    /// 是否校验校验和
    bool verifyChecksums = false;

    /// 是否填充块缓存
    bool fillCache = true;

    /// 读取快照（0表示最新）
    ulong snapshot = 0;
}

/// 写入选项
struct WriteOptions
{
    /// 写后是否同步（fsync）
    bool sync = false;
}

/**
 * 校验和修正选项值
 */
Options sanitizeOptions(Options options)
{
    import dleveldb.comparator : defaultComparator;
    import dleveldb.filter_policy : newBloomFilterPolicy;
    import dleveldb.key_filter : newNullKeyFilter;
    import dleveldb.compression_filter : newNullCompressionFilter;

    Options result = options;

    if (result.comparator is null)
        result.comparator = defaultComparator();

    if (result.env is null)
        result.env = defaultEnv();

    if (result.filterPolicy is null)
        result.filterPolicy = newBloomFilterPolicy(10);

    if (result.keyFilter is null)
        result.keyFilter = newNullKeyFilter();

    if (result.compressionFilter is null)
        result.compressionFilter = newNullCompressionFilter();

    // 校验范围
    if (result.maxOpenFiles < 74)
        result.maxOpenFiles = 74;
    if (result.maxOpenFiles > 50000)
        result.maxOpenFiles = 50000;

    if (result.writeBufferSize < 64 * 1024)
        result.writeBufferSize = 64 * 1024;
    if (result.writeBufferSize > 1024 * 1024 * 1024)
        result.writeBufferSize = 1024 * 1024 * 1024;

    if (result.maxFileSize < 1024 * 1024)
        result.maxFileSize = 1024 * 1024;
    if (result.maxFileSize > 1024 * 1024 * 1024)
        result.maxFileSize = 1024 * 1024 * 1024;

    if (result.blockSize < 1024)
        result.blockSize = 1024;
    if (result.blockSize > 4 * 1024 * 1024)
        result.blockSize = 4 * 1024 * 1024;

    return result;
}
