module dleveldb.compression_filter;

import dleveldb.slice;

/**
 * 压缩过滤器结果
 */
enum CompressionFilterResult : ubyte
{
    keep = 0,    /// 保留该键值对
    remove = 1,  /// 丢弃该键值对
    change = 2,  /// 修改值
}

/**
 * 压缩过滤器接口
 * 在压缩过程中对每个键值对进行过滤决策
 * 用户可实现此接口来控制压缩时的数据保留/丢弃/修改
 */
interface CompressionFilter
{
    /// 压缩开始时通知（可用于创建快照）
    void snapshot() const;

    /// 过滤决策
    /// key: 当前键
    /// value: 当前值
    /// newValue: 如果返回change，设置新值
    /// 返回: keep/remove/change
    CompressionFilterResult filter(Slice key, Slice value, ref Slice newValue) const;
}

/**
 * 默认压缩过滤器：保留所有键值对
 */
class NullCompressionFilter : CompressionFilter
{
    void snapshot() const pure nothrow @safe @nogc
    {
    }

    CompressionFilterResult filter(Slice key, Slice value, ref Slice newValue) const pure nothrow @safe @nogc
    {
        return CompressionFilterResult.keep;
    }
}

/// 创建默认压缩过滤器
CompressionFilter newNullCompressionFilter()
{
    return new NullCompressionFilter();
}
