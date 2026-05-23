/**
 * 双库交叉验证测试主程序
 * 使用两个 dleveldb 实例进行交叉对比验证
 */
module dual_test_app;

import dleveldb.dual_db_test;
shared static this()
{
    import core.sys.windows.windows;
    SetConsoleOutputCP(65001);
    SetConsoleCP(65001);    
}
int main()
{
    runDualDbTests();
    return 0;
}
