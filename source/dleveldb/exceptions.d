module dleveldb.exceptions;

import dleveldb.status;
import std.format : format;

/**
 * LevelDB 异常类
 * 
 * 当数据库操作失败时抛出，替代 Status 返回值模式
 * 可从 Status 或字符串构造
 */
class LeveldbException : Exception
{
private:
    int code_; // Status.Code 值

public:
    /// 从错误字符串构造
    this(string errstr, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(errstr, file, line, next);
        code_ = 0;
    }

    /// 从 Status 构造
    this(ref const Status status, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        import dleveldb.status : Status;
        super(status.toString(), file, line, next);
        code_ = cast(int) status.code();
    }

    /// 获取状态码
    int code() const pure nothrow @safe @nogc { return code_; }
}

/**
 * 键未找到异常
 * 
 * 当使用关联数组语法 db["key"] 访问不存在的键时抛出
 */
class KeyNotFoundException : LeveldbException
{
private:
    string key_;

public:
    /// 从键构造
    this(string key, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(format("Key not found: %s", key), file, line, next);
        key_ = key;
    }

    /// 获取未找到的键
    string key() const pure nothrow @safe @nogc { return key_; }
}
