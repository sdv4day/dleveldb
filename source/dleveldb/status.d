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

    this(Code code, string msg)
    {
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
    Code code() const pure nothrow @safe
    {
        if (msg_ is null) return Code.ok;
        if (msg_.startsWith("NotFound")) return Code.notFound;
        if (msg_.startsWith("Corruption")) return Code.corruption;
        if (msg_.startsWith("Not implemented")) return Code.notSupported;
        if (msg_.startsWith("Invalid argument")) return Code.invalidArgument;
        if (msg_.startsWith("IO error")) return Code.ioError;
        return Code.ok;
    }

    bool isNotFound() const pure nothrow @safe
    {
        return !ok() && msg_.startsWith("NotFound");
    }

    bool isCorruption() const pure nothrow @safe
    {
        return !ok() && msg_.startsWith("Corruption");
    }

    bool isNotSupported() const pure nothrow @safe
    {
        return !ok() && msg_.startsWith("Not implemented");
    }

    bool isInvalidArgument() const pure nothrow @safe
    {
        return !ok() && msg_.startsWith("Invalid argument");
    }

    bool isIoError() const pure nothrow @safe
    {
        return !ok() && msg_.startsWith("IO error");
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
