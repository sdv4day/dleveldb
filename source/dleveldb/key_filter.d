module dleveldb.key_filter;

import dleveldb.slice;

/**
 * 键过滤器接口
 * 用户可实现此接口来过滤不需要的键
 * 在读写和压缩时都会调用
 */
interface KeyFilter
{
    /// 返回true表示该键应被过滤（跳过）
    /// 在写入时：跳过写入
    /// 在读取时：直接返回NotFound
    /// 在压缩时：跳过该键值对
    bool filter(Slice key) const;
}

/**
 * 默认键过滤器：不过滤任何键
 */
class NullKeyFilter : KeyFilter
{
    bool filter(Slice key) const pure nothrow @safe @nogc
    {
        return false;
    }
}

/**
 * 前缀键过滤器：过滤指定前缀的键
 */
class PrefixKeyFilter : KeyFilter
{
private:
    Slice prefix_;

public:
    this(Slice prefix)
    {
        prefix_ = prefix;
    }

    bool filter(Slice key) const nothrow @nogc
    {
        return key.startsWith(prefix_);
    }
}

/// 创建默认键过滤器
KeyFilter nullKeyFilter()
{
    return new NullKeyFilter();
}

/// 创建前缀键过滤器
KeyFilter prefixKeyFilter(Slice prefix)
{
    return new PrefixKeyFilter(prefix);
}
