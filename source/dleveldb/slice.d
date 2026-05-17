module dleveldb.slice;

import std.traits;
import std.conv : to;

/**
 * 零拷贝字节引用，类似leveldb的Slice
 * 不拥有数据，仅引用外部内存
 * 
 * 支持泛型类型转换 as!T 和安全引用创建 Ref!T
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

    /// 别名：兼容 _lib_obj_size__
    alias length = size;

    /// 是否为空
    bool empty() const pure nothrow @safe @nogc { return size_ == 0; }

    /// 别名：兼容 etc.dleveldb.Slice
    alias isEmpty = empty;

    /// 是否有效（非空）
    bool ok() const pure nothrow @safe @nogc { return size_ > 0; }

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

    /**
     * 泛型类型转换：将 Slice 数据解释为类型 T
     * 
     * 支持类型：
     *   - 字符串：as!string → 复制为 string
     *   - 基本类型：as!int / as!long / as!double 等
     *   - POD 结构体：as!Point 等
     *   - 动态数组：as!(int[]) 等
     */
    @property
    inout(T) as(T)() inout
        if (!isPointer!T && __traits(compiles, *(cast(inout(T*)) data_)))
    {
        static if (isSomeString!T)
        {
            return (cast(inout(T)) (cast(inout(char)*) data_)[0 .. size_]).idup;
        }
        else static if (isDynamicArray!T && !is(T == class))
        {
            import std.range.primitives : ElementEncodingType;
            return cast(inout(T)) (cast(inout(ElementEncodingType!T)*) data_)[0 .. size_ / ElementEncodingType!T.sizeof];
        }
        else
        {
            return *(cast(inout(T*)) data_);
        }
    }

    /// 别名：to 是 as 的别名
    alias to = as;

    /**
     * 隐式类型转换重载
     * 指针类型走 ptr!T，其他走 as!T
     */
    inout(T) opCast(T)() inout
    {
        static if (isPointer!T)
        {
            return cast(inout(T)) data_;
        }
        else
        {
            return this.as!T;
        }
    }

    /**
     * 为基本类型常量创建安全引用 Slice
     * 数据存储在 TLS 缓冲区中，Slice 仅引用
     * 
     * 示例：
     *   auto s = Slice.Ref(42);  // 创建 int 值 42 的 Slice
     */
    static Slice Ref(T)(T value)
        if (isBasicType!T || isPODStruct!T)
    {
        import std.traits : Unqual;
        // 使用 TLS 缓冲区存储值
        static Unqual!T storage;
        storage = cast(Unqual!T) value;
        return Slice(cast(const(void*)) &storage, Unqual!T.sizeof);
    }

    /// 兼容接口：获取 const(char)* 指针
    @property
    const(char)* _lib_obj_ptr__() const pure nothrow @trusted @nogc
    {
        return cast(const(char)*) data_;
    }

    /// 兼容接口：获取字节大小
    @property
    size_t _lib_obj_size__() const pure nothrow @safe @nogc
    {
        return size_;
    }

    /// 比较两个Slice（使用D标准数组比较）
    int opCmp(Slice rhs) const nothrow @nogc
    {
        size_t minLen = size_ < rhs.size_ ? size_ : rhs.size_;
        int r = 0;
        if (minLen > 0)
        {
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
        return data_[0 .. size_] == rhs.data_[0 .. size_];
    }

    /// 哈希值（使用MurmurHash3）
    size_t toHash() const nothrow @nogc
    {
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
        import std.format : format;
        if (size_ <= 64)
        {
            return asString().idup;
        }
        return format("%s...(truncated %d bytes)", asString()[0 .. 64].idup, size_ - 64);
    }
}

/// 判断类型是否为 POD 结构体
template isPODStruct(T)
{
    enum isPODStruct = is(T == struct) && !isDynamicArray!T && !isSomeString!T;
}

/// 获取类型的字节大小（用于 _lib_obj_size__ 兼容）
size_t _lib_obj_size__(P)(in P p)
    if (isSomeString!P || (isDynamicArray!P && !isBanned!(ForeachType!P)))
{
    return p.length;
}

/// 获取基本类型/POD结构体的字节大小
size_t _lib_obj_size__(P)(in P p)
    if (isBasicType!P || isPODStruct!P)
{
    return P.sizeof;
}

/// 获取指针指向数据的字节大小
size_t _lib_obj_size__(P)(in P p)
    if (isPointer!P)
{
    return p.sizeof;
}

/// 获取数据的 const(char)* 指针
const(char)* _lib_obj_ptr__(P)(ref P p)
{
    static if (isSomeString!P || isDynamicArray!P)
        return cast(const(char)*) p.ptr;
    else static if (isPointer!P)
        return cast(const(char)*) p;
    else
        return cast(const(char)*) &p;
}

/// 判断类型是否被禁止（class、动态数组、指针）
template isBanned(T)
{
    enum isBanned = is(T == class) || isDynamicArray!T || isPointer!T;
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
