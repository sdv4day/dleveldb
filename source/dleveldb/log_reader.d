module dleveldb.log_reader;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.log_format;
import dleveldb.crc32c;
import dleveldb.coding;
import dleveldb.env;

/**
 * WAL日志读取器
 * 从文件读取逻辑记录，自动重组分片
 */
class LogReader
{
private:
    SequentialFile file_;
    bool checksum_;        // 是否校验CRC
    ulong logNumber_;      // 日志编号
    ulong initialOffset_;  // 初始偏移

    ubyte[kBlockSize] backingStore_; // 读取缓冲区
    Slice buffer_;        // 当前缓冲区
    bool eof_;            // 是否到达文件末尾
    uint[5] typeCrc_;     // 预计算CRC

    // 读取统计
    ulong readBytes_;
    ulong lastRecordOffset_;

public:
    /// 构造WAL日志读取器
    ///
    /// Params:
    ///     file = 顺序读取文件
    ///     checksum = 是否校验CRC
    ///     logNumber = 日志编号
    ///     initialOffset = 初始偏移
    this(SequentialFile file, bool checksum = true, ulong logNumber = 0, ulong initialOffset = 0)
    {
        file_ = file;
        checksum_ = checksum;
        logNumber_ = logNumber;
        initialOffset_ = initialOffset;
        eof_ = false;
        readBytes_ = 0;
        lastRecordOffset_ = 0;

        // 预计算CRC
        for (int i = 0; i <= cast(int) RecordType.last; i++)
        {
            ubyte[6] buf;
            buf[0] = 0; buf[1] = 0;
            buf[2] = cast(ubyte) i;
            buf[3] = 0; buf[4] = 0; buf[5] = 0;
            typeCrc_[i] = crc32cValue(buf.ptr, 6);
        }
    }

    /// 读取一条逻辑记录
    /// 
    /// 注意：返回的 record Slice 可能有两种生命周期：
    /// 1. 对于完整记录（full type），record 指向内部缓冲区，在下一次 readRecord 调用前有效
    /// 2. 对于分片记录（first/middle/last），record 指向 scratch 缓冲区
    ///    调用者必须确保 scratch 在使用 record 期间不被修改或释放
    ///    如需长期保存数据，应将 record 内容复制到自己的缓冲区
    ///
    /// Params:
    ///     record = 输出记录数据（Slice 引用的内存由 scratch 或内部缓冲区提供）
    ///     scratch = 临时缓冲区，用于组装分片记录
    /// Returns: true 表示成功读取，false 表示到达文件末尾或出错
    bool readRecord(ref Slice record, ref ubyte[] scratch) 
    {
        while (true)
        {
            if (buffer_.size() < kHeaderSize)
            {
                if (!eof_)
                {
                    // 读取下一个块
                    readPhysicalRecord();
                }
                if (buffer_.size() < kHeaderSize)
                {
                    return false;
                }
            }

            // 解析记录头
            const(ubyte)* header = buffer_.data();
            uint crc = decodeFixed32(header);
            uint length = cast(uint) header[4] | (cast(uint) header[5] << 8);
            ubyte type = header[6];

            if (type == cast(ubyte) RecordType.full ||
                type == cast(ubyte) RecordType.first ||
                type == cast(ubyte) RecordType.middle ||
                type == cast(ubyte) RecordType.last)
            {
                // 检查长度
                if (kHeaderSize + length > buffer_.size())
                {
                    // 记录超出缓冲区
                    buffer_ = Slice();
                    continue;
                }

                // 校验CRC
                if (checksum_ && typeCrc_[type] != 0)
                {
                    uint expectedCrc = crc32cExtend(typeCrc_[type],
                        header + kHeaderSize, length);
                    if (crc != expectedCrc)
                    {
                        // CRC不匹配，跳过
                        buffer_ = Slice(buffer_.data() + kHeaderSize + length,
                            buffer_.size() - kHeaderSize - length);
                        continue;
                    }
                }

                Slice data = Slice(header + kHeaderSize, length);
                buffer_ = Slice(buffer_.data() + kHeaderSize + length,
                    buffer_.size() - kHeaderSize - length);

                if (type == cast(ubyte) RecordType.full)
                {
                    record = data;
                    lastRecordOffset_ = readBytes_ - buffer_.size() - kHeaderSize - length;
                    return true;
                }
                else if (type == cast(ubyte) RecordType.first)
                {
                    scratch.length = 0;
                    scratch ~= data.asBytes()[];
                }
                else if (type == cast(ubyte) RecordType.middle)
                {
                    scratch ~= data.asBytes()[];
                }
                else if (type == cast(ubyte) RecordType.last)
                {
                    scratch ~= data.asBytes()[];
                    record = Slice(scratch.ptr, scratch.length);
                    lastRecordOffset_ = readBytes_ - buffer_.size() - kHeaderSize - length;
                    return true;
                }
            }
            else
            {
                // 未知类型，跳过
                buffer_ = Slice();
            }
        }
    }

private:
    /// 读取一个物理块
    void readPhysicalRecord()
    {
        // 读取一个完整的块
        Status s = file_.read(kBlockSize, buffer_, backingStore_);
        if (!s.ok())
        {
            buffer_ = Slice();
            eof_ = true;
            return;
        }

        readBytes_ += buffer_.size();
        if (buffer_.size() < kBlockSize)
        {
            eof_ = true;
        }
    }
}
