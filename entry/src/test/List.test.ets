import MimeUtilsTest from './MimeUtils.test';
import PreferencesUtilTest from './PreferencesUtil.test';
import FavoritesServiceTest from './FavoritesService.test';
import ReceiveHistoryServiceTest from './ReceiveHistoryService.test';
import TransferProgressTest from './TransferProgress.test';
import BreakpointsTest from './Breakpoints.test';
import FormatUtilTest from './FormatUtil.test';
import IPValidatorTest from './IPValidator.test';
import EventBusTest from './EventBus.test';
import NetworkPresentationTest from './NetworkPresentation.test';
import ReceiveLogicTest from './ReceiveLogic.test';
import SendLogicTest from './SendLogic.test';
import P2pVerifyModelsTest from './P2pVerifyModels.test';
import BleVerifyModelsTest from './BleVerifyModels.test';
import MtaCryptoTest from './MtaCrypto.test';
import MtaProtocolTest from './MtaProtocol.test';
import MtaSendProtocolTest from './MtaSendProtocol.test';
import MtaMainFlowTest from './MtaMainFlow.test';
import MtaReceiveModelsTest from './MtaReceiveModels.test';

export default function testsuite() {
  MimeUtilsTest()
  PreferencesUtilTest()
  FavoritesServiceTest()
  ReceiveHistoryServiceTest()
  TransferProgressTest()
  BreakpointsTest()
  FormatUtilTest()
  IPValidatorTest()
  EventBusTest()
  NetworkPresentationTest()
  ReceiveLogicTest()
  SendLogicTest()
  P2pVerifyModelsTest()
  BleVerifyModelsTest()
  MtaCryptoTest()
  MtaProtocolTest()
  MtaSendProtocolTest()
  MtaMainFlowTest()
  MtaReceiveModelsTest()
}
