/+ dub.sdl:
name "ctfe_demo"
dependency "silly" version="~>1.1.1"
+/

/**
 * CTFE（编译时求值）示例
 * 
 * 演示如何在编译期间执行纯函数生成常量数据
 * 符合 Dlang_SP.md 第 2 节规范
 * 
 * 使用方法:
 *   dub --single examples/ctfe_demo.d
 */
module ctfe_demo;

import std.stdio;

// ====== 示例 1: 编译时生成查找表 ======

/// 在编译时生成平方表
int[] generateSquareTable(int size) pure @safe
{
    int[] result;
    result.length = size;
    foreach (i; 0 .. size)
    {
        result[i] = i * i;
    }
    return result;
}

// 在编译时计算，运行时直接使用
immutable int[] squareTable = generateSquareTable(10);

// ====== 示例 2: 编译时字符串处理 ======

/// 在编译时将字符串转换为大写
string toUpperCTFE(string input) pure @safe
{
    import std.ascii : toUpper;
    string result;
    foreach (c; input)
    {
        result ~= toUpper(c);
    }
    return result;
}

// 编译时转换
enum string upperHello = toUpperCTFE("hello");

// ====== 示例 3: 编译时数学计算 ======

/// 编译时计算阶乘
ulong factorial(uint n) pure @safe
{
    if (n <= 1)
        return 1;
    return n * factorial(n - 1);
}

// 编译时计算 10!
enum ulong fact10 = factorial(10);

// ====== 示例 4: 编译时数组操作 ======

/// 编译时生成斐波那契数列
int[] generateFibonacci(int count) pure @safe
{
    int[] fib;
    fib.length = count;
    if (count > 0) fib[0] = 0;
    if (count > 1) fib[1] = 1;
    
    for (int i = 2; i < count; i++)
    {
        fib[i] = fib[i-1] + fib[i-2];
    }
    return fib;
}

// 编译时生成前 10 个斐波那契数
immutable int[] fibonacci = generateFibonacci(10);

// ====== 主函数 ======

void main()
{
    writeln("=== CTFE 示例 ===");
    writeln();
    
    // 示例 1: 平方表
    writeln("1. 编译时生成的平方表:");
    foreach (i, val; squareTable)
    {
        writefln("   %d^2 = %d", i, val);
    }
    writeln();
    
    // 示例 2: 字符串转换
    writeln("2. 编译时字符串转换:");
    writeln("   'hello' -> '%s'", upperHello);
    writeln();
    
    // 示例 3: 阶乘计算
    writeln("3. 编译时阶乘计算:");
    writeln("   10! = %d", fact10);
    writeln();
    
    // 示例 4: 斐波那契数列
    writeln("4. 编译时生成的斐波那契数列:");
    foreach (i, val; fibonacci)
    {
        writefln("   fib[%d] = %d", i, val);
    }
    writeln();
    
    writeln("所有计算都在编译时完成，运行时零开销！");
}

// ====== 单元测试 ======

unittest
{
    // 测试平方表
    assert(squareTable.length == 10);
    assert(squareTable[0] == 0);
    assert(squareTable[1] == 1);
    assert(squareTable[5] == 25);
    assert(squareTable[9] == 81);
    
    // 测试字符串转换
    assert(upperHello == "HELLO");
    
    // 测试阶乘
    assert(fact10 == 3628800);
    
    // 测试斐波那契数列
    assert(fibonacci.length == 10);
    assert(fibonacci[0] == 0);
    assert(fibonacci[1] == 1);
    assert(fibonacci[5] == 5);
    assert(fibonacci[9] == 34);
}
