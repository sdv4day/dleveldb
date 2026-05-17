module dleveldb.filename;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.env;

import std.format : format;
import std.conv : to;

/**
 * 文件命名规则
 * 
 * 日志文件：/{number}.log
 * SSTable文件：/{number}.ldb
 * 描述文件：/MANIFEST-{number}
 * 当前文件：/CURRENT
 * 锁文件：/LOCK
 * 信息日志：/LOG
 * 临时文件：/{number}.dbtmp
 */

/// 构建日志文件名
string logFileName(string dbname, ulong number)
{
    return format("%s/%06d.log", dbname, number);
}

/// 构建SSTable文件名
string tableFileName(string dbname, ulong number)
{
    return format("%s/%06d.ldb", dbname, number);
}

/// 构建SSTable文件名（.sst后缀）
string sstTableFileName(string dbname, ulong number)
{
    return format("%s/%06d.sst", dbname, number);
}

/// 构建描述文件名
string descriptorFileName(string dbname, ulong number)
{
    return format("%s/MANIFEST-%06d", dbname, number);
}

/// 构建当前文件名
string currentFileName(string dbname)
{
    return dbname ~ "/CURRENT";
}

/// 构建锁文件名
string lockFileName(string dbname)
{
    return dbname ~ "/LOCK";
}

/// 构建信息日志文件名
string infoLogFileName(string dbname)
{
    return dbname ~ "/LOG";
}

/// 构建旧信息日志文件名
string oldInfoLogFileName(string dbname)
{
    return dbname ~ "/LOG.old";
}

/// 构建临时文件名
string tempFileName(string dbname, ulong number)
{
    return format("%s/%06d.dbtmp", dbname, number);
}

/**
 * 解析文件名，提取文件类型和编号
 */
bool parseFileName(string fname, ref ulong number, ref FileType type)
{
    Slice s = sliceFromString(fname);

    // 去除目录前缀
    size_t pos = fname.lastIndexOf('/');
    if (pos != size_t.max)
    {
        fname = fname[pos + 1 .. $];
    }

    // 尝试解析各种文件类型
    if (fname == "CURRENT")
    {
        number = 0;
        type = FileType.current;
        return true;
    }
    else if (fname == "LOCK")
    {
        number = 0;
        type = FileType.dbLock;
        return true;
    }
    else if (fname == "LOG" || fname == "LOG.old")
    {
        number = 0;
        type = FileType.infoLog;
        return true;
    }

    // 解析带编号的文件名
    size_t dotPos = fname.lastIndexOf('.');
    if (dotPos == size_t.max)
        return false;

    string suffix = fname[dotPos .. $];
    string prefix = fname[0 .. dotPos];

    // 解析编号
    try
    {
        number = to!ulong(prefix);
    }
    catch (Exception)
    {
        // MANIFEST-{number}格式
        if (prefix.startsWith("MANIFEST-"))
        {
            try
            {
                number = to!ulong(prefix[9 .. $]);
                type = FileType.descriptor;
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }
        return false;
    }

    // 根据后缀确定类型
    if (suffix == ".log")
    {
        type = FileType.log;
        return true;
    }
    else if (suffix == ".ldb" || suffix == ".sst")
    {
        type = FileType.table;
        return true;
    }
    else if (suffix == ".dbtmp")
    {
        type = FileType.temp;
        return true;
    }

    return false;
}

/// 判断字符串是否以指定前缀开头
private bool startsWith(string s, string prefix) pure nothrow @safe
{
    if (s.length < prefix.length)
        return false;
    return s[0 .. prefix.length] == prefix;
}

/// 查找最后一个指定字符的位置
private size_t lastIndexOf(string s, char c) pure nothrow @safe
{
    for (size_t i = s.length; i > 0; i--)
    {
        if (s[i - 1] == c)
            return i - 1;
    }
    return size_t.max;
}
