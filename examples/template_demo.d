/+ dub.sdl:
name "template_demo"
dependency "silly" version="~>1.1.1"
+/

/**
 * 模板和 static if 示例
 * 
 * 演示如何使用模板元编程和编译时分支判断
 * 符合 Dlang_SP.md 第 2 节规范
 * 
 * 使用方法:
 *   dub --single examples/template_demo.d
 */
module template_demo;

import std.stdio;
import std.traits;
import std.conv;

// ====== 示例 1: 使用 static if 进行类型分支 ======

/// 根据类型执行不同操作
void processValue(T)(T value)
{
    static if (isIntegral!T)
    {
        // 处理整数类型
        writeln("整数: ", value, " (类型: ", T.stringof, ")");
    }
    else static if (isFloatingPoint!T)
    {
        // 处理浮点类型
        writeln("浮点数: ", value, " (类型: ", T.stringof, ")");
    }
    else static if (isSomeString!T)
    {
        // 处理字符串类型
        writeln("字符串: \"", value, "\" (长度: ", value.length, ")");
    }
    else
    {
        static assert(false, "不支持的类型: " ~ T.stringof);
    }
}

// ====== 示例 2: 使用模板约束 ======

/// 只接受数值类型的加法函数
auto addNumbers(T, U)(T a, U b)
    if (isNumeric!T && isNumeric!U)
{
    return a + b;
}

// ====== 示例 3: 可变参数模板 ======

/// 打印任意数量的参数
void printArgs(Args...)(Args args)
{
    static if (args.length == 0)
    {
        writeln();
    }
    else
    {
        write(args[0]);
        static if (args.length > 1)
        {
            write(", ");
            printArgs(args[1 .. $]);
        }
        else
        {
            writeln();
        }
    }
}

// ====== 示例 4: 使用 traits 进行编译时检查 ======

/// 检查类型是否有特定方法
template hasToString(T)
{
    enum bool hasToString = __traits(hasMember, T, "toString");
}

// 示例类
class Person
{
    string name;
    int age;
    
    this(string name, int age)
    {
        this.name = name;
        this.age = age;
    }
    
    override string toString() const
    {
        return name ~ " (年龄: " ~ to!string(age) ~ ")";
    }
}

// ====== 主函数 ======

void main()
{
    writeln("=== 模板和 static if 示例 ===");
    writeln();
    
    // 示例 1: 类型分支
    writeln("1. 使用 static if 进行类型分支:");
    processValue(42);
    processValue(3.14);
    processValue("Hello");
    writeln();
    
    // 示例 2: 模板约束
    writeln("2. 使用模板约束的数值加法:");
    writeln("   1 + 2 = ", addNumbers(1, 2));
    writeln("   1.5 + 2.5 = ", addNumbers(1.5, 2.5));
    writeln("   1 + 2.5 = ", addNumbers(1, 2.5));
    writeln();
    
    // 示例 3: 可变参数模板
    writeln("3. 可变参数模板打印:");
    write("   参数: ");
    printArgs(1, "hello", 3.14, true);
    writeln();
    
    // 示例 4: traits 检查
    writeln("4. 使用 traits 进行编译时检查:");
    auto person = new Person("张三", 25);
    static if (hasToString!(typeof(person)))
    {
        writeln("   Person 有 toString 方法: ", person.toString());
    }
    else
    {
        writeln("   Person 没有 toString 方法");
    }
    writeln();
    
    writeln("所有类型检查和分支都在编译时完成！");
}

// ====== 单元测试 ======

unittest
{
    // 测试类型分支
    // processValue 会在编译时选择正确的分支
    
    // 测试模板约束
    assert(addNumbers(1, 2) == 3);
    assert(addNumbers(1.5, 2.5) == 4.0);
    assert(addNumbers(1, 2.5) == 3.5);
    
    // 测试可变参数模板
    // printArgs 只是打印，不需要断言
    
    // 测试 traits 检查
    static assert(hasToString!Person);
    static assert(!hasToString!int);
    
    // 测试 Person 类
    auto person = new Person("李四", 30);
    assert(person.toString() == "李四 (年龄: 30)");
}
