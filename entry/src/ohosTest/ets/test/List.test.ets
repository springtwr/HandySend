// Instrument Test 测试入口：挂载全部 ohosTest 套件
// 各子模块的测试套件在此注册（含自 entry/src/test/（Local Test）迁移的套件）

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
import ReceiveTargetsTest from './repository/ReceiveTargetsTest.test'

// ── model/ 迁移测试（原 Local Test）──
import BreakpointsTest from './model/BreakpointsTest.test'
import SendDeviceGroupingTest from './model/SendDeviceGroupingTest.test'
import SendTextPreparationTest from './model/SendTextPreparationTest.test'
import MtaProtocolModelsTest from './model/MtaProtocolModelsTest.test'
import SendProgressTest from './model/SendProgressTest.test'
import DragDropParserTest from './model/DragDropParserTest.test'

// ── utils/ 迁移测试（原 Local Test）──
import MimeUtilsTest from './utils/MimeUtilsTest.test'
import FileTypeIconUtilTest from './utils/FileTypeIconUtilTest.test'
import FormatUtilTest from './utils/FormatUtilTest.test'
import IPValidatorTest from './utils/IPValidatorTest.test'
import EventBusTest from './utils/EventBusTest.test'
import NetworkPresentationTest from './utils/NetworkPresentationTest.test'
import SpeedEstimatorTest from './utils/SpeedEstimatorTest.test'
import MtaProgressUtilTest from './utils/MtaProgressUtilTest.test'
import PreferencesUtilTest from './utils/PreferencesUtilTest.test'
import FingerprintIconsTest from './utils/FingerprintIconsTest.test'

// ── views/ 测试 ──
import SessionStatusBadgeTest from './views/SessionStatusBadgeTest.test'

// ── service/ 迁移测试（原 Local Test）──
import SendLogicTest from './service/SendLogicTest.test'
import ReceiveLogicTest from './service/ReceiveLogicTest.test'
import FavoritesServiceTest from './service/FavoritesServiceTest.test'
import ReceiveHistoryServiceTest from './service/ReceiveHistoryServiceTest.test'
import MtaSendProtocolTest from './service/MtaSendProtocolTest.test'
import MtaProtocolTest from './service/MtaProtocolTest.test'
import MtaMainFlowTest from './service/MtaMainFlowTest.test'
import MtaSendLogFilterTest from './service/MtaSendLogFilterTest.test'
import MtaLogLevelTest from './service/MtaLogLevelTest.test'
import LogLevelsTest from './service/LogLevelsTest.test'
import LogFormatTest from './service/LogFormatTest.test'
import MtaCryptoTest from './service/MtaCryptoTest.test'
import BackgroundTransferServiceTest from './service/BackgroundTransferServiceTest.test'
import TransferSessionRegistryTest from './service/TransferSessionRegistryTest.test'
import SessionHistoryStoreTest from './service/SessionHistoryStoreTest.test'
import RegistriesTest from './service/RegistriesTest.test'
import AdaptersTest from './service/AdaptersTest.test'
import SendSessionRegistrationTest from './service/SendSessionRegistrationTest.test'
import SendDiagnosticsTest from './service/SendDiagnosticsTest.test'
import TransferCenterTest from './viewmodel/TransferCenterTest.test'
import SessionDetailTest from './viewmodel/SessionDetailTest.test'
import ReceiveHistoryItemTest from './viewmodel/ReceiveHistoryItemTest.test'
import PendingConfirmTest from './service/PendingConfirmTest.test'
import SendPageTest from './viewmodel/SendPageTest.test'
import BackgroundAggregateTest from './service/BackgroundAggregateTest.test'
import AdapterExtensibilityTest from './service/AdapterExtensibilityTest.test'
import NetworkSettingsViewModelTest from './viewmodel/NetworkSettingsViewModelTest.test'

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
  ReceiveTargetsTest()

  // ── model/ 迁移测试套件 ──
  BreakpointsTest()
  SendDeviceGroupingTest()
  SendTextPreparationTest()
  MtaProtocolModelsTest()
  SendProgressTest()
  DragDropParserTest()

  // ── utils/ 迁移测试套件 ──
  MimeUtilsTest()
  FileTypeIconUtilTest()
  FormatUtilTest()
  IPValidatorTest()
  EventBusTest()
  NetworkPresentationTest()
  SpeedEstimatorTest()
  MtaProgressUtilTest()
  PreferencesUtilTest()
  FingerprintIconsTest()

  // ── views/ 测试套件 ──
  SessionStatusBadgeTest()

  // ── service/ 迁移测试套件 ──
  SendLogicTest()
  ReceiveLogicTest()
  FavoritesServiceTest()
  ReceiveHistoryServiceTest()
  MtaSendProtocolTest()
  MtaProtocolTest()
  MtaMainFlowTest()
  MtaSendLogFilterTest()
  MtaLogLevelTest()
  LogLevelsTest()
  LogFormatTest()
  MtaCryptoTest()
  BackgroundTransferServiceTest()
  TransferSessionRegistryTest()
  SessionHistoryStoreTest()
  RegistriesTest()
  AdaptersTest()
  SendSessionRegistrationTest()
  SendDiagnosticsTest()
  TransferCenterTest()
  SessionDetailTest()
  ReceiveHistoryItemTest()
  PendingConfirmTest()
  SendPageTest()
  BackgroundAggregateTest()
  AdapterExtensibilityTest()
  NetworkSettingsViewModelTest()
}
