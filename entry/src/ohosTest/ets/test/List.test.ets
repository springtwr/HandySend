// Instrument Test 测试入口：挂载全部 ohosTest 套件
// 各子模块的测试套件在此注册，与 entry/src/test/List.test.ets（Local Test）格式一致

// ── NativeBridge .so 函数测试 ──
import ServerNativeTest from './native/ServerNativeTest.test'
import DiscoveryNativeTest from './native/DiscoveryNativeTest.test'
import SendNativeTest from './native/SendNativeTest.test'
import WebShareNativeTest from './native/WebShareNativeTest.test'
import SecurityNativeTest from './native/SecurityNativeTest.test'
import UtilityNativeTest from './native/UtilityNativeTest.test'
import VersionNativeTest from './native/VersionNativeTest.test'
import LoopbackNativeTest from './native/LoopbackNativeTest.test'
import LoopbackTransferTest from './native/LoopbackTransferTest.test'

// ── NativeTypes 事件解析测试 ──
import NativeEventParseTest from './parsing/NativeEventParseTest.test'

// ── Repository 业务逻辑测试 ──
import ServerRepositoryTest from './repository/ServerRepositoryTest.test'
import DiscoveryRepositoryTest from './repository/DiscoveryRepositoryTest.test'
import SendRepositoryTest from './repository/SendRepositoryTest.test'
import WebShareRepositoryTest from './repository/WebShareRepositoryTest.test'
import ProgressLogicTest from './repository/ProgressLogicTest.test'
import ReceiveBehaviorTest from './repository/ReceiveBehaviorTest.test'

export default function testsuite() {
  // ── Native 测试套件 ──
  ServerNativeTest()
  DiscoveryNativeTest()
  SendNativeTest()
  WebShareNativeTest()
  SecurityNativeTest()
  UtilityNativeTest()
  VersionNativeTest()
  LoopbackNativeTest()
  LoopbackTransferTest()

  // ── 解析测试套件 ──
  NativeEventParseTest()

  // ── Repository 业务逻辑测试套件 ──
  ServerRepositoryTest()
  DiscoveryRepositoryTest()
  SendRepositoryTest()
  WebShareRepositoryTest()
  ProgressLogicTest()
  ReceiveBehaviorTest()
}
