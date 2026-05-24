module dleveldb.status;

import dleveldb.slice;
import std.algorithm.searching : startsWith;

/**
 * 操作结果状态，类似leveldb的Status
 * 使用短字符串优化：OK状态为零开销
 */
struct Status
{
    /// 状态码枚举
    enum Code : ubyte
    {
        ok = 0,              /// 操作成功
        notFound = 1,        /// 未找到目标
        corruption = 2,      /// 数据损坏
        notSupported = 3,    /// 操作不支持
        invalidArgument = 4, /// 无效参数
        ioError = 5,         /// IO错误
    }

    private string msg_;
    private Code code_ = Code.ok;

    /// 构造指定状态码和消息的状态
    /// Params: code = 状态码, msg = 状态消息
    this(Code code, string msg)
    {
        code_ = code;
        final switch (code) with (Code)
        {
            case ok:
                msg_ = null;
                break;
            case notFound:
                msg_ = "NotFound: " ~ msg;
                break;
            case corruption:
                msg_ = "Corruption: " ~ msg;
                break;
            case notSupported:
                msg_ = "Not implemented: " ~ msg;
                break;
            case invalidArgument:
                msg_ = "Invalid argument: " ~ msg;
                break;
            case ioError:
                msg_ = "IO error: " ~ msg;
                break;
        }
    }

    /// 检查是否为成功状态
    /// Returns: 成功返回 true，否则返回 false
    bool ok() const pure nothrow @safe @nogc { return msg_ is null; }

    /// 获取状态码
    Code code() const pure nothrow @safe @nogc
    {
        return code_;
    }

    /// 检查是否为 NotFound 状态
    /// Returns: 是 NotFound 返回 true，否则返回 false
    bool isNotFound() const pure nothrow @safe @nogc
    {
        return code_ == Code.notFound;
    }

    /// 检查是否为 Corruption 状态
    /// Returns: 是 Corruption 返回 true，否则返回 false
    bool isCorruption() const pure nothrow @safe @nogc
    {
        return code_ == Code.corruption;
    }

    /// 检查是否为 NotSupported 状态
    /// Returns: 是 NotSupported 返回 true，否则返回 false
    bool isNotSupported() const pure nothrow @safe @nogc
    {
        return code_ == Code.notSupported;
    }

    /// 检查是否为 InvalidArgument 状态
    /// Returns: 是 InvalidArgument 返回 true，否则返回 false
    bool isInvalidArgument() const pure nothrow @safe @nogc
    {
        return code_ == Code.invalidArgument;
    }

    /// 检查是否为 IOError 状态
    /// Returns: 是 IOError 返回 true，否则返回 false
    bool isIoError() const pure nothrow @safe @nogc
    {
        return code_ == Code.ioError;
    }

    /// 将状态转为字符串表示
    /// Returns: 成功状态返回 "OK"，否则返回带前缀的错误消息
    string toString() const pure nothrow @safe
    {
        return msg_ is null ? "OK" : msg_;
    }

    /// 获取错误消息
    string message() const pure nothrow @safe
    {
        return msg_;
    }
}

/// 创建OK状态
Status statusOk() pure nothrow @safe @nogc
{
    return Status();
}

/// 创建NotFound状态
Status statusNotFound(string msg)
{
    return Status(Status.Code.notFound, msg);
}

/// 创建Corruption状态
Status statusCorruption(string msg)
{
    return Status(Status.Code.corruption, msg);
}

/// 创建NotSupported状态
Status statusNotSupported(string msg)
{
    return Status(Status.Code.notSupported, msg);
}

/// 创建InvalidArgument状态
Status statusInvalidArgument(string msg)
{
    return Status(Status.Code.invalidArgument, msg);
}

/// 创建IOError状态
Status statusIoError(string msg)
{
    return Status(Status.Code.ioError, msg);
}

/**
 * 检查 Status 并在错误时抛出异常
 * 
 * 示例：
 *   auto s = db.get(key, value);
 *   throwIfError(s);  // 如果 s 不是 OK，抛出 LeveldbException
 */
void throwIfError(Status s)
{
    if (!s.ok())
    {
        import dleveldb.exceptions : LeveldbException;
        throw new LeveldbException(s);
    }
}

/**
 * 检查 Status 并在错误时抛出异常（带上下文）
 * 
 * 示例：
 *   auto s = db.get(key, value);
 *   throwIfError(s, "读取键失败");
 */
void throwIfError(Status s, string context)
{
    if (!s.ok())
    {
        import dleveldb.exceptions : LeveldbException;
        import std.format : format;
        throw new LeveldbException(format("%s: %s", context, s.toString()));
    }
}

///
unittest
{
    // OK状态
    auto ok = Status();
    assert(ok.ok());
    assert(!ok.isNotFound());
    assert(!ok.isCorruption());
    assert(!ok.isNotSupported());
    assert(!ok.isInvalidArgument());
    assert(!ok.isIoError());
    assert(ok.toString() == "OK");
    assert(ok.code() == Status.Code.ok);

    // NotFound状态
    auto nf = statusNotFound("key not found");
    assert(!nf.ok());
    assert(nf.isNotFound());
    assert(nf.code() == Status.Code.notFound);
    assert(nf.toString().startsWith("NotFound:"));

    // Corruption状态
    auto cor = statusCorruption("bad data");
    assert(!cor.ok());
    assert(cor.isCorruption());
    assert(cor.code() == Status.Code.corruption);
    assert(cor.toString().startsWith("Corruption:"));

    // NotSupported状态
    auto ns = statusNotSupported("feature");
    assert(!ns.ok());
    assert(ns.isNotSupported());
    assert(ns.code() == Status.Code.notSupported);

    // InvalidArgument状态
    auto ia = statusInvalidArgument("bad arg");
    assert(!ia.ok());
    assert(ia.isInvalidArgument());
    assert(ia.code() == Status.Code.invalidArgument);

    // IOError状态
    auto io = statusIoError("disk fail");
    assert(!io.ok());
    assert(io.isIoError());
    assert(io.code() == Status.Code.ioError);

    // statusOk工厂函数
    auto ok2 = statusOk();
    assert(ok2.ok());

    // message() 获取错误消息
    assert(nf.message() !is null);
    assert(ok.message() is null);
    
    // throwIfError 测试
    // OK 状态不应抛出
    throwIfError(statusOk());
    throwIfError(statusOk(), "context");
    
    // 错误状态应抛出 LeveldbException
    import dleveldb.exceptions : LeveldbException;
    auto errStatus = statusNotFound("test error");
    bool caught = false;
    try
    {
        throwIfError(errStatus);
    }
    catch (LeveldbException e)
    {
        caught = true;
        assert(e.code() == Status.Code.notFound);
    }
    assert(caught, "throwIfError 应抛出 LeveldbException");
    
    // 带上下文的 throwIfError
    caught = false;
    try
    {
        throwIfError(statusCorruption("bad"), "操作失败");
    }
    catch (LeveldbException e)
    {
        caught = true;
        import std.algorithm.searching : canFind;
        assert(e.msg.canFind("操作失败"));
    }
    assert(caught);
}
