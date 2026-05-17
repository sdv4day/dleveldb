module dleveldb.slice;

/**
 * 零拷贝字节引用，类似leveldb的Slice
 * 不拥有数据，仅引用外部内存
 */
struct Slice
{
    const(ubyte)* data_ = null;
    size_t size_ = 0;

    this(const(ubyte)[] arr) pure nothrow @trusted @nogc
    {
        data_ = arr.ptr;
        size_ = arr.length;
    }

    this(const(char)[] str) pure nothrow @trusted @nogc
    {
        data_ = cast(const(ubyte)*) str.ptr;
        size_ = str.length;
    }

    this(const void* ptr, size_t len) pure nothrow @safe @nogc
    {
        data_ = cast(const(ubyte)*) ptr;
        size_ = len;
    }

    /// 获取数据指针
    const(ubyte)* data() const pure nothrow @safe @nogc { return data_; }

    /// 获取数据长度
    size_t size() const pure nothrow @safe @nogc { return size_; }

    /// 是否为空
    bool empty() const pure nothrow @safe @nogc { return size_ == 0; }

    /// 清空
    void clear() pure nothrow @safe @nogc
    {
        data_ = null;
        size_ = 0;
    }

    /// 转为ubyte数组视图
    const(ubyte)[] asBytes() const pure nothrow @trusted @nogc
    {
        return data_[0 .. size_];
    }

    /// 转为char数组视图
    const(char)[] asString() const pure nothrow @trusted @nogc
    {
        return (cast(const(char)*) data_)[0 .. size_];
    }

    /// 比较两个Slice（使用D标准数组比较）
    int opCmp(Slice rhs) const nothrow @nogc
    {
        size_t minLen = size_ < rhs.size_ ? size_ : rhs.size_;
        int r = 0;
        if (minLen > 0)
        {
            // 使用D标准数组切片比较替代memcmp
            auto a = data_[0 .. minLen];
            auto b = rhs.data_[0 .. minLen];
            if (a < b) r = -1;
            else if (a > b) r = 1;
        }
        if (r == 0)
        {
            if (size_ < rhs.size_)
                r = -1;
            else if (size_ > rhs.size_)
                r = 1;
        }
        return r;
    }

    /// 相等比较（使用D标准数组比较）
    bool opEquals(Slice rhs) const nothrow @nogc
    {
        if (size_ != rhs.size_)
            return false;
        if (size_ == 0)
            return true;
        // 使用D标准数组切片比较替代memcmp
        return data_[0 .. size_] == rhs.data_[0 .. size_];
    }

    /// 哈希值（使用MurmurHash3）
    size_t toHash() const nothrow @nogc
    {
        // 使用项目已有的高质量哈希函数
        import dleveldb.hash : hash;
        return cast(size_t) hash(Slice(data_, size_));
    }

    /// 前缀判断
    bool startsWith(Slice prefix) const nothrow @nogc
    {
        return (size_ >= prefix.size_) && (Slice(data_[0 .. prefix.size_]) == prefix);
    }

    /// 后缀判断
    bool endsWith(Slice suffix) const nothrow @nogc
    {
        return (size_ >= suffix.size_) &&
            (Slice(data_[size_ - suffix.size_ .. size_]) == suffix);
    }

    /// 去除前缀
    Slice removePrefix(size_t n) const pure nothrow @trusted @nogc
    in (n <= size_)
    {
        return Slice(data_ + n, size_ - n);
    }

    /// 字符串表示（用于调试）
    string toString() const
    {
        import std.conv : text;
        import std.format : format;
        if (size_ <= 64)
        {
            return asString().idup;
        }
        return format("%s...(truncated %d bytes)", asString()[0 .. 64].idup, size_ - 64);
    }
}

/// 从字符串创建Slice的便捷函数
Slice sliceFromString(const(char)[] s) pure nothrow @safe @nogc
{
    return Slice(s);
}

/// 从字节数组创建Slice的便捷函数
Slice sliceFromBytes(const(ubyte)[] arr) pure nothrow @safe @nogc
{
    return Slice(arr);
}
