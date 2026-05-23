module dleveldb.status;

import dleveldb.slice;
import std.algorithm.searching : startsWith;

/**
 * 操作结果状态，类似leveldb的Status
 * 使用短字符串优化：OK状态为零开销
 */
struct Status
{
    enum Code : ubyte
    {
        ok = 0,
        notFound = 1,
        corruption = 2,
        notSupported = 3,
        invalidArgument = 4,
        ioError = 5,
    }

    private string msg_;
    private Code code_ = Code.ok;

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

    bool ok() const pure nothrow @safe @nogc { return msg_ is null; }

    /// 获取状态码
    Code code() const pure nothrow @safe @nogc
    {
        return code_;
    }

    bool isNotFound() const pure nothrow @safe @nogc
    {
        return code_ == Code.notFound;
    }

    bool isCorruption() const pure nothrow @safe @nogc
    {
        return code_ == Code.corruption;
    }

    bool isNotSupported() const pure nothrow @safe @nogc
    {
        return code_ == Code.notSupported;
    }

    bool isInvalidArgument() const pure nothrow @safe @nogc
    {
        return code_ == Code.invalidArgument;
    }

    bool isIoError() const pure nothrow @safe @nogc
    {
        return code_ == Code.ioError;
    }

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
}
