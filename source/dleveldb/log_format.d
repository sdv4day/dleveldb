module dleveldb.log_format;

/**
 * WAL日志格式常量
 */

/// 块大小：32KB
enum int kBlockSize = 32768;

/// 记录头大小：checksum(4) + length(2) + type(1) = 7字节
enum int kHeaderSize = 4 + 2 + 1;

/// 记录类型
enum RecordType : ubyte
{
    full = 1,
    first = 2,
    middle = 3,
    last = 4,
}

/// 日志文件魔数（用于校验）
enum uint kLogMagic = 0xdb;
