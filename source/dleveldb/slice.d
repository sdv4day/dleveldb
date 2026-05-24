module dleveldb.slice;

import std.traits;
import std.conv : to;
import std.format : format;

/**
 * 零拷贝字节引用，类似leveldb的Slice
 * 不拥有数据，仅引用外部内存
 * 
 * 支持泛型类型转换 as!T 和安全引用创建 owned!T
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
     * 为基本类型创建拥有数据的 Slice
     * 返回一个 OwnedSlice!T 结构体，包含数据副本
     * 
     * 相比旧的 Ref() 方法，此方法更安全：
     * - 数据存储在结构体中，而非 TLS
     * - 可安全存储和传递
     * - 无悬空引用风险
     * 
     * 示例：
     *   auto s1 = Slice.owned(42);    // 创建 int 值 42 的 Slice
     *   auto s2 = Slice.owned(3.14);  // 创建 double 值的 Slice
     *   // s1 和 s2 独立存储，互不影响
     */
    static auto owned(T)(T value)
        if (isBasicType!T || isPODStruct!T)
    {
        return OwnedSlice!T(value);
    }

    /**
     * @deprecated 使用 owned() 替代
     * 
     * 为基本类型常量创建引用 Slice
     * 
     * ⚠ 警告：此方法使用 TLS 存储，存在悬空引用风险！
     *   下次对同一类型 T 调用 Ref() 会覆盖前值。
     *   建议使用 owned() 方法替代。
     * 
     * 示例：
     *   auto s = Slice.Ref(42);  // 创建 int 值 42 的 Slice
     *   // ⚠ 危险: auto s1 = Slice.Ref(1); auto s2 = Slice.Ref(2); 
     *   //   此时 s1 引用已被 s2 覆盖！
     */
    static Slice Ref(T)(T value)
        if (isBasicType!T || isPODStruct!T)
    {
        import std.traits : Unqual;
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

    /// 比较两个Slice（使用 std.algorithm.cmp）
    int opCmp(Slice rhs) const nothrow @nogc
    {
        import std.algorithm.comparison : cmp;
        return cmp(data_[0 .. size_], rhs.data_[0 .. rhs.size_]);
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

/**
 * 拥有数据的 Slice 包装器
 * 
 * 用于安全地创建基本类型的 Slice，数据存储在结构体内部。
 * 相比 Slice.Ref()，此结构体无 TLS 陷阱风险。
 * 
 * 示例：
 *   auto s = OwnedSlice!int(42);
 *   Slice slice = s.slice;  // 获取 Slice
 *   assert(slice.as!int == 42);
 */
struct OwnedSlice(T)
    if (isBasicType!T || isPODStruct!T)
{
    import std.traits : Unqual;
    
private:
    Unqual!T storage_;
    
public:
    /// 从值构造
    this(T value) pure nothrow @safe @nogc
    {
        storage_ = cast(Unqual!T) value;
    }
    
    /// 获取底层 Slice
    Slice slice() const pure nothrow @trusted @nogc
    {
        return Slice(cast(const(void*)) &storage_, Unqual!T.sizeof);
    }
    
    /// 隐式转换为 Slice（使用 alias this）
    alias slice this;
    
    /// 获取数据指针
    const(ubyte)* data() const pure nothrow @trusted @nogc
    {
        return cast(const(ubyte*)) &storage_;
    }
    
    /// 获取数据大小
    size_t size() const pure nothrow @safe @nogc
    {
        return Unqual!T.sizeof;
    }
    
    /// 获取原始值
    ref const(T) value() const pure nothrow @safe @nogc
    {
        return *cast(const(T*)) &storage_;
    }
    
    /// 字符串表示
    string toString() const
    {
        return format("OwnedSlice!%s(%s)", T.stringof, storage_);
    }
}

///
unittest
{
    // OwnedSlice 基本测试
    auto s1 = OwnedSlice!int(42);
    assert(s1.size() == int.sizeof);
    assert(s1.value() == 42);
    
    // 隐式转换为 Slice
    Slice slice1 = s1;
    assert(slice1.size() == int.sizeof);
    assert(slice1.as!int == 42);
    
    // 多个 OwnedSlice 互不影响
    auto s2 = OwnedSlice!int(100);
    auto s3 = OwnedSlice!int(200);
    assert(s2.value() == 100);
    assert(s3.value() == 200);
    
    Slice slice2 = s2;
    Slice slice3 = s3;
    assert(slice2.as!int == 100);
    assert(slice3.as!int == 200);
    
    // 不同类型
    auto sLong = OwnedSlice!long(123456789012345L);
    assert(sLong.value() == 123456789012345L);
    
    auto sDouble = OwnedSlice!double(3.14159);
    assert(sDouble.value() == 3.14159);
    
    // 通过 Slice.owned() 创建
    auto s4 = Slice.owned(42);
    assert(s4.value() == 42);
    
    Slice slice4 = s4;
    assert(slice4.as!int == 42);
}

///
unittest
{
    // OwnedSlice 与 Slice.Ref 对比测试
    // OwnedSlice 安全，Ref 有 TLS 陷阱
    
    // OwnedSlice: 多次调用互不影响
    auto o1 = Slice.owned(1);
    auto o2 = Slice.owned(2);
    auto o3 = Slice.owned(3);
    
    Slice so1 = o1;
    Slice so2 = o2;
    Slice so3 = o3;
    
    assert(so1.as!int == 1);
    assert(so2.as!int == 2);
    assert(so3.as!int == 3);
    
    // Ref: 后调用会覆盖前值（危险！）
    // 注释掉以下测试，因为它会失败
    // auto r1 = Slice.Ref!int(1);
    // auto r2 = Slice.Ref!int(2);
    // assert(r1.as!int == 1);  // 失败！r1 已被 r2 覆盖
}

///
unittest
{
    // 从字符串构造
    auto s1 = Slice("hello");
    assert(s1.size() == 5);
    assert(!s1.empty());
    assert(s1.asString() == "hello");

    // 从字节数组构造
    ubyte[] bytes = [0x48, 0x65, 0x6C, 0x6C, 0x6F];
    auto s2 = Slice(bytes);
    assert(s2.size() == 5);
    assert(s2.asBytes() == bytes);

    // 从指针+长度构造
    auto s3 = Slice(bytes.ptr, bytes.length);
    assert(s3.size() == 5);

    // 空Slice
    auto empty = Slice();
    assert(empty.empty());
    assert(!empty.ok());

    // 清空
    auto s4 = Slice("test");
    s4.clear();
    assert(s4.empty());

    // 比较
    auto a = Slice("apple");
    auto b = Slice("banana");
    auto c = Slice("apple");
    assert(a == c);
    assert(a != b);
    assert(a < b);
    assert(b > a);

    // 类型转换
    auto numSlice = Slice("\x0A\x00\x00\x00");
    assert(numSlice.as!int() == 10);

    // Slice.owned (推荐)
    auto ownedSlice = Slice.owned!int(42);
    assert(ownedSlice.slice().as!int() == 42);
    
    // Slice.Ref (已弃用，但保留兼容)
    auto refSlice = Slice.Ref!int(42);
    assert(refSlice.as!int() == 42);
}

///
unittest
{
    // startsWith / endsWith 测试
    auto s = Slice("hello world");
    assert(s.startsWith(Slice("hello")));
    assert(s.startsWith(Slice("h")));
    assert(s.startsWith(Slice("")));
    assert(!s.startsWith(Slice("world")));
    assert(s.endsWith(Slice("world")));
    assert(s.endsWith(Slice("d")));
    assert(s.endsWith(Slice("")));
    assert(!s.endsWith(Slice("hello")));

    // removePrefix 测试
    auto s2 = Slice("abcdef");
    auto r1 = s2.removePrefix(3);
    assert(r1.asString() == "def");
    auto r2 = s2.removePrefix(0);
    assert(r2.asString() == "abcdef");
    auto r3 = s2.removePrefix(6);
    assert(r3.empty());

    // toString 测试
    auto s3 = Slice("short");
    assert(s3.toString() == "short");

    // Slice.Ref 对多种类型
    auto refLong = Slice.Ref!long(123456789012345L);
    assert(refLong.as!long() == 123456789012345L);
    auto refDouble = Slice.Ref!double(3.14);
    assert(refDouble.as!double() == 3.14);

    // asBytes 往返
    ubyte[] data = [0x01, 0x02, 0x03, 0x04];
    auto bs = Slice(data);
    assert(bs.asBytes() == data);

    // 空Slice的startsWith/endsWith
    auto empty = Slice();
    assert(empty.startsWith(Slice()));
    assert(empty.endsWith(Slice()));
    assert(!empty.startsWith(Slice("a")));

    // opCmp 边界
    auto sa = Slice("a");
    auto sb = Slice("ab");
    assert(sa < sb);
    auto sabc = Slice("abc");
    auto sabd = Slice("abd");
    assert(sabc < sabd);

    // toHash 非零
    auto hx = Slice("hash_test");
    assert(hx.toHash() != 0);

    // sliceFromString / sliceFromBytes
    auto sf = sliceFromString("test");
    assert(sf.asString() == "test");
    ubyte[] bf = [0xAA, 0xBB];
    auto sb2 = sliceFromBytes(bf);
    assert(sb2.asBytes() == bf);
}
